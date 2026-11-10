import Foundation
import XCTest
@testable import MnemeCore

/// Small, fast and reproducible pseudo-random numbers for property tests (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Seeded property tests, without dependencies: invariants checked on many generated inputs rather than on a few
/// hand-written examples. Every failure message names the seed and the case, so it can be replayed exactly; set
/// PROPERTY_SEED to explore other inputs (`PROPERTY_SEED=7 swift test --filter PropertyTests`).
final class PropertyTests: XCTestCase {
    private var seed: UInt64 {
        ProcessInfo.processInfo.environment["PROPERTY_SEED"].flatMap { UInt64($0) } ?? 20_261_110
    }

    // MARK: - Error rates

    /// The alignment behind WER and CER agrees with an independent Levenshtein distance, and its breakdown into
    /// substitutions, deletions and insertions is consistent.
    func testAlignmentAgreesWithALevenshteinOracle() {
        var random = SplitMix64(seed: seed)
        let alphabet = ["a", "b", "c", "d"]
        for index in 0..<400 {
            let reference = (0..<Int.random(in: 0...12, using: &random)).map { _ in alphabet.randomElement(using: &random)! }
            let hypothesis = (0..<Int.random(in: 0...12, using: &random)).map { _ in alphabet.randomElement(using: &random)! }
            let counts = ErrorRate.align(reference: reference, hypothesis: hypothesis)
            let context = "seed \(seed), case \(index): \(reference) / \(hypothesis)"
            XCTAssertEqual(counts.errors, Self.levenshtein(reference, hypothesis), context)
            XCTAssertEqual(counts.referenceLength, reference.count, context)
            // Every reference token is matched, substituted or deleted; every hypothesis token matched, substituted
            // or inserted. Both counts share the matches.
            XCTAssertEqual(counts.deletions - counts.insertions, reference.count - hypothesis.count, context)
            XCTAssertLessThanOrEqual(counts.substitutions + counts.deletions, reference.count, context)
            XCTAssertLessThanOrEqual(counts.substitutions + counts.insertions, hypothesis.count, context)
            XCTAssertEqual(ErrorRate.align(reference: hypothesis, hypothesis: reference).errors, counts.errors, context)
            XCTAssertEqual(ErrorRate.align(reference: reference, hypothesis: reference).errors, 0, context)
        }
    }

    private static func levenshtein(_ first: [String], _ second: [String]) -> Int {
        var previous = Array(0...second.count)
        for (row, left) in first.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: second.count)
            for (column, right) in second.enumerated() {
                current[column + 1] = min(previous[column + 1] + 1, current[column] + 1, previous[column] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[second.count]
    }

    // MARK: - Text normalisation

    /// Normalising twice changes nothing, the result has single spaces only, and a text compared with its own
    /// normalised form has no errors: on generated text mixing scripts, combining marks, punctuation, annotations
    /// and odd whitespace.
    func testNormalisationIsIdempotent() {
        var random = SplitMix64(seed: seed)
        let letters = ["a", "b", "z", "é", "ç", "ß", "ø", "Ł", "A", "Z", "É", "ا", "ب", "ت", "क", "ख", "中", "文", "日", "ж", "Я", "ﬁ", "7"]
        let marks = ["\u{0301}", "\u{0308}", "\u{064E}", "\u{093E}"]
        let separators = [" ", "  ", "\t", "\n", "\u{00A0}", ",", ".", "!", "?", ";", "—", "-", "«", "»", "“", "”", "'", "’", "(", ")", "[", "]", "/", "…"]
        let annotations = ["[noise]", "(laughs)", "<unk>"]
        for index in 0..<400 {
            var text = ""
            for _ in 0..<Int.random(in: 0...10, using: &random) {
                for _ in 0..<Int.random(in: 1...6, using: &random) {
                    text += letters.randomElement(using: &random)!
                    if Int.random(in: 0..<5, using: &random) == 0 {
                        text += marks.randomElement(using: &random)!
                    }
                }
                if Int.random(in: 0..<10, using: &random) == 0 {
                    text += " \(annotations.randomElement(using: &random)!) "
                }
                text += separators.randomElement(using: &random)!
            }
            let once = TextNormalizer.normalize(text)
            let context = "seed \(seed), case \(index): \(text.debugDescription)"
            XCTAssertEqual(TextNormalizer.normalize(once), once, context)
            XCTAssertFalse(once.hasPrefix(" ") || once.hasSuffix(" ") || once.contains("  "), context)
            XCTAssertEqual(ErrorRate.wordErrors(reference: text, hypothesis: once).errors, 0, context)
            XCTAssertEqual(ErrorRate.characterErrors(reference: text, hypothesis: once).errors, 0, context)
        }
    }

    // MARK: - Speech windows

    /// On generated recordings of speech bursts and pauses at known positions: the windows tile the recording,
    /// never exceed the maximum, are cut inside pauses unless the maximum forces a cut, and are deterministic.
    func testSpeechWindowsTileTheRecordingAndCutInPauses() {
        var random = SplitMix64(seed: seed)
        let sampleRate = 8_000.0
        let windowing = SpeechWindowing(sampleRate: sampleRate)
        let maximum = Int(windowing.maximumWindow * sampleRate)
        let noise = (0..<4_096).map { _ in Float.random(in: -1...1, using: &random) }

        for index in 0..<25 {
            var samples: [Float] = []
            var pauses: [Range<Int>] = []
            let digitalSilence = Bool.random(using: &random)
            let target = Int(Double.random(in: 1...70, using: &random) * sampleRate)
            while samples.count < target {
                // Speech: a tone with a little noise, from a fifth of a second to longer than the maximum window.
                let long = Int.random(in: 0..<10, using: &random) == 0
                let speech = Int((long ? Double.random(in: 28...35, using: &random) : Double.random(in: 0.2...6, using: &random)) * sampleRate)
                let amplitude = Float.random(in: 0.2...0.5, using: &random)
                let step = 2 * Float.pi * Float.random(in: 120...900, using: &random) / Float(sampleRate)
                samples.reserveCapacity(samples.count + speech)
                for sample in 0..<speech {
                    samples.append(amplitude * sin(step * Float(sample)) + 0.02 * noise[sample & 4_095])
                }
                // A pause: exact zeros, or room noise about 50 dB below the speech.
                let pause = Int(Double.random(in: 0.05...1.5, using: &random) * sampleRate)
                let start = samples.count
                for sample in 0..<pause {
                    samples.append(digitalSilence ? 0 : 0.001 * noise[(start + sample) & 4_095])
                }
                pauses.append(start..<samples.count)
            }

            let windows = windowing.windows(for: samples)
            let context = "seed \(seed), case \(index) (\(samples.count) samples, digital silence: \(digitalSilence))"
            XCTAssertEqual(windows.first?.lowerBound, 0, context)
            XCTAssertEqual(windows.last?.upperBound, samples.count, context)
            XCTAssertTrue(windows.allSatisfy { !$0.isEmpty && $0.count <= maximum }, context)
            for (window, next) in zip(windows, windows.dropFirst()) {
                XCTAssertEqual(window.upperBound, next.lowerBound, context)
                let cut = window.upperBound
                let forced = window.count == maximum
                XCTAssertTrue(forced || pauses.contains { $0.contains(cut) }, "\(context): cut at \(Double(cut) / sampleRate) s is not in a pause")
            }
            XCTAssertEqual(windowing.windows(for: samples), windows, context)
        }
    }

    /// Silence alone is cut only by the maximum window length.
    func testSilenceIsCutOnlyByTheMaximum() {
        var random = SplitMix64(seed: seed)
        let windowing = SpeechWindowing(sampleRate: 8_000)
        let maximum = Int(windowing.maximumWindow * 8_000)
        for index in 0..<20 {
            let count = Int.random(in: 1...(maximum * 4), using: &random)
            let windows = windowing.windows(for: [Float](repeating: 0, count: count))
            let context = "seed \(seed), case \(index): \(count) samples"
            XCTAssertEqual(windows.count, (count + maximum - 1) / maximum, context)
            XCTAssertTrue(windows.dropLast().allSatisfy { $0.count == maximum }, context)
            XCTAssertEqual(windows.last?.upperBound, count, context)
        }
        XCTAssertEqual(windowing.windows(for: []), [])
    }

    // MARK: - Manifests and languages

    /// Evaluation manifests survive a write and a read, whatever their text, paths and optional fields.
    func testManifestsRoundTrip() throws {
        var random = SplitMix64(seed: seed)
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("eval/manifest.jsonl")
        let languages = ["en", "fr", "de", "ar", "zh", "hi"]
        let fragments = ["Bonjour", "l'été", "naïve", "\"quoted\"", "tab\there", "new\nline", "مرحبا", "नमस्ते", "中文", "#hash", "back\\slash", "emoji 🙂"]
        for index in 0..<40 {
            let items = (0..<Int.random(in: 1...8, using: &random)).map { position -> EvalItem in
                let audio = Bool.random(using: &random)
                    ? directory.appendingPathComponent("eval/clips/c\(index)-\(position).wav").path
                    : "/elsewhere/case \(index)/c\(position).wav"
                let start: Double? = Bool.random(using: &random) ? Double(Int.random(in: 0...100, using: &random)) / 4 : nil
                let end = start.map { $0 + Double(Int.random(in: 1...40, using: &random)) / 4 }
                let text = (0..<Int.random(in: 1...4, using: &random)).map { _ in fragments.randomElement(using: &random)! }.joined(separator: " ")
                return EvalItem(
                    id: Bool.random(using: &random) ? "item-\(index)-\(position)" : nil,
                    audio: audio,
                    text: text,
                    language: Bool.random(using: &random) ? languages.randomElement(using: &random) : nil,
                    accent: Bool.random(using: &random) ? "accent \(position)" : nil,
                    speaker: Bool.random(using: &random) ? "speaker \(position)" : nil,
                    start: start,
                    end: end
                )
            }
            try Manifest.write(items, to: url)
            var expected = items
            for position in expected.indices {
                expected[position].audio = URL(fileURLWithPath: expected[position].audio).standardizedFileURL.path
            }
            XCTAssertEqual(try Manifest.read(url), expected, "seed \(seed), case \(index)")
        }
    }

    /// Language resolution only ever yields languages Whisper supports, and resolving a result again keeps it.
    func testLanguageResolutionIsClosedAndStable() {
        var random = SplitMix64(seed: seed)
        for (code, name) in WhisperLanguages.names {
            XCTAssertEqual(LanguagePolicy.resolve(code), code)
            XCTAssertEqual(LanguagePolicy.resolve(name), code, name)
            XCTAssertEqual(LanguagePolicy.resolve("<|\(code)|>"), code)
        }
        let pieces = Array(WhisperLanguages.names.keys) + ["", " ", "-", "_", "<|", "|>", "x", "zz", "fra", "pt-BR", "EN", "français", "Ελληνικά", "123"]
        for index in 0..<500 {
            let input = (0..<Int.random(in: 1...3, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
            let context = "seed \(seed), case \(index): \(input.debugDescription)"
            guard let code = LanguagePolicy.resolve(input) else { continue }
            XCTAssertNotNil(WhisperLanguages.names[code], context)
            XCTAssertEqual(LanguagePolicy.resolve(code), code, context)
        }
    }
}
