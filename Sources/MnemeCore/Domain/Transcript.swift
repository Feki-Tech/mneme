import Foundation

/// A word with its time span in seconds from the start of the recording.
public struct TranscribedWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Model probability in [0, 1]; nil when unknown.
    public var probability: Double?

    public init(text: String, start: Double, end: Double, probability: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// Signals attached to a segment so uncertain passages can be reviewed instead of silently trusted.
public enum QualityFlag: String, Codable, CaseIterable, Comparable, Sendable {
    /// Average token log-probability below the threshold.
    case lowConfidence = "low_confidence"
    /// High compression ratio, typical of repetition loops.
    case repetitive
    /// Probably silence or noise rather than speech.
    case likelySilence = "likely_silence"
    /// The decoder needed a higher sampling temperature to produce acceptable output.
    case temperatureFallback = "temperature_fallback"
    /// At least one word has a low probability.
    case uncertainWords = "uncertain_words"
    /// The decoder's timestamps were impossible (beyond the recording); the text is kept and its timing estimated.
    case unreliableTiming = "unreliable_timing"
    /// Text confirmed or corrected by the user.
    case userVerified = "user_verified"

    public static func < (lhs: QualityFlag, rhs: QualityFlag) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Comma-separated and sorted, so the stored value is deterministic.
    public static func encode(_ flags: Set<QualityFlag>) -> String {
        flags.sorted().map(\.rawValue).joined(separator: ",")
    }

    public static func decode(_ value: String) -> Set<QualityFlag> {
        Set(value.split(separator: ",").compactMap { QualityFlag(rawValue: String($0)) })
    }
}

public struct TranscribedSegment: Codable, Equatable, Sendable {
    /// A quality warning the user has not resolved. A verified segment can keep `unreliableTiming`, which no
    /// correction can fix, so verification alone settles the review.
    public var needsReview: Bool {
        !flags.isEmpty && !flags.contains(.userVerified)
    }

    public var index: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var avgLogprob: Double?
    public var compressionRatio: Double?
    public var noSpeechProb: Double?
    public var temperature: Double?
    public var words: [TranscribedWord]
    public var flags: Set<QualityFlag>
    /// The language this passage was decoded in, when the recording was identified passage by passage
    /// (speakers who switch languages). Nil means the transcript's language.
    public var language: String?

    public init(
        index: Int,
        start: Double,
        end: Double,
        text: String,
        avgLogprob: Double? = nil,
        compressionRatio: Double? = nil,
        noSpeechProb: Double? = nil,
        temperature: Double? = nil,
        words: [TranscribedWord] = [],
        flags: Set<QualityFlag> = [],
        language: String? = nil
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
        self.avgLogprob = avgLogprob
        self.compressionRatio = compressionRatio
        self.noSpeechProb = noSpeechProb
        self.temperature = temperature
        self.words = words
        self.flags = flags
        self.language = language
    }
}

/// How the transcription language was chosen.
public struct LanguageDecision: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Set explicitly by the user or an evaluation manifest.
        case forced
        /// The only language in the speaker's profile.
        case profile
        /// The model's top language.
        case detected
        /// The most likely language within the speaker's profile, overriding the model's top language.
        case constrained
        /// Reported by the decoder after transcription.
        case model
        /// No usable detection; the first language of the profile.
        case fallback
        /// Several languages: each segment carries the language it was decoded in; `code` is the language
        /// spoken longest and `probability` its share of the speech.
        case mixed
    }

    public var code: String
    public var probability: Double?
    public var source: Source
    /// The model's unconstrained top language, kept for auditing.
    public var modelTopCode: String?

    public init(code: String, probability: Double? = nil, source: Source, modelTopCode: String? = nil) {
        self.code = code
        self.probability = probability
        self.source = source
        self.modelTopCode = modelTopCode
    }
}

/// Which engine and settings produced a transcript, so every derived text can be reproduced or re-run.
public struct Provenance: Codable, Equatable, Sendable {
    public var engine: String
    public var modelID: String
    public var settings: [String: String]

    public init(engine: String, modelID: String, settings: [String: String] = [:]) {
        self.engine = engine
        self.modelID = modelID
        self.settings = settings
    }
}

/// Engine-independent transcript: what the speech layer produces and the archive stores.
public struct Transcript: Codable, Equatable, Sendable {
    public var language: LanguageDecision
    public var segments: [TranscribedSegment]
    public var provenance: Provenance
    public var processingSeconds: Double?

    public init(
        language: LanguageDecision,
        segments: [TranscribedSegment],
        provenance: Provenance,
        processingSeconds: Double? = nil
    ) {
        self.language = language
        self.segments = segments
        self.provenance = provenance
        self.processingSeconds = processingSeconds
    }

    public var text: String {
        TextJoiner.join(segments.map(\.text), language: language.code)
    }

    /// Seconds of speech per language, longest first. Segments without a language count for the transcript's.
    public var speechByLanguage: [(code: String, seconds: Double)] {
        var totals: [String: Double] = [:]
        for segment in segments {
            totals[segment.language ?? language.code, default: 0] += max(0, segment.end - segment.start)
        }
        return totals.map { (code: $0.key, seconds: $0.value) }.sorted { lhs, rhs in
            lhs.seconds != rhs.seconds ? lhs.seconds > rhs.seconds : lhs.code < rhs.code
        }
    }

    /// Segments waiting for review: a quality warning, and not verified by the user yet.
    public var flaggedSegmentCount: Int {
        segments.filter(\.needsReview).count
    }
}

public enum TextJoiner {
    /// Languages written without spaces between words.
    static let unspacedLanguages: Set<String> = ["zh", "ja", "th", "lo", "km", "my", "yue", "bo"]

    public static func join(_ parts: [String], language: String?) -> String {
        let trimmed = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unspaced = language.map { unspacedLanguages.contains(LanguagePolicy.normalize($0)) } ?? false
        return trimmed.joined(separator: unspaced ? "" : " ")
    }
}
