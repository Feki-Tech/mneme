import XCTest
@testable import MnemeCore

/// Windows that follow sentences, for speakers who switch languages.
final class SpeechWindowingTests: XCTestCase {
    private let rate = 16_000.0

    /// Tone bursts ("speech") and silences, with optional deterministic background noise.
    private func signal(_ parts: [(seconds: Double, speech: Bool)], noise: Float = 0) -> [Float] {
        var samples: [Float] = []
        var state: UInt32 = 12_345
        for part in parts {
            let count = Int(part.seconds * rate)
            for index in 0..<count {
                var value: Float = part.speech ? Float(0.3 * sin(2 * Double.pi * 220 * Double(index) / rate)) : 0
                if noise > 0 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    value += noise * (Float(state) / Float(UInt32.max) * 2 - 1)
                }
                samples.append(value)
            }
        }
        return samples
    }

    private func assertTiles(_ windows: [Range<Int>], _ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(windows.first?.lowerBound, 0, file: file, line: line)
        XCTAssertEqual(windows.last?.upperBound, count, file: file, line: line)
        for (current, next) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(current.upperBound, next.lowerBound, file: file, line: line)
        }
    }

    func testEachSentenceGetsItsOwnWindowCutInThePause() {
        let samples = signal([(0.3, false), (3.5, true), (0.8, false), (3.5, true), (0.8, false), (3.5, true), (0.3, false)])
        let windows = SpeechWindowing().windows(for: samples)
        XCTAssertEqual(windows.count, 3)
        assertTiles(windows, samples.count)
        XCTAssertEqual(Double(windows[0].upperBound) / rate, 0.3 + 3.5 + 0.4, accuracy: 0.05)
        XCTAssertEqual(Double(windows[1].upperBound) / rate, 0.3 + 3.5 + 0.8 + 3.5 + 0.4, accuracy: 0.05)
    }

    func testShortPhrasesAreGroupedUntilThereIsEnoughSpeech() {
        var parts: [(seconds: Double, speech: Bool)] = [(0.2, false)]
        for _ in 0..<6 {
            parts += [(1.2, true), (0.5, false)]
        }
        let samples = signal(parts)
        let windows = SpeechWindowing().windows(for: samples)
        XCTAssertEqual(windows.count, 3, "Two 1.2 s phrases and the pause between them reach the 2 s minimum")
        assertTiles(windows, samples.count)
    }

    func testLongSpeechWithoutPausesIsCutAtTheMaximum() {
        let samples = signal([(70, true)])
        let windows = SpeechWindowing().windows(for: samples)
        XCTAssertEqual(windows.count, 3)
        XCTAssertTrue(windows.allSatisfy { Double($0.count) / rate <= 28.0001 })
        assertTiles(windows, samples.count)
    }

    func testAPauseIsPreferredToACutInTheMiddleOfSpeech() {
        var windowing = SpeechWindowing()
        windowing.minimumSpeech = 25
        let samples = signal([(20, true), (0.6, false), (20, true)])
        let windows = windowing.windows(for: samples)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(Double(windows[0].upperBound) / rate, 20.3, accuracy: 0.05)
        assertTiles(windows, samples.count)
    }

    func testTheNoiseFloorIsLearnedFromTheRecording() {
        let samples = signal([(0.3, false), (3.5, true), (0.8, false), (3.5, true), (0.3, false)], noise: 0.004)
        XCTAssertEqual(SpeechWindowing().windows(for: samples).count, 2)
    }

    func testALastWindowWithLittleSpeechJoinsThePreviousOne() {
        let samples = signal([(4, true), (0.6, false), (0.8, true), (0.2, false)])
        let windows = SpeechWindowing().windows(for: samples)
        XCTAssertEqual(windows, [0..<samples.count])
    }

    func testEmptyAndShortRecordings() {
        XCTAssertEqual(SpeechWindowing().windows(for: []), [])
        let short = signal([(1, true)])
        XCTAssertEqual(SpeechWindowing().windows(for: short), [0..<short.count])
    }
}
