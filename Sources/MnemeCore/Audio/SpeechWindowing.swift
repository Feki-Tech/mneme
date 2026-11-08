import Foundation

/// Splits a recording into windows at pauses so that each window holds about one sentence of speech.
///
/// Used for speakers who switch languages: Whisper identifies one language per window, so the windows must
/// follow sentences rather than fixed 30-second slices. The windows tile the whole recording (nothing is
/// skipped), are cut in the middle of pauses, and never exceed Whisper's 30-second window.
public struct SpeechWindowing: Sendable {
    public var sampleRate: Double
    /// Frame length of the energy envelope.
    public var frameSeconds: Double
    /// Silences at least this long can end a window.
    public var minimumPause: Double
    /// A window ends at the first pause after it holds this much speech (from its first voiced frame to the
    /// pause). Shorter windows give language identification too little to go on.
    public var minimumSpeech: Double
    /// The longest window: Whisper sees 30 seconds, minus a margin.
    public var maximumWindow: Double

    public init(
        sampleRate: Double = 16_000,
        frameSeconds: Double = 0.02,
        minimumPause: Double = 0.35,
        minimumSpeech: Double = 2,
        maximumWindow: Double = 28
    ) {
        self.sampleRate = sampleRate
        self.frameSeconds = frameSeconds
        self.minimumPause = minimumPause
        self.minimumSpeech = minimumSpeech
        self.maximumWindow = maximumWindow
    }

    /// Sample ranges that tile `0..<samples.count`, in order.
    public func windows(for samples: [Float]) -> [Range<Int>] {
        let count = samples.count
        guard count > 0 else { return [] }
        let frameLength = max(1, Int((frameSeconds * sampleRate).rounded()))
        let maximum = max(frameLength, Int(maximumWindow * sampleRate))
        let voiced = voicedFrames(samples, frameLength: frameLength)

        // Speech in a stretch is measured from its first voiced frame to its end, so the short gaps between
        // words count as speech. `nextVoiced[f]` is the first voiced frame at or after frame f.
        var nextVoiced = [Int](repeating: voiced.count, count: voiced.count + 1)
        for frame in stride(from: voiced.count - 1, through: 0, by: -1) {
            nextVoiced[frame] = voiced[frame] ? frame : nextVoiced[frame + 1]
        }
        func speechSeconds(from start: Int, to end: Int) -> Double {
            let first = nextVoiced[min(voiced.count, start / frameLength)]
            let last = min(voiced.count, end / frameLength)
            return last > first ? Double(last - first) * Double(frameLength) / sampleRate : 0
        }

        var cuts: [Int] = []
        var start = 0
        var pending: Int?
        func enforceMaximum(upTo position: Int) {
            while position - start > maximum {
                if let candidate = pending, candidate > start {
                    cuts.append(candidate)
                    start = candidate
                } else {
                    // No pause within reach: cut at the maximum.
                    cuts.append(start + maximum)
                    start += maximum
                }
                pending = nil
            }
        }
        for pause in pauses(in: voiced, frameLength: frameLength, sampleCount: count) {
            enforceMaximum(upTo: pause.middle)
            guard pause.middle > start else { continue }
            if speechSeconds(from: start, to: pause.start) >= minimumSpeech {
                cuts.append(pause.middle)
                start = pause.middle
                pending = nil
            } else {
                pending = pause.middle
            }
        }
        enforceMaximum(upTo: count)

        // A last window with little speech joins the previous one when the result still fits.
        let speechEnd = min(count, (voiced.lastIndex(of: true).map { $0 + 1 } ?? 0) * frameLength)
        if let last = cuts.last, speechSeconds(from: last, to: speechEnd) < minimumSpeech / 2 {
            let previous = cuts.count >= 2 ? cuts[cuts.count - 2] : 0
            if count - previous <= maximum {
                cuts.removeLast()
            }
        }

        var ranges: [Range<Int>] = []
        var lower = 0
        for cut in cuts + [count] where cut > lower {
            ranges.append(lower..<cut)
            lower = cut
        }
        return ranges
    }

    /// Frames whose energy stands out from the recording's own noise floor.
    func voicedFrames(_ samples: [Float], frameLength: Int) -> [Bool] {
        let frameCount = (samples.count + frameLength - 1) / frameLength
        var levels = [Double](repeating: -140, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                let lower = frame * frameLength
                let upper = min(buffer.count, lower + frameLength)
                var sum = 0.0
                for index in lower..<upper {
                    let value = Double(buffer[index])
                    sum += value * value
                }
                let rms = (sum / Double(max(1, upper - lower))).squareRoot()
                levels[frame] = 20 * log10(max(rms, 1e-7))
            }
        }
        // Digital silence (exact zeros, below -100 dBFS) is never speech, and it says nothing about the room's
        // noise floor, so the floor is estimated on the other frames: pauses take at least 5 % of a recording.
        let digitalSilence = -100.0
        let audible = levels.filter { $0 > digitalSilence }.sorted()
        guard !audible.isEmpty else {
            return Array(repeating: false, count: frameCount)
        }
        let noise = audible[Int(Double(audible.count - 1) * 0.05)]
        let peak = audible[Int(Double(audible.count - 1) * 0.95)]
        var voiced: [Bool]
        if peak - noise < 10 {
            // No clear difference between quiet and loud parts: only digital silence separates speech.
            voiced = levels.map { $0 > digitalSilence }
        } else {
            let threshold = noise + max(6, 0.25 * (peak - noise))
            voiced = levels.map { $0 > threshold }
        }

        // Clicks shorter than 100 ms do not interrupt a pause.
        let minimumBlip = max(1, Int((0.1 / frameSeconds).rounded()))
        var index = 0
        while index < voiced.count {
            guard voiced[index] else {
                index += 1
                continue
            }
            let runStart = index
            while index < voiced.count && voiced[index] {
                index += 1
            }
            if index - runStart < minimumBlip {
                for blip in runStart..<index {
                    voiced[blip] = false
                }
            }
        }
        return voiced
    }

    /// Silences of at least `minimumPause` between speech, as sample positions; leading and trailing silence
    /// are not pauses.
    func pauses(in voiced: [Bool], frameLength: Int, sampleCount: Int) -> [(start: Int, middle: Int)] {
        guard let firstVoiced = voiced.firstIndex(of: true), let lastVoiced = voiced.lastIndex(of: true) else {
            return []
        }
        let minimumFrames = max(1, Int((minimumPause / frameSeconds).rounded()))
        var result: [(start: Int, middle: Int)] = []
        var index = firstVoiced
        while index <= lastVoiced {
            if voiced[index] {
                index += 1
                continue
            }
            let runStart = index
            while index <= lastVoiced && !voiced[index] {
                index += 1
            }
            let length = index - runStart
            if length >= minimumFrames {
                let middle = min(sampleCount, (runStart + length / 2) * frameLength)
                result.append((start: runStart * frameLength, middle: middle))
            }
        }
        return result
    }
}
