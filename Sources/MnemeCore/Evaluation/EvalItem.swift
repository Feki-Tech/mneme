import Foundation

/// One evaluation utterance: audio, its reference transcript, and the speaker's accent metadata.
/// Stored one per line in a JSONL manifest.
public struct EvalItem: Codable, Equatable, Sendable {
    public var id: String?
    /// Audio path; relative paths in a manifest are resolved against the manifest's folder.
    public var audio: String
    /// Reference transcript.
    public var text: String
    /// Language of the reference (ISO 639-1, for example "en").
    public var language: String?
    /// Accent or first language of the speaker, for example "arabic" or "en_IN".
    public var accent: String?
    /// Region or country, for example "tunisia".
    public var region: String?
    public var speaker: String?
    /// Optional slice of a longer recording, in seconds.
    public var start: Double?
    public var end: Double?

    public init(
        id: String? = nil,
        audio: String,
        text: String,
        language: String? = nil,
        accent: String? = nil,
        region: String? = nil,
        speaker: String? = nil,
        start: Double? = nil,
        end: Double? = nil
    ) {
        self.id = id
        self.audio = audio
        self.text = text
        self.language = language
        self.accent = accent
        self.region = region
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    /// A readable identifier for logs and reports.
    public var label: String {
        id ?? URL(fileURLWithPath: audio).lastPathComponent
    }
}

/// The outcome of transcribing one evaluation item.
public struct EvalResult: Codable, Equatable, Sendable {
    public var item: EvalItem
    public var hypothesis: String
    public var detectedLanguage: String?
    public var languageSource: String?
    public var words: EditCounts
    public var characters: EditCounts
    public var flaggedSegments: Int
    public var audioSeconds: Double?
    public var processingSeconds: Double?
    /// Set when the item could not be transcribed; such items are excluded from error rates and counted as failed.
    public var error: String?

    public init(
        item: EvalItem,
        hypothesis: String = "",
        detectedLanguage: String? = nil,
        languageSource: String? = nil,
        words: EditCounts = .zero,
        characters: EditCounts = .zero,
        flaggedSegments: Int = 0,
        audioSeconds: Double? = nil,
        processingSeconds: Double? = nil,
        error: String? = nil
    ) {
        self.item = item
        self.hypothesis = hypothesis
        self.detectedLanguage = detectedLanguage
        self.languageSource = languageSource
        self.words = words
        self.characters = characters
        self.flaggedSegments = flaggedSegments
        self.audioSeconds = audioSeconds
        self.processingSeconds = processingSeconds
        self.error = error
    }

    /// True when the transcription language differs from the reference language.
    public var languageMismatch: Bool {
        guard error == nil, let reference = item.language, let detected = detectedLanguage else { return false }
        return LanguagePolicy.normalize(reference) != LanguagePolicy.normalize(detected)
    }
}
