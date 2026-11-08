import Foundation
import XCTest
@testable import MnemeCore

final class UtilityTests: XCTestCase {
    func testIdentifiersAreTimeOrderedUUIDv7() {
        let earlier = Identifiers.newID(at: Date(timeIntervalSince1970: 1_700_000_000))
        let later = Identifiers.newID(at: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertLessThan(earlier, later)
        for id in [earlier, later] {
            XCTAssertNotNil(id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression), id)
        }
        XCTAssertNotEqual(Identifiers.newID(), Identifiers.newID())
    }

    func testTimestampsRoundTripWithMillisecondPrecision() throws {
        let date = Timestamps.truncated(Date(timeIntervalSince1970: 1_700_000_000.123_456))
        let text = Timestamps.string(date)
        XCTAssertEqual(text, "2023-11-14T22:13:20.123Z")
        let parsed = try XCTUnwrap(Timestamps.date(text))
        XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.000_5)
    }

    func testFileHasher() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mneme-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try FileHasher.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testFTSQueryQuotesEveryWord() {
        XCTAssertEqual(FTSQuery.make("call ste"), "\"call\" \"ste\"*")
        XCTAssertEqual(FTSQuery.make("say \"NEAR\" OR"), "\"say\" \"NEAR\" \"OR\"*")
        XCTAssertNil(FTSQuery.make("   "))
        XCTAssertNil(FTSQuery.make("- ! \""))
    }

    func testPromptBuilderKeepsTheMostRecentTerms() {
        XCTAssertNil(PromptBuilder.promptText(terms: []))
        XCTAssertEqual(PromptBuilder.promptText(terms: ["Stella", " ", "Sfax"]), "Stella, Sfax.")
        let many = (0..<300).map { "Term\($0)" }
        let prompt = PromptBuilder.promptText(terms: many) ?? ""
        XCTAssertLessThanOrEqual(prompt.count, PromptBuilder.maxCharacters + 1)
        XCTAssertTrue(prompt.hasSuffix("Term299."))
        XCTAssertFalse(prompt.contains("Term0,"))
        XCTAssertEqual(PromptBuilder.limit(tokens: Array(0..<500)), Array((500 - PromptBuilder.maxPromptTokens)..<500))
        XCTAssertEqual(PromptBuilder.limit(tokens: [1, 2]), [1, 2])
    }

    func testGlossarySuggestions() {
        XCTAssertEqual(
            GlossarySuggester.suggestions(
                original: "we met jon at the sfax office on route nine",
                corrected: "We met John at the Sfax office on Route 9",
                glossary: ["Sfax"]
            ),
            ["John", "9"],
            "Capitalisation alone (Route) and glossary terms (Sfax) are not suggested"
        )
    }

    func testTextJoinerHandlesUnspacedScripts() {
        XCTAssertEqual(TextJoiner.join([" 你好", "世界 "], language: "zh"), "你好世界")
        XCTAssertEqual(TextJoiner.join([" Hello", "", "world "], language: "en"), "Hello world")
    }

    func testQualityFlagsEncodeDeterministically() {
        let flags: Set<QualityFlag> = [.uncertainWords, .lowConfidence, .repetitive]
        let encoded = QualityFlag.encode(flags)
        XCTAssertEqual(encoded, "low_confidence,repetitive,uncertain_words")
        XCTAssertEqual(QualityFlag.decode(encoded), flags)
        XCTAssertEqual(QualityFlag.decode(""), [])
        XCTAssertEqual(QualityFlag.decode("unknown,repetitive"), [.repetitive])
    }

    func testSanitizationReportSummary() {
        var report = SanitizationReport()
        XCTAssertEqual(report.summary, "clean")
        report.droppedEmptySegments = 2
        report.reorderedSegments = true
        XCTAssertEqual(report.summary, "2 empty segment(s) dropped, segments reordered by time")
    }
}
