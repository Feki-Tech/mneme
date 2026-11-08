import Foundation
import MnemeCore
import WhisperKit

public enum SpeechError: Error, LocalizedError, Equatable {
    case modelNotDownloaded(variant: String, size: String)
    case modelNotLoaded

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let variant, let size):
            return "The Whisper model \(variant) is not prepared on this Mac yet. Download it once (\(size) "
                + "from huggingface.co) with `mneme models download \(variant)`, or add --allow-download."
        case .modelNotLoaded:
            return "The speech model is not loaded."
        }
    }
}

/// What to transcribe, with the speaker context that makes recognition robust to accents.
public struct TranscriptionRequest: Sendable {
    public var audioURL: URL
    /// Skip language identification and decode in this language.
    public var forcedLanguage: String?
    /// The speaker's languages; identification is restricted to them.
    public var languageProfile: [String]
    /// Names and terms passed to the decoder as a prompt.
    public var glossary: [String]
    public var wordTimestamps: Bool

    public init(
        audioURL: URL,
        forcedLanguage: String? = nil,
        languageProfile: [String] = [],
        glossary: [String] = [],
        wordTimestamps: Bool = true
    ) {
        self.audioURL = audioURL
        self.forcedLanguage = forcedLanguage
        self.languageProfile = languageProfile
        self.glossary = glossary
        self.wordTimestamps = wordTimestamps
    }
}

/// On-device Whisper transcription through WhisperKit (Core ML on the Apple Neural Engine).
/// Audio is processed locally; the network is only used to download a model when explicitly allowed.
public final class WhisperEngine {
    public static let engineName = "whisperkit"

    public let profile: ModelProfile
    public let modelsDirectory: URL
    private var pipe: WhisperKit?
    private var modelFolderName: String?

    public init(profile: ModelProfile = .defaultProfile, modelsDirectory: URL = ModelLocator.defaultModelsDirectory) {
        self.profile = profile
        self.modelsDirectory = modelsDirectory
    }

    /// The model is downloaded and has loaded successfully before, so it can be used offline.
    public var isReady: Bool {
        ModelLocator.readyModelFolder(variant: profile.variant, base: modelsDirectory) != nil
    }

    public var isLoaded: Bool {
        pipe != nil
    }

    /// Loads the model. Without `allowDownload`, only a model already prepared on this Mac is used,
    /// and nothing is fetched from the network.
    public func load(allowDownload: Bool) async throws {
        if pipe != nil { return }
        let ready = ModelLocator.readyModelFolder(variant: profile.variant, base: modelsDirectory)
        guard ready != nil || allowDownload else {
            throw SpeechError.modelNotDownloaded(variant: profile.variant, size: profile.approximateDownloadSize)
        }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let local = ready ?? ModelLocator.localModelFolder(variant: profile.variant, base: modelsDirectory)
        let config: WhisperKitConfig
        if let local {
            config = WhisperKitConfig(
                model: profile.variant,
                downloadBase: modelsDirectory,
                modelFolder: local.path,
                tokenizerFolder: modelsDirectory,
                verbose: false,
                load: true,
                download: false
            )
        } else {
            config = WhisperKitConfig(
                model: profile.variant,
                downloadBase: modelsDirectory,
                tokenizerFolder: modelsDirectory,
                verbose: false,
                load: true,
                download: true
            )
        }
        let pipeline = try await WhisperKit(config)
        pipe = pipeline
        if let folder = ModelLocator.localModelFolder(variant: profile.variant, base: modelsDirectory) {
            ModelLocator.markReady(folder)
            modelFolderName = folder.lastPathComponent
        }
    }

    /// Transcribes one file. The result is not yet validated; `ArchiveStore` sanitises it before writing.
    public func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
        guard let pipe else { throw SpeechError.modelNotLoaded }
        let started = Date()
        let path = request.audioURL.path
        let allowed = profile.isMultilingual ? request.languageProfile : ["en"]

        // 1. Language: identify once on the opening of the recording, restricted to the speaker's languages.
        var probabilities: [String: Double]?
        if request.forcedLanguage == nil && allowed.count != 1 {
            do {
                let detection = try await pipe.detectLanguage(audioPath: path)
                var scores: [String: Double] = [:]
                for (code, value) in detection.langProbs {
                    scores[code] = Double(value)
                }
                if scores.isEmpty && !detection.language.isEmpty {
                    scores[detection.language] = 1
                }
                probabilities = scores
            } catch {
                // Identification failed: the profile's first language, or the decoder's own identification, is used.
                probabilities = nil
            }
        }
        let decision = LanguagePolicy.decide(
            forced: request.forcedLanguage,
            probabilities: probabilities,
            allowed: allowed
        )

        // 2. Decoding: VAD chunking at silences, word timings, temperature fallback (WhisperKit defaults),
        //    and the personal glossary as a prompt.
        var options = DecodingOptions()
        options.language = decision?.code
        options.detectLanguage = decision == nil
        options.skipSpecialTokens = true
        options.wordTimestamps = request.wordTimestamps
        options.chunkingStrategy = .vad
        var promptTokenCount = 0
        if let prompt = PromptBuilder.promptText(terms: request.glossary), let tokenizer = pipe.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            let limited = PromptBuilder.limit(tokens: tokens)
            if !limited.isEmpty {
                options.promptTokens = limited
                // After a prompt the first word is often less certain. WhisperKit's first-token early stop
                // (log-probability below -1.5) then ends the window with no text at all: measured on the
                // macOS-voices set, 8 of 37 clips came back empty. The average log-probability and
                // compression-ratio fallbacks still guard against hallucinations.
                options.firstTokenLogProbThreshold = nil
                // WhisperKit 1.1 misaligns word timings when a prompt is present: they collapse onto the last
                // second of the 30-second window, and the segment boundaries are then moved onto them (measured:
                // 29.32–29.98 s for a 4.5 s clip). The timestamp tokens themselves are right (0.00–4.24 s), so
                // prompted runs keep segment timings and skip word timings.
                options.wordTimestamps = false
                promptTokenCount = limited.count
            }
        }

        // 3. Transcription. With VAD chunking WhisperKit returns one result per chunk, in file time.
        //
        // WhisperKit 1.1 finds where sampling starts by looking for the task token among the first three
        // tokens. A prompt pushes it further back, which silently switches off the timestamp rules: the
        // timestamps then drift to the end of the 30-second window (measured: 29.3–30.0 s for a 4.5 s clip).
        // For prompted runs a correctly positioned copy of the same rules is added. Prefill layout:
        // <|startofprev|> prompt… <|startoftranscript|> <|lang|> <|transcribe|> <|0.00|>
        let originalFilters = pipe.textDecoder.logitsFilters
        var promptTimestampRules: TimestampRulesFilter?
        if promptTokenCount > 0, pipe.textDecoder.isModelMultilingual, let tokenizer = pipe.tokenizer {
            promptTimestampRules = TimestampRulesFilter(
                specialTokens: tokenizer.specialTokens,
                sampleBegin: 1 + promptTokenCount + 4,
                maxInitialTimestampIndex: nil,
                isModelMultilingual: false
            )
        }
        var results: [TranscriptionResult]
        if let promptTimestampRules {
            pipe.textDecoder.logitsFilters = (originalFilters ?? []) + [promptTimestampRules as any LogitsFiltering]
            do {
                results = try await pipe.transcribe(audioPath: path, decodeOptions: options)
            } catch {
                pipe.textDecoder.logitsFilters = originalFilters
                throw error
            }
            pipe.textDecoder.logitsFilters = originalFilters
        } else {
            results = try await pipe.transcribe(audioPath: path, decodeOptions: options)
        }

        // Safety net: speech must never be lost because of the glossary. With a prompt, Whisper sometimes
        // ends a window at once (8 of 37 clips in the macOS-voices set), leaving segments without words.
        // Such chunks are transcribed again without the prompt. Chunking depends only on the audio, so the
        // chunks of both runs align.
        var repairedChunks = 0
        if options.promptTokens != nil && (results.isEmpty || results.contains(where: WhisperEngine.hasNoWords)) {
            var plain = options
            plain.promptTokens = nil
            plain.firstTokenLogProbThreshold = DecodingOptions().firstTokenLogProbThreshold
            let unprompted: [TranscriptionResult] = try await pipe.transcribe(audioPath: path, decodeOptions: plain)
            if unprompted.count == results.count {
                for index in results.indices
                where WhisperEngine.hasNoWords(results[index]) && !WhisperEngine.hasNoWords(unprompted[index]) {
                    results[index] = unprompted[index]
                    repairedChunks += 1
                }
            } else if unprompted.contains(where: { !WhisperEngine.hasNoWords($0) }) {
                results = unprompted
                repairedChunks = unprompted.count
            }
        }

        var segments: [TranscribedSegment] = []
        for result in results {
            for segment in result.segments {
                let words = (segment.words ?? []).map { (timing: WordTiming) -> TranscribedWord in
                    TranscribedWord(
                        text: timing.word,
                        start: Double(timing.start),
                        end: Double(timing.end),
                        probability: Double(timing.probability)
                    )
                }
                segments.append(TranscribedSegment(
                    index: segments.count,
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: segment.text,
                    avgLogprob: Double(segment.avgLogprob),
                    compressionRatio: Double(segment.compressionRatio),
                    // WhisperKit 1.1 does not compute a no-speech probability yet and reports 0; a real softmax
                    // probability is never exactly 0, so store "unknown" rather than a misleading certainty.
                    noSpeechProb: segment.noSpeechProb > 0 ? Double(segment.noSpeechProb) : nil,
                    temperature: Double(segment.temperature),
                    words: words
                ))
            }
        }

        let language: LanguageDecision
        if let decision {
            language = decision
        } else if let code = WhisperEngine.mostCommon(results.map { $0.language }) {
            language = LanguageDecision(code: code, probability: nil, source: .model)
        } else {
            language = LanguageDecision(code: allowed.first ?? "en", probability: nil, source: .fallback)
        }

        var settings: [String: String] = [
            "profile": profile.name,
            "model_variant": profile.variant,
            "chunking": "vad",
            "word_timestamps": options.wordTimestamps ? "true" : "false",
            "language_profile": allowed.joined(separator: ","),
            "glossary_terms": String(request.glossary.count),
            "prompt_tokens": String(promptTokenCount),
        ]
        if promptTokenCount > 0 {
            settings["prompt_repaired_chunks"] = String(repairedChunks)
            if request.wordTimestamps {
                settings["word_timestamps_skipped"] = "glossary_prompt"
            }
        }
        return Transcript(
            language: language,
            segments: segments,
            provenance: Provenance(
                engine: WhisperEngine.engineName,
                modelID: modelFolderName ?? profile.variant,
                settings: settings
            ),
            processingSeconds: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Model management

    /// Model variants published in argmaxinc/whisperkit-coreml (uses the network).
    public static func availableRemoteModels() async throws -> [String] {
        try await WhisperKit.fetchAvailableModels()
    }

    /// Downloads a model variant into the models directory (uses the network).
    @discardableResult
    public static func download(
        profile: ModelProfile,
        modelsDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        return try await WhisperKit.download(
            variant: profile.variant,
            downloadBase: modelsDirectory,
            progressCallback: { value in
                progress(value.fractionCompleted)
            }
        )
    }

    /// A chunk without a single letter or digit in its segments (special tokens and punctuation only).
    static func hasNoWords(_ result: TranscriptionResult) -> Bool {
        !result.segments.contains { segment in
            TranscriptSanitizer.cleanText(segment.text).contains { $0.isLetter || $0.isNumber }
        }
    }

    static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values {
            let code = LanguagePolicy.normalize(value)
            if !code.isEmpty {
                counts[code, default: 0] += 1
            }
        }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key
    }
}
