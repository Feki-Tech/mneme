import Foundation
import XCTest
@testable import MnemeCore

final class TranscriptSanitizerTests: XCTestCase {
    private let sanitizer = TranscriptSanitizer()

    func testCleanTextRemovesTokensControlCharactersAndAppliesNFC() {
        let cleaned = TranscriptSanitizer.cleanText("<|en|> Cafe\u{301}\u{0}  au\tlait <|0.00|>")
        XCTAssertEqual(Array(cleaned.unicodeScalars), Array("Caf\u{E9} au lait".unicodeScalars))
    }

    func testDropsEmptySegmentsAndReindexes() throws {
        let input = Fixtures.transcript(with: [
            Fixtures.segment(0, 0, 1, "<|startoftranscript|> Hello   world"),
            Fixtures.segment(1, 1, 2, "  <|nospeech|> "),
            Fixtures.segment(2, 2, 3, "Bye."),
        ])
        let (output, report) = try sanitizer.sanitize(input, duration: 3)
        XCTAssertEqual(output.segments.map { $0.text }, ["Hello world", "Bye."])
        XCTAssertEqual(output.segments.map { $0.index }, [0, 1])
        XCTAssertEqual(report.droppedEmptySegments, 1)
        XCTAssertFalse(report.isClean)
    }

    func testClampsSmallOvershootAndDropsHallucinationsBeyondTheEnd() throws {
        var hallucination = Fixtures.segment(2, 4.5, 5.0, "Thanks for watching.")
        hallucination.avgLogprob = -1.4
        let input = Fixtures.transcript(with: [
            Fixtures.segment(0, 0, 2.2, "Inside."),
            Fixtures.segment(1, 2.2, 3.3, "Overshoot."),
            hallucination,
        ])
        let (output, report) = try sanitizer.sanitize(input, duration: 3.0)
        XCTAssertEqual(output.segments.map { $0.text }, ["Inside.", "Overshoot."])
        XCTAssertEqual(output.segments[1].end, 3.0)
        XCTAssertEqual(report.droppedOutOfRangeSegments, 1)
        XCTAssertEqual(report.clampedTimestamps, 1)
        XCTAssertEqual(report.estimatedTimingSegments, 0)
    }

    func testKeepsConfidentSpeechWithImpossibleTimestamps() throws {
        // Observed with WhisperKit when a prompt disabled its timestamp rules: the right text, placed at 29.3–30.0 s.
        var segment = Fixtures.segment(0, 29.32, 29.98, " Guten Morgen, ich heiße Jonas und wohne seit langem in Hamburg.")
        segment.words = [TranscribedWord(text: "Guten", start: 29.32, end: 29.4, probability: 0.9)]
        let (output, report) = try sanitizer.sanitize(Fixtures.transcript(with: [segment], language: "de"), duration: 3.9)
        XCTAssertEqual(output.segments.count, 1)
        XCTAssertEqual(output.segments[0].text, "Guten Morgen, ich heiße Jonas und wohne seit langem in Hamburg.")
        XCTAssertEqual(output.segments[0].start, 0)
        XCTAssertEqual(output.segments[0].end, 3.9)
        XCTAssertTrue(output.segments[0].words.isEmpty)
        XCTAssertEqual(output.segments[0].flags, [.unreliableTiming])
        XCTAssertEqual(output.flaggedSegmentCount, 1)
        XCTAssertEqual(report.estimatedTimingSegments, 1)
        XCTAssertEqual(report.droppedOutOfRangeSegments, 0)
    }

    func testEstimatedTimingFollowsThePreviousSegment() throws {
        let input = Fixtures.transcript(with: [
            Fixtures.segment(0, 0, 2.0, "First part."),
            Fixtures.segment(1, 29.0, 29.9, "Second part."),
        ])
        let (output, _) = try sanitizer.sanitize(input, duration: 5.0)
        XCTAssertEqual(output.segments.map { $0.text }, ["First part.", "Second part."])
        XCTAssertEqual(output.segments[1].start, 2.0)
        XCTAssertEqual(output.segments[1].end, 5.0)
        XCTAssertEqual(output.segments[0].flags, [])
        XCTAssertEqual(output.segments[1].flags, [.unreliableTiming])
    }

    func testSanitizingTwiceChangesNothing() throws {
        var late = Fixtures.segment(3, 29.0, 29.5, "Late but confident.")
        late.words = [TranscribedWord(text: "Late", start: 29.0, end: 29.2, probability: 0.9)]
        var uncertain = Fixtures.segment(1, 1.0, 2.0, "Mm hmm.")
        uncertain.avgLogprob = -1.3
        let messy = Fixtures.transcript(with: [
            Fixtures.segment(2, 2.0, 3.2, "<|en|> Second."),
            uncertain,
            Fixtures.segment(0, -0.2, 1.1, "First."),
            late,
        ])
        let once = try sanitizer.sanitize(messy, duration: 3.0).transcript
        let (twice, report) = try sanitizer.sanitize(once, duration: 3.0)
        XCTAssertEqual(twice, once)
        XCTAssertTrue(report.isClean, report.summary)
        XCTAssertEqual(once.segments.last?.flags, [.unreliableTiming])
    }

    func testRejectsCorruptTimestamps() {
        XCTAssertThrowsError(try sanitizer.sanitize(Fixtures.transcript(with: [Fixtures.segment(0, .nan, 1, "x")]), duration: nil))
        XCTAssertThrowsError(try sanitizer.sanitize(Fixtures.transcript(with: [Fixtures.segment(0, 0, .infinity, "x")]), duration: nil))
        XCTAssertThrowsError(try sanitizer.sanitize(Fixtures.transcript(with: [Fixtures.segment(0, -2, 1, "x")]), duration: nil))
        XCTAssertThrowsError(try sanitizer.sanitize(Fixtures.transcript(with: [Fixtures.segment(0, 5, 2, "x")]), duration: nil))
    }

    func testRepairsSmallTimestampErrors() throws {
        let input = Fixtures.transcript(with: [
            Fixtures.segment(0, -0.2, 1, "Starts slightly early."),
            Fixtures.segment(1, 2.0, 1.8, "Ends slightly early."),
        ])
        let (output, report) = try sanitizer.sanitize(input, duration: nil)
        XCTAssertEqual(output.segments[0].start, 0)
        XCTAssertEqual(output.segments[1].end, output.segments[1].start)
        XCTAssertEqual(report.clampedTimestamps, 2)
    }

    func testReordersSegmentsAndResolvesOverlaps() throws {
        let input = Fixtures.transcript(with: [
            Fixtures.segment(0, 5, 8, "Third."),
            Fixtures.segment(1, 0, 3, "First."),
            Fixtures.segment(2, 2, 6, "Second."),
        ])
        let (output, report) = try sanitizer.sanitize(input, duration: 10)
        XCTAssertEqual(output.segments.map { $0.text }, ["First.", "Second.", "Third."])
        XCTAssertTrue(report.reorderedSegments)
        XCTAssertEqual(output.segments[0].end, 2)
        XCTAssertEqual(output.segments[1].end, 5)
        XCTAssertEqual(report.clampedTimestamps, 2)
    }

    func testDropsInconsistentWordTimingsButKeepsTheText() throws {
        // Word times relative to a chunk instead of the file: they fall outside their segment.
        var segment = Fixtures.segment(0, 10, 12, "Hello world.")
        segment.words = [
            TranscribedWord(text: "Hello", start: 0.1, end: 0.5, probability: 0.9),
            TranscribedWord(text: "world.", start: 0.5, end: 1.0, probability: 0.9),
        ]
        let (output, report) = try sanitizer.sanitize(Fixtures.transcript(with: [segment]), duration: 20)
        XCTAssertEqual(output.segments[0].text, "Hello world.")
        XCTAssertTrue(output.segments[0].words.isEmpty)
        XCTAssertEqual(report.droppedWordTimings, 2)
    }

    func testClampsWordsSlightlyOutsideTheirSegment() throws {
        var segment = Fixtures.segment(0, 1, 2, "Hello world.")
        segment.words = [
            TranscribedWord(text: " Hello", start: 0.9, end: 1.4, probability: 1.3),
            TranscribedWord(text: "world.", start: 1.4, end: 2.2, probability: 0.8),
        ]
        let (output, report) = try sanitizer.sanitize(Fixtures.transcript(with: [segment]), duration: 3)
        let words = output.segments[0].words
        XCTAssertEqual(words.map { $0.text }, ["Hello", "world."])
        XCTAssertEqual(words[0].start, 1)
        XCTAssertEqual(words[1].end, 2)
        XCTAssertEqual(words[0].probability, 1)
        XCTAssertEqual(report.droppedWordTimings, 0)
    }

    func testComputesQualityFlags() throws {
        var segment = Fixtures.segment(0, 0, 2, "Mm hmm.")
        segment.avgLogprob = -1.4
        segment.noSpeechProb = 0.8
        segment.compressionRatio = 2.8
        segment.temperature = 0.4
        segment.words = [TranscribedWord(text: "Mm", start: 0, end: 0.5, probability: 0.2)]
        let (output, _) = try sanitizer.sanitize(Fixtures.transcript(with: [segment]), duration: 2)
        XCTAssertEqual(output.segments[0].flags, [.lowConfidence, .likelySilence, .repetitive, .temperatureFallback, .uncertainWords])
        XCTAssertEqual(output.flaggedSegmentCount, 1)
    }

    func testSegmentLanguagesAreValidatedAndAMixedTranscriptIsRelabelled() throws {
        var french = Fixtures.segment(0, 0, 3, "Bonjour à tous.")
        french.language = "<|fr|>"
        var english = Fixtures.segment(1, 3, 4, "Hello.")
        english.language = "en"
        var unknown = Fixtures.segment(2, 4, 5, "Hm.")
        unknown.language = "xx"
        let input = Transcript(
            language: LanguageDecision(code: "en", probability: 0.9, source: .mixed),
            segments: [french, english, unknown],
            provenance: Provenance(engine: "test-engine", modelID: "test-model")
        )
        let (once, _) = try sanitizer.sanitize(input, duration: 5)
        XCTAssertEqual(once.segments.map { $0.language }, ["fr", "en", nil])
        XCTAssertEqual(once.language.code, "fr")
        XCTAssertEqual(once.language.probability ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(once.speechByLanguage.map { $0.code }, ["fr", "en"])
        let (twice, _) = try sanitizer.sanitize(once, duration: 5)
        XCTAssertEqual(twice, once, "Sanitising is idempotent")
    }

    func testUserVerifiedSegmentsKeepOnlyTheirFlag() throws {
        var segment = Fixtures.segment(0, 0, 2, "Verified.")
        segment.avgLogprob = -3
        segment.flags = [.userVerified, .lowConfidence]
        let (output, _) = try sanitizer.sanitize(Fixtures.transcript(with: [segment]), duration: 2)
        XCTAssertEqual(output.segments[0].flags, [.userVerified])
        XCTAssertEqual(output.flaggedSegmentCount, 0)
    }

    func testNormalisesLanguageAndRejectsUnsupportedOnes() throws {
        var input = Fixtures.transcript(with: [Fixtures.segment(0, 0, 1, "Bonjour.")])
        input.language = LanguageDecision(code: "<|fr|>", probability: 1.7, source: .detected, modelTopCode: "xx")
        let (output, _) = try sanitizer.sanitize(input, duration: 1)
        XCTAssertEqual(output.language.code, "fr")
        XCTAssertEqual(output.language.probability, 1)
        XCTAssertNil(output.language.modelTopCode)

        input.language.code = "klingon"
        XCTAssertThrowsError(try sanitizer.sanitize(input, duration: 1)) { error in
            XCTAssertEqual(error as? ArchiveError, .invalidLanguageCode("klingon"))
        }
    }

    func testMissingProvenanceIsRejected() {
        var input = Fixtures.transcript(with: [Fixtures.segment(0, 0, 1, "Hello.")])
        input.provenance = Provenance(engine: " ", modelID: "model")
        XCTAssertThrowsError(try sanitizer.sanitize(input, duration: 1))
    }

    func testEmptyTranscriptIsValid() throws {
        let (output, report) = try sanitizer.sanitize(Fixtures.transcript(with: []), duration: 4)
        XCTAssertTrue(output.segments.isEmpty)
        XCTAssertEqual(output.text, "")
        XCTAssertTrue(report.isClean)
    }

    func testNonFiniteMetricsBecomeNil() throws {
        var segment = Fixtures.segment(0, 0, 1, "Hello.")
        segment.avgLogprob = .nan
        segment.compressionRatio = .infinity
        segment.noSpeechProb = -0.5
        let (output, _) = try sanitizer.sanitize(Fixtures.transcript(with: [segment]), duration: 1)
        XCTAssertNil(output.segments[0].avgLogprob)
        XCTAssertNil(output.segments[0].compressionRatio)
        XCTAssertEqual(output.segments[0].noSpeechProb, 0)
    }
}
