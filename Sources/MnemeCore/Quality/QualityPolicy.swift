import Foundation

/// Thresholds that turn decoder statistics into review flags. Defaults follow Whisper's own fallback rules.
public struct QualityPolicy: Equatable, Sendable {
    /// Segments with a lower average token log-probability are flagged as low confidence.
    public var minAvgLogprob: Double
    /// Segments with a higher gzip compression ratio are flagged as repetitive.
    public var maxCompressionRatio: Double
    /// With low confidence, a no-speech probability above this marks a likely hallucination in silence.
    public var silenceNoSpeechProb: Double
    /// Words below this probability flag their segment.
    public var minWordProbability: Double

    public static let standard = QualityPolicy()

    public init(
        minAvgLogprob: Double = -1.0,
        maxCompressionRatio: Double = 2.4,
        silenceNoSpeechProb: Double = 0.6,
        minWordProbability: Double = 0.5
    ) {
        self.minAvgLogprob = minAvgLogprob
        self.maxCompressionRatio = maxCompressionRatio
        self.silenceNoSpeechProb = silenceNoSpeechProb
        self.minWordProbability = minWordProbability
    }

    public func flags(for segment: TranscribedSegment) -> Set<QualityFlag> {
        // Estimated timing stays flagged through later versions; confirming the text does not fix the timing.
        let carried = segment.flags.intersection([.unreliableTiming])
        // Text the user confirmed is ground truth; decoder statistics no longer apply to it.
        if segment.flags.contains(.userVerified) {
            return carried.union([.userVerified])
        }
        var flags = carried
        let lowConfidence = segment.avgLogprob.map { $0 < minAvgLogprob } ?? false
        if lowConfidence {
            flags.insert(.lowConfidence)
        }
        if let ratio = segment.compressionRatio, ratio > maxCompressionRatio {
            flags.insert(.repetitive)
        }
        if let noSpeech = segment.noSpeechProb, noSpeech > silenceNoSpeechProb, lowConfidence {
            flags.insert(.likelySilence)
        }
        if let temperature = segment.temperature, temperature > 0 {
            flags.insert(.temperatureFallback)
        }
        if segment.words.contains(where: { ($0.probability ?? 1) < minWordProbability }) {
            flags.insert(.uncertainWords)
        }
        return flags
    }

    /// Decoder statistics typical of hallucinated text: low average confidence or repetition loops.
    public func isLikelyHallucination(_ segment: TranscribedSegment) -> Bool {
        let lowConfidence = segment.avgLogprob.map { $0 < minAvgLogprob } ?? false
        let repetitive = segment.compressionRatio.map { $0 > maxCompressionRatio } ?? false
        return lowConfidence || repetitive
    }
}
