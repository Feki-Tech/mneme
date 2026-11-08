import Foundation

/// What the sanitizer changed. Every change is counted, so nothing is altered silently.
public struct SanitizationReport: Codable, Equatable, Sendable {
    public var droppedEmptySegments = 0
    /// Low-confidence or repetitive segments that start after the end of the recording: hallucinations in padding.
    public var droppedOutOfRangeSegments = 0
    /// Confident segments whose timestamps fell beyond the recording: the text is kept and the timing estimated.
    public var estimatedTimingSegments = 0
    public var clampedTimestamps = 0
    /// Word timings removed because they were inconsistent with their segment (the text is kept).
    public var droppedWordTimings = 0
    public var reorderedSegments = false

    public init() {}

    public var isClean: Bool {
        droppedEmptySegments == 0 && droppedOutOfRangeSegments == 0 && estimatedTimingSegments == 0
            && clampedTimestamps == 0 && droppedWordTimings == 0 && !reorderedSegments
    }

    public var summary: String {
        var parts: [String] = []
        if droppedEmptySegments > 0 { parts.append("\(droppedEmptySegments) empty segment(s) dropped") }
        if droppedOutOfRangeSegments > 0 {
            parts.append("\(droppedOutOfRangeSegments) low-confidence segment(s) beyond the end of the audio dropped")
        }
        if estimatedTimingSegments > 0 {
            parts.append("\(estimatedTimingSegments) segment(s) with impossible timestamps kept, timing estimated")
        }
        if clampedTimestamps > 0 { parts.append("\(clampedTimestamps) timestamp(s) adjusted") }
        if droppedWordTimings > 0 { parts.append("\(droppedWordTimings) inconsistent word timing(s) removed") }
        if reorderedSegments { parts.append("segments reordered by time") }
        return parts.isEmpty ? "clean" : parts.joined(separator: ", ")
    }
}

/// Validates and normalises a transcript before it is written.
///
/// Recoverable defects (empty segments, small timestamp overshoots, overlaps, inconsistent word timings)
/// are repaired and counted in the report. Confident speech is never dropped because of its timestamps:
/// a segment placed beyond the end of the recording keeps its text, gets an estimated timing and the
/// `unreliableTiming` flag; only low-confidence or repetitive segments there are dropped as hallucinations.
/// Defects that indicate corrupt input (non-finite or negative times, segments that end long before they
/// start, an unsupported language, missing provenance) throw, and nothing is written.
public struct TranscriptSanitizer: Sendable {
    /// Seconds of timestamp error tolerated and repaired.
    public var tolerance: Double
    public var policy: QualityPolicy

    public init(tolerance: Double = 0.5, policy: QualityPolicy = .standard) {
        self.tolerance = tolerance
        self.policy = policy
    }

    public func sanitize(_ transcript: Transcript, duration: Double?) throws -> (transcript: Transcript, report: SanitizationReport) {
        var report = SanitizationReport()

        guard let code = LanguagePolicy.validatedCode(transcript.language.code) else {
            throw ArchiveError.invalidLanguageCode(transcript.language.code)
        }
        var language = transcript.language
        language.code = code
        language.probability = Self.unitInterval(language.probability)
        language.modelTopCode = language.modelTopCode.flatMap { LanguagePolicy.validatedCode($0) }

        let engine = transcript.provenance.engine.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = transcript.provenance.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !engine.isEmpty, !modelID.isEmpty else {
            throw ArchiveError.invalidTranscript("the engine and model that produced it must be recorded")
        }
        let limit: Double? = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }

        var kept: [(order: Int, segment: TranscribedSegment, estimatedTiming: Bool)] = []
        for (order, original) in transcript.segments.enumerated() {
            var segment = original
            segment.text = Self.cleanText(original.text)
            if segment.text.isEmpty {
                report.droppedEmptySegments += 1
                continue
            }
            guard segment.start.isFinite, segment.end.isFinite else {
                throw ArchiveError.invalidTranscript("segment \(original.index) has a non-finite timestamp")
            }
            segment.avgLogprob = Self.finite(segment.avgLogprob)
            segment.compressionRatio = Self.finite(segment.compressionRatio).map { max(0, $0) }
            segment.noSpeechProb = Self.unitInterval(segment.noSpeechProb)
            segment.temperature = Self.finite(segment.temperature).map { max(0, $0) }
            if segment.start < 0 {
                guard segment.start >= -tolerance else {
                    throw ArchiveError.invalidTranscript("segment \(original.index) starts before the recording")
                }
                segment.start = 0
                report.clampedTimestamps += 1
            }
            if segment.end < segment.start {
                guard segment.start - segment.end <= tolerance else {
                    throw ArchiveError.invalidTranscript("segment \(original.index) ends before it starts")
                }
                segment.end = segment.start
                report.clampedTimestamps += 1
            }
            var estimatedTiming = false
            if let limit {
                if segment.start > limit + tolerance {
                    if policy.isLikelyHallucination(segment) {
                        report.droppedOutOfRangeSegments += 1
                        continue
                    }
                    // Confident speech with impossible timestamps: keep the words, estimate the timing below.
                    segment.start = limit
                    segment.end = limit
                    segment.words = []
                    estimatedTiming = true
                    report.estimatedTimingSegments += 1
                } else if segment.end > limit {
                    segment.end = limit
                    segment.start = min(segment.start, limit)
                    report.clampedTimestamps += 1
                }
            }
            if !estimatedTiming {
                segment.words = sanitizeWords(segment.words, in: segment, report: &report)
            }
            kept.append((order: order, segment: segment, estimatedTiming: estimatedTiming))
        }

        let sorted = kept.sorted { lhs, rhs in
            if lhs.segment.start != rhs.segment.start { return lhs.segment.start < rhs.segment.start }
            if lhs.segment.end != rhs.segment.end { return lhs.segment.end < rhs.segment.end }
            return lhs.order < rhs.order
        }
        if sorted.map({ $0.order }) != kept.map({ $0.order }) {
            report.reorderedSegments = true
        }

        var segments = sorted.map { $0.segment }
        let estimated = sorted.map { $0.estimatedTiming }
        // An overlap beyond the tolerance ends the earlier segment where the next one starts.
        if segments.count > 1 {
            for index in 1..<segments.count {
                let nextStart = segments[index].start
                if segments[index - 1].end - nextStart > tolerance {
                    segments[index - 1].end = max(segments[index - 1].start, nextStart)
                    segments[index - 1].words = clampWords(segments[index - 1].words, to: segments[index - 1])
                    report.clampedTimestamps += 1
                }
            }
        }
        // Estimated timing: from the end of the previous segment to the end of the recording.
        for index in segments.indices where estimated[index] {
            let previousEnd = index > 0 ? segments[index - 1].end : 0
            segments[index].start = min(previousEnd, segments[index].end)
        }
        for index in segments.indices {
            segments[index].index = index
            var flags = policy.flags(for: segments[index])
            if estimated[index] {
                flags.insert(.unreliableTiming)
            }
            segments[index].flags = flags
        }

        let clean = Transcript(
            language: language,
            segments: segments,
            provenance: Provenance(engine: engine, modelID: modelID, settings: transcript.provenance.settings),
            processingSeconds: Self.finite(transcript.processingSeconds).map { max(0, $0) }
        )
        return (clean, report)
    }

    /// Removes Whisper special tokens and control characters, collapses whitespace and applies NFC.
    public static func cleanText(_ text: String) -> String {
        let withoutTokens = text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: " ", options: .regularExpression)
        var scalars = String.UnicodeScalarView()
        for scalar in withoutTokens.unicodeScalars {
            if scalar.properties.generalCategory == .control {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.precomposedStringWithCanonicalMapping
    }

    private func sanitizeWords(
        _ words: [TranscribedWord],
        in segment: TranscribedSegment,
        report: inout SanitizationReport
    ) -> [TranscribedWord] {
        var result: [TranscribedWord] = []
        var previousStart = -Double.infinity
        for original in words {
            var word = original
            word.text = Self.cleanText(original.text)
            if word.text.isEmpty { continue }
            let plausible = word.start.isFinite && word.end.isFinite
                && word.end >= word.start - tolerance
                && word.start >= segment.start - tolerance
                && word.end <= segment.end + tolerance
                && word.start >= previousStart - tolerance
            guard plausible else {
                // Keep the text, drop timings that cannot be trusted.
                report.droppedWordTimings += words.count
                return []
            }
            previousStart = word.start
            word.probability = Self.unitInterval(word.probability)
            result.append(word)
        }
        return clampWords(result, to: segment)
    }

    private func clampWords(_ words: [TranscribedWord], to segment: TranscribedSegment) -> [TranscribedWord] {
        words.map { (word: TranscribedWord) -> TranscribedWord in
            var clamped = word
            clamped.start = min(max(word.start, segment.start), segment.end)
            clamped.end = min(max(word.end, clamped.start), segment.end)
            return clamped
        }
    }

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func unitInterval(_ value: Double?) -> Double? {
        finite(value).map { min(max($0, 0), 1) }
    }
}
