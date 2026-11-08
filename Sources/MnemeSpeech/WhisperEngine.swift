import Foundation
import MnemeCore
import WhisperKit

public enum SpeechError: Error, LocalizedError, Equatable {
    case modelNotDownloaded(variant: String, size: String)
    case modelNotLoaded
    case windowsLost

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let variant, let size):
            return "The Whisper model \(variant) is not prepared on this Mac yet. Download it once (\(size) "
                + "from huggingface.co) with `mneme models download \(variant)`, or add --allow-download."
        case .modelNotLoaded:
            return "The speech model is not loaded."
        case .windowsLost:
            return "Some parts of the recording were not decoded."
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
    /// How the recording is divided for language identification when the profile lists several languages.
    public var languageStrategy: LanguageStrategy

    public init(
        audioURL: URL,
        forcedLanguage: String? = nil,
        languageProfile: [String] = [],
        glossary: [String] = [],
        wordTimestamps: Bool = true,
        languageStrategy: LanguageStrategy = .window
    ) {
        self.audioURL = audioURL
        self.forcedLanguage = forcedLanguage
        self.languageProfile = languageProfile
        self.glossary = glossary
        self.wordTimestamps = wordTimestamps
        self.languageStrategy = languageStrategy
    }
}

/// Progress of one transcription: the share of windows decoded and their text so far.
public struct TranscriptionProgressUpdate: Sendable {
    public var fractionCompleted: Double
    public var text: String

    public init(fractionCompleted: Double, text: String) {
        self.fractionCompleted = fractionCompleted
        self.text = text
    }
}

public typealias TranscriptionProgressHandler = @Sendable (TranscriptionProgressUpdate) -> Void

/// WhisperKit builds its language filter from the tokenizer's language tokens the first time it identifies a
/// language. A decoder whose tokenizer lists only the speaker's languages therefore identifies among them alone,
/// as part of the normal decoding pass, without an extra pass over the audio.
final class LanguageRestrictedTokenizer: WhisperTokenizer {
    private let base: WhisperTokenizer
    let allLanguageTokens: Set<Int>

    init(base: WhisperTokenizer, languageTokens: Set<Int>) {
        self.base = base
        self.allLanguageTokens = languageTokens
    }

    var specialTokens: SpecialTokens {
        base.specialTokens
    }

    func encode(text: String) -> [Int] {
        base.encode(text: text)
    }

    func decode(tokens: [Int]) -> String {
        base.decode(tokens: tokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        base.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        base.convertIdToToken(id)
    }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        base.splitToWordTokens(tokenIds: tokenIds)
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
    /// The decoder WhisperKit loaded, and the copy restricted to the current language profile.
    private var baseDecoder: TextDecoder?
    private var restrictedDecoder: (key: String, decoder: TextDecoder, primed: Bool)?

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
        baseDecoder = pipeline.textDecoder as? TextDecoder
        restrictedDecoder = nil
        if let folder = ModelLocator.localModelFolder(variant: profile.variant, base: modelsDirectory) {
            ModelLocator.markReady(folder)
            modelFolderName = folder.lastPathComponent
        }
    }

    /// Transcribes one file. The result is not yet validated; `ArchiveStore` sanitises it before writing.
    ///
    /// The recording is decoded in windows. With a fixed language (chosen, or the only language of the
    /// profile) every window uses it. Otherwise each window identifies its own language among the speaker's
    /// languages, inside the decoding pass, so speakers who switch languages are followed window by window;
    /// with `LanguageStrategy.sentence` the windows follow sentences.
    public func transcribe(
        _ request: TranscriptionRequest,
        progress: TranscriptionProgressHandler? = nil
    ) async throws -> Transcript {
        guard let pipe else { throw SpeechError.modelNotLoaded }
        let started = Date()
        let multilingual = profile.isMultilingual && (baseDecoder?.isModelMultilingual ?? pipe.textDecoder.isModelMultilingual)
        let allowed = multilingual ? request.languageProfile.compactMap { LanguagePolicy.validatedCode($0) } : ["en"]

        // 1. Language: fixed for the recording, or identified window by window among the allowed languages.
        var fixed: LanguageDecision?
        if let forced = request.forcedLanguage {
            fixed = LanguageDecision(code: LanguagePolicy.normalize(forced), probability: nil, source: .forced)
        } else if allowed.count == 1 {
            fixed = LanguageDecision(code: allowed[0], probability: nil, source: .profile)
        }
        // Without a profile any of Whisper's languages is possible: one identification for the whole recording
        // is then safer for accents than one per window.
        let strategy: LanguageStrategy = fixed != nil ? .window : (allowed.isEmpty ? .recording : request.languageStrategy)

        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: request.audioURL.path)
        let windowSamples = pipe.featureExtractor.windowSamples ?? 480_000
        let windows = try await Self.windows(for: samples, strategy: strategy, windowSamples: windowSamples)

        if fixed == nil && strategy == .recording {
            useDecoder(restrictedTo: nil)
            fixed = await identifyOnce(samples, windowSamples: windowSamples, allowed: allowed)
        }
        let perWindowLanguage = fixed == nil
        let primed = useDecoder(restrictedTo: perWindowLanguage ? allowed : nil)

        // 2. Decoding options: word timings, temperature fallback (WhisperKit defaults), the glossary as a prompt.
        var options = DecodingOptions()
        options.language = fixed?.code
        options.detectLanguage = perWindowLanguage
        options.skipSpecialTokens = true
        options.wordTimestamps = request.wordTimestamps
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

        // WhisperKit 1.1 finds where sampling starts by looking for the task token among the first three
        // tokens. A prompt pushes it further back, which silently switches off the timestamp rules: the
        // timestamps then drift to the end of the 30-second window (measured: 29.3–30.0 s for a 4.5 s clip).
        // For prompted runs a correctly positioned copy of the same rules is added. Prefill layout:
        // <|startofprev|> prompt… <|startoftranscript|> <|lang|> <|transcribe|> <|0.00|>
        let decoder = pipe.textDecoder
        let originalFilters = decoder.logitsFilters
        if promptTokenCount > 0, decoder.isModelMultilingual, let tokenizer = pipe.tokenizer {
            let rules = TimestampRulesFilter(
                specialTokens: tokenizer.specialTokens,
                sampleBegin: 1 + promptTokenCount + 4,
                maxInitialTimestampIndex: nil,
                isModelMultilingual: false
            )
            pipe.textDecoder.logitsFilters = (originalFilters ?? []) + [rules as any LogitsFiltering]
        }
        defer { pipe.textDecoder.logitsFilters = originalFilters }

        // 3. Decoding, a few windows at a time so progress can be reported. WhisperKit builds its language
        // filter on first use, so a new language-restricted decoder decodes its first window alone.
        //
        // With a language identified per window, this first decoding is greedy only: WhisperKit identifies the
        // language again at every fallback temperature, by sampling, which can move a window to another of the
        // speaker's languages (measured: a French and Arabic clip came back translated into English). Windows
        // that need the fallback are decoded again below, in the language identified here.
        var firstPass = options
        if perWindowLanguage {
            firstPass.temperatureFallbackCount = 0
        }
        var results = [[TranscriptionResult]](repeating: [], count: windows.count)
        var batches: [[Int]] = []
        var next = 0
        if !primed && !windows.isEmpty {
            batches.append([0])
            next = 1
        }
        while next < windows.count {
            batches.append(Array(next..<min(windows.count, next + Self.batchSize)))
            next += Self.batchSize
        }
        var completed = 0
        for batch in batches {
            let decoded = try await decode(batch.map { windows[$0] }, options: firstPass)
            for (offset, index) in batch.enumerated() {
                results[index] = decoded[offset]
            }
            if !primed {
                markRestrictedDecoderPrimed()
            }
            completed += batch.count
            progress?(TranscriptionProgressUpdate(
                fractionCompleted: Double(completed) / Double(max(1, windows.count)),
                text: Self.partialText(results)
            ))
        }

        // Temperature fallback for the windows that need it, with each window's language fixed.
        var fallbackWindows = 0
        if perWindowLanguage && options.temperatureFallbackCount > 0 {
            let unreliable = results.indices.filter { Self.needsFallback(results[$0], options: options) }
            if !unreliable.isEmpty {
                let perWindow: [DecodingOptions] = unreliable.map { index in
                    var retry = options
                    retry.language = results[index].first.flatMap { LanguagePolicy.validatedCode($0.language) } ?? allowed.first
                    retry.detectLanguage = false
                    // The greedy decoding is already done: continue with the fallback temperatures.
                    retry.temperature = options.temperature + options.temperatureIncrementOnFallback
                    retry.temperatureFallbackCount = options.temperatureFallbackCount - 1
                    return retry
                }
                let retried = try await decode(unreliable.map { windows[$0] }, perWindow: perWindow)
                for (offset, index) in unreliable.enumerated() where Self.isBetter(retried[offset], than: results[index], options: options) {
                    results[index] = retried[offset]
                    fallbackWindows += 1
                }
            }
        }

        // A window that still has no words may have been stopped by WhisperKit's first-token check. It is decoded
        // once more without that check; the text is kept only if the decoder is confident, so silence does not
        // turn into an invented sentence.
        var rescuedWindows = 0
        if options.promptTokens == nil {
            let silent = results.indices.filter { results[$0].isEmpty || results[$0].allSatisfy(WhisperEngine.hasNoWords) }
            if !silent.isEmpty {
                let perWindow: [DecodingOptions] = silent.map { index in
                    var retry = options
                    if perWindowLanguage {
                        retry.language = results[index].first.flatMap { LanguagePolicy.validatedCode($0.language) } ?? allowed.first
                        retry.detectLanguage = false
                    }
                    retry.firstTokenLogProbThreshold = nil
                    retry.temperatureFallbackCount = 0
                    return retry
                }
                let retried = try await decode(silent.map { windows[$0] }, perWindow: perWindow)
                let confidence = options.logProbThreshold ?? -1
                for (offset, index) in silent.enumerated()
                where !retried[offset].allSatisfy(WhisperEngine.hasNoWords) && Self.meanLogProb(retried[offset]) >= confidence {
                    results[index] = retried[offset]
                    rescuedWindows += 1
                }
            }
        }

        // Safety net: speech must never be lost because of the glossary. With a prompt, Whisper sometimes
        // ends a window at once (8 of 37 clips in the macOS-voices set), leaving segments without words.
        // Those windows are decoded again without the prompt.
        var repairedChunks = 0
        if options.promptTokens != nil {
            let empty = results.indices.filter { results[$0].isEmpty || results[$0].allSatisfy(WhisperEngine.hasNoWords) }
            if !empty.isEmpty {
                var plain = options
                plain.promptTokens = nil
                plain.firstTokenLogProbThreshold = DecodingOptions().firstTokenLogProbThreshold
                plain.wordTimestamps = request.wordTimestamps
                pipe.textDecoder.logitsFilters = originalFilters
                let retried = try await decode(empty.map { windows[$0] }, options: plain)
                for (offset, index) in empty.enumerated() where !retried[offset].allSatisfy(WhisperEngine.hasNoWords) {
                    results[index] = retried[offset]
                    repairedChunks += 1
                }
            }
        }

        // 4. Segments in file time, each with the language its window was decoded in.
        var segments: [TranscribedSegment] = []
        var windowLanguages: [String] = []
        for (index, windowResults) in results.enumerated() {
            let offset = windows[index].seekOffsetIndex
            for result in windowResults {
                let language = perWindowLanguage ? LanguagePolicy.validatedCode(result.language) : nil
                if let language {
                    windowLanguages.append(language)
                }
                for original in result.segments {
                    let segment = TranscriptionUtilities.updateSegmentTimings(segment: original, seekOffsetIndex: offset)
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
                        words: words,
                        language: language
                    ))
                }
            }
        }

        let language = fixed ?? Self.languageDecision(for: segments, windowLanguages: windowLanguages, allowed: allowed)
        let strategyLabel: String
        if let source = fixed?.source, source == .forced || source == .profile {
            strategyLabel = "fixed"
        } else {
            strategyLabel = strategy.rawValue
        }
        var settings: [String: String] = [
            "profile": profile.name,
            "model_variant": profile.variant,
            "language_strategy": strategyLabel,
            "windows": String(windows.count),
            "fallback_windows": String(fallbackWindows),
            "rescued_windows": String(rescuedWindows),
            "word_timestamps": options.wordTimestamps ? "true" : "false",
            "language_profile": allowed.joined(separator: ","),
            "glossary_terms": String(request.glossary.count),
            "prompt_tokens": String(promptTokenCount),
        ]
        if perWindowLanguage {
            let draft = Transcript(language: language, segments: segments, provenance: Provenance(engine: "draft", modelID: "draft"))
            settings["speech_by_language"] = draft.speechByLanguage
                .map { "\($0.code):" + String(format: "%.1f", $0.seconds) }
                .joined(separator: ",")
        }
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

    /// Windows decoded at the same time. WhisperKit overlaps the work of concurrent windows; batches keep
    /// progress reports coming during long recordings.
    static let batchSize = 8

    /// Whether a greedy decoding would have triggered WhisperKit's temperature fallback: no words, a
    /// repetition loop, or a low average log-probability.
    static func needsFallback(_ results: [TranscriptionResult], options: DecodingOptions) -> Bool {
        let segments = results.flatMap { $0.segments }
        if segments.isEmpty || results.allSatisfy(WhisperEngine.hasNoWords) {
            return true
        }
        return segments.contains { segment in
            if let threshold = options.compressionRatioThreshold, segment.compressionRatio > threshold {
                return true
            }
            if let threshold = options.logProbThreshold, segment.avgLogprob < threshold {
                return true
            }
            return false
        }
    }

    /// A retried decoding replaces the first one when it has words and either passes the fallback checks or is
    /// more probable on average.
    static func isBetter(_ candidate: [TranscriptionResult], than current: [TranscriptionResult], options: DecodingOptions) -> Bool {
        if candidate.isEmpty || candidate.allSatisfy(WhisperEngine.hasNoWords) {
            return false
        }
        if current.isEmpty || current.allSatisfy(WhisperEngine.hasNoWords) || !needsFallback(candidate, options: options) {
            return true
        }
        return meanLogProb(candidate) > meanLogProb(current)
    }

    static func meanLogProb(_ results: [TranscriptionResult]) -> Float {
        let values = results.flatMap { $0.segments }.map { $0.avgLogprob }
        return values.isEmpty ? -Float.infinity : values.reduce(0, +) / Float(values.count)
    }

    /// Decodes windows concurrently with the same options.
    private func decode(_ windows: [AudioChunk], options: DecodingOptions) async throws -> [[TranscriptionResult]] {
        try await decode(windows, perWindow: Array(repeating: options, count: windows.count))
    }

    /// Decodes windows concurrently and returns their results in order; any failure fails the whole call, so
    /// no speech is dropped silently.
    private func decode(_ windows: [AudioChunk], perWindow options: [DecodingOptions]) async throws -> [[TranscriptionResult]] {
        guard let pipe else { throw SpeechError.modelNotLoaded }
        guard !windows.isEmpty else { return [] }
        let perWindow: [DecodingOptions?] = options.map { Optional($0) }
        let outcomes = await pipe.transcribeWithOptions(
            audioArrays: windows.map { $0.audioSamples },
            decodeOptionsArray: perWindow,
            seekOffsets: windows.map { $0.seekOffsetIndex }
        )
        guard outcomes.count == windows.count else {
            if let first = outcomes.first, case .failure(let error) = first {
                throw error
            }
            throw SpeechError.windowsLost
        }
        return try outcomes.map { (outcome: Result<[TranscriptionResult], Error>) throws -> [TranscriptionResult] in
            switch outcome {
            case .success(let results):
                return results
            case .failure(let error):
                throw error
            }
        }
    }

    /// Fixed 30-second windows cut at silences, or windows that follow sentences.
    static func windows(for samples: [Float], strategy: LanguageStrategy, windowSamples: Int) async throws -> [AudioChunk] {
        guard !samples.isEmpty else { return [] }
        if strategy == .sentence {
            return SpeechWindowing(sampleRate: Double(WhisperKit.sampleRate)).windows(for: samples).map { range in
                AudioChunk(seekOffsetIndex: range.lowerBound, audioSamples: Array(samples[range]))
            }
        }
        if samples.count <= windowSamples {
            return [AudioChunk(seekOffsetIndex: 0, audioSamples: samples)]
        }
        return try await VADAudioChunker().chunkAll(audioArray: samples, maxChunkLength: windowSamples, decodeOptions: nil)
    }

    /// One identification on the opening of the recording (the `recording` strategy).
    private func identifyOnce(_ samples: [Float], windowSamples: Int, allowed: [String]) async -> LanguageDecision? {
        guard let pipe else { return nil }
        var probabilities: [String: Double]?
        if let detection = try? await pipe.detectLangauge(audioArray: Array(samples.prefix(windowSamples))) {
            var scores: [String: Double] = [:]
            for (code, value) in detection.langProbs {
                scores[code] = Double(value)
            }
            if scores.isEmpty && !detection.language.isEmpty {
                scores[detection.language] = 1
            }
            probabilities = scores
        }
        return LanguagePolicy.decide(forced: nil, probabilities: probabilities, allowed: allowed)
    }

    /// The transcript's language when each window identified its own: the language spoken longest, marked as
    /// mixed when several were found.
    static func languageDecision(for segments: [TranscribedSegment], windowLanguages: [String], allowed: [String]) -> LanguageDecision {
        var seconds: [String: Double] = [:]
        for segment in segments {
            if let code = segment.language {
                seconds[code, default: 0] += max(0, segment.end - segment.start)
            }
        }
        let ranked = seconds.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        let total = ranked.reduce(0) { $0 + $1.value }
        if ranked.count > 1, let top = ranked.first {
            return LanguageDecision(code: top.key, probability: total > 0 ? top.value / total : nil, source: .mixed)
        }
        if let only = ranked.first?.key ?? mostCommon(windowLanguages) {
            return LanguageDecision(code: only, probability: nil, source: allowed.isEmpty ? .detected : .constrained)
        }
        return LanguageDecision(code: allowed.first ?? "en", probability: nil, source: .fallback)
    }

    /// Text of the windows decoded so far, in order, for progress reports.
    static func partialText(_ results: [[TranscriptionResult]]) -> String {
        results.flatMap { $0 }
            .map { TranscriptSanitizer.cleanText($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Language-restricted decoding

    /// Installs WhisperKit's own decoder, or a copy that identifies languages only among `allowed`.
    /// Returns false when the restricted decoder has not decoded a window yet.
    @discardableResult
    private func useDecoder(restrictedTo allowed: [String]?) -> Bool {
        guard let pipe, let base = baseDecoder else { return true }
        guard let allowed, !allowed.isEmpty, let tokenizer = base.tokenizer else {
            pipe.textDecoder = base
            return true
        }
        let key = allowed.sorted().joined(separator: ",")
        if let current = restrictedDecoder, current.key == key {
            pipe.textDecoder = current.decoder
            return current.primed
        }
        let tokens = Set(allowed.compactMap { tokenizer.convertTokenToId("<|\($0)|>") })
        guard !tokens.isEmpty else {
            pipe.textDecoder = base
            return true
        }
        // Same Core ML model; only the tokenizer's list of language tokens differs.
        let decoder = TextDecoder()
        decoder.model = base.model
        decoder.isModelMultilingual = base.isModelMultilingual
        decoder.logitsFilters = base.logitsFilters
        decoder.tokenizer = LanguageRestrictedTokenizer(base: tokenizer, languageTokens: tokens)
        restrictedDecoder = (key: key, decoder: decoder, primed: false)
        pipe.textDecoder = decoder
        return false
    }

    private func markRestrictedDecoderPrimed() {
        if let current = restrictedDecoder, let installed = pipe?.textDecoder as? TextDecoder, installed === current.decoder {
            restrictedDecoder = (key: current.key, decoder: current.decoder, primed: true)
        }
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
