import Foundation
import MnemeCore

/// Transcribes evaluation items and scores them against their references.
public struct AccentEvaluator {
    public enum LanguageMode: String, CaseIterable, Sendable {
        /// Decode in the reference language: measures recognition of the accent alone.
        case reference
        /// Identify the language first (restricted to `languageProfile` when set): measures the whole pipeline,
        /// including accents being mistaken for another language.
        case detect
    }

    public var engine: WhisperEngine
    public var languageMode: LanguageMode
    public var languageProfile: [String]
    public var glossary: [String]
    /// How recordings are divided for language identification in detect mode.
    public var languageStrategy: LanguageStrategy
    public var sanitizer: TranscriptSanitizer

    public init(
        engine: WhisperEngine,
        languageMode: LanguageMode = .reference,
        languageProfile: [String] = [],
        glossary: [String] = [],
        languageStrategy: LanguageStrategy = .window,
        sanitizer: TranscriptSanitizer = TranscriptSanitizer()
    ) {
        self.engine = engine
        self.languageMode = languageMode
        self.languageProfile = languageProfile
        self.glossary = glossary
        self.languageStrategy = languageStrategy
        self.sanitizer = sanitizer
    }

    /// Never throws: failures are returned as results with `error` set, so one bad file cannot stop a run.
    public func evaluate(_ item: EvalItem) async -> EvalResult {
        let fileManager = FileManager.default
        var clipDirectory: URL?
        defer {
            if let clipDirectory {
                try? fileManager.removeItem(at: clipDirectory)
            }
        }
        do {
            let source = URL(fileURLWithPath: item.audio)
            var audioURL = source
            if item.start != nil || item.end != nil {
                let directory = fileManager.temporaryDirectory
                    .appendingPathComponent("mneme-eval-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                clipDirectory = directory
                let total = try AudioFileInfo.duration(of: source)
                let clip = directory.appendingPathComponent("clip.wav")
                try AudioFileInfo.extractSegment(from: source, start: item.start ?? 0, end: item.end ?? total, to: clip)
                audioURL = clip
            }
            let duration = try AudioFileInfo.duration(of: audioURL)
            let request = TranscriptionRequest(
                audioURL: audioURL,
                forcedLanguage: languageMode == .reference ? item.language : nil,
                languageProfile: languageMode == .detect ? languageProfile : [],
                glossary: glossary,
                languageStrategy: languageStrategy
            )
            let transcript = try await engine.transcribe(request)
            let clean = try sanitizer.sanitize(transcript, duration: duration).transcript
            let hypothesis = clean.text
            var languages: [String] = []
            for segment in clean.segments {
                let code = segment.language ?? clean.language.code
                if languages.last != code {
                    languages.append(code)
                }
            }
            return EvalResult(
                item: item,
                hypothesis: hypothesis,
                detectedLanguage: clean.language.code,
                languageSource: clean.language.source.rawValue,
                words: ErrorRate.wordErrors(reference: item.text, hypothesis: hypothesis),
                characters: ErrorRate.characterErrors(reference: item.text, hypothesis: hypothesis),
                flaggedSegments: clean.flaggedSegmentCount,
                audioSeconds: duration,
                processingSeconds: clean.processingSeconds,
                segmentLanguages: languages
            )
        } catch {
            return EvalResult(item: item, error: error.localizedDescription)
        }
    }
}
