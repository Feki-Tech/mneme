import Foundation
import XCTest
@testable import MnemeCore

/// The promotion gate: absolute bars always, relative regressions only against a baseline that measured the same data.
final class EvalGateTests: XCTestCase {
    private let platform = PlatformInfo(os: "macOS 26.5.2", architecture: "arm64", machine: "Mac16,1")

    /// One result per (accent, language, words in the reference, word errors, character errors).
    private func report(
        _ rows: [(accent: String, language: String, words: Int, errors: Int, characterErrors: Int)],
        dataset: String = "aaaaaaaaaaaa",
        fingerprint: String? = "0123456789ab",
        failed: Int = 0,
        mismatches: Int = 0
    ) -> EvalRunReport {
        var results: [EvalResult] = rows.enumerated().map { index, row in
            let item = EvalItem(id: "item-\(index)", audio: "/tmp/\(index).wav", text: "reference", language: row.language, accent: row.accent)
            return EvalResult(
                item: item,
                hypothesis: "hypothesis",
                detectedLanguage: row.language,
                words: EditCounts(substitutions: row.errors, referenceLength: row.words),
                characters: EditCounts(substitutions: row.characterErrors, referenceLength: row.words * 5)
            )
        }
        for index in 0..<mismatches {
            results[index].detectedLanguage = "xx"
        }
        for index in 0..<failed {
            results.append(EvalResult(item: EvalItem(audio: "/tmp/failed-\(index).wav", text: "reference", language: "en"), error: "unreadable"))
        }
        return EvalRunReport(
            started: Date(timeIntervalSince1970: 1_794_000_000),
            durationSeconds: 60,
            model: .init(profile: "fast", variant: "large-v3-v20240930_626MB", fingerprint: fingerprint),
            decoding: .init(languageMode: "reference", languageStrategy: "window", languageProfile: [], glossaryTerms: 0),
            dataset: .init(name: "say", items: results.count, fingerprint: dataset),
            platform: platform,
            summary: EvalReporter.summarize(results)
        )
    }

    private let baselineRows: [(accent: String, language: String, words: Int, errors: Int, characterErrors: Int)] = [
        ("en_GB", "en", 100, 1, 2),
        ("en_IN", "en", 100, 2, 3),
        ("fr_FR", "fr", 15, 0, 0),
        ("zh_CN", "zh", 1, 0, 1),
    ]

    func testAnIdenticalRunPasses() {
        let baseline = report(baselineRows)
        let outcome = EvalGate().evaluate(report(baselineRows), against: baseline)
        XCTAssertTrue(outcome.passed, outcome.lines.joined(separator: "\n"))
        XCTAssertTrue(outcome.compared)
        XCTAssertEqual(outcome.lines.last, "PASS overall WER 1.4% (baseline 1.4%)")
    }

    func testOneFlippedWordInASmallGroupIsTolerated() {
        var rows = baselineRows
        rows[2].errors = 1
        let outcome = EvalGate().evaluate(report(rows), against: report(baselineRows))
        XCTAssertTrue(outcome.passed, outcome.lines.joined(separator: "\n"))
    }

    func testAGroupRegressionIsRefused() {
        var rows = baselineRows
        rows[2].errors = 2
        let outcome = EvalGate().evaluate(report(rows), against: report(baselineRows))
        XCTAssertFalse(outcome.passed)
        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("FAIL accent \"fr_FR\"") }, outcome.lines.joined(separator: "\n"))
        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("FAIL language \"fr\"") }, outcome.lines.joined(separator: "\n"))
    }

    func testAnOverallRegressionIsRefused() {
        var rows = baselineRows
        rows[0].errors = 4
        rows[1].errors = 4
        let outcome = EvalGate().evaluate(report(rows), against: report(baselineRows))
        XCTAssertFalse(outcome.passed)
        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("FAIL overall WER regressed from 1.4% to 3.7%") }, outcome.lines.joined(separator: "\n"))
    }

    func testLanguagesWithoutSpacesAreJudgedOnCharacters() {
        var rows = baselineRows
        // The single "word" of a Chinese sentence flips from right to wrong; one more character error of five.
        rows[3].errors = 1
        rows[3].characterErrors = 2
        let outcome = EvalGate().evaluate(report(rows), against: report(baselineRows))
        XCTAssertTrue(outcome.passed, outcome.lines.joined(separator: "\n"))
        XCTAssertTrue(EvalGate.writtenWithoutSpaces("zh_CN"))
        XCTAssertTrue(EvalGate.writtenWithoutSpaces("ja"))
        XCTAssertFalse(EvalGate.writtenWithoutSpaces("en_IN"))
        XCTAssertFalse(EvalGate.writtenWithoutSpaces("mymensingh"))
    }

    func testLanguageErrorsAndFailuresAreRefused() {
        let baseline = report(baselineRows)
        let wrongLanguage = EvalGate().evaluate(report(baselineRows, mismatches: 1), against: baseline)
        XCTAssertFalse(wrongLanguage.passed)
        XCTAssertTrue(wrongLanguage.lines.contains { $0.hasPrefix("FAIL items decoded in the wrong language") })

        let failed = EvalGate().evaluate(report(baselineRows, failed: 1), against: nil)
        XCTAssertFalse(failed.passed)
        XCTAssertTrue(failed.lines.contains("FAIL 1 of 5 items could not be transcribed"), failed.lines.joined(separator: "\n"))
    }

    func testOtherDataOnlyFacesTheAbsoluteBar() {
        var rows = baselineRows
        rows[0].errors = 8
        let outcome = EvalGate().evaluate(report(rows, dataset: "bbbbbbbbbbbb"), against: report(baselineRows))
        XCTAssertTrue(outcome.passed, outcome.lines.joined(separator: "\n"))
        XCTAssertFalse(outcome.compared)
        XCTAssertTrue(outcome.lines.contains { $0.contains("absolute bars only") })

        rows[0].errors = 40
        let tooMany = EvalGate().evaluate(report(rows, dataset: "bbbbbbbbbbbb"), against: report(baselineRows))
        XCTAssertFalse(tooMany.passed)
        XCTAssertTrue(tooMany.lines.contains { $0.hasPrefix("FAIL overall WER") && $0.contains("above the bar") })
    }

    func testAChangedModelIsNotedButStillCompared() {
        let outcome = EvalGate().evaluate(report(baselineRows, fingerprint: "ffffffffffff"), against: report(baselineRows))
        XCTAssertTrue(outcome.passed)
        XCTAssertTrue(outcome.compared)
        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("note: model differs") })
    }

    func testReportRoundTripAndDatasetFingerprint() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = report(baselineRows)
        let url = directory.appendingPathComponent("baselines/say.fast.json")
        try original.write(to: url)
        XCTAssertEqual(try EvalRunReport.read(from: url), original)

        let first = directory.appendingPathComponent("a.wav")
        let second = directory.appendingPathComponent("b.wav")
        try Fixtures.writeTone(to: first, seconds: 1, frequency: 440)
        try Fixtures.writeTone(to: second, seconds: 1, frequency: 660)
        let items = [
            EvalItem(id: "a", audio: first.path, text: "One.", language: "en"),
            EvalItem(id: "b", audio: second.path, text: "Two.", language: "en"),
        ]
        let fingerprint = EvalDataset.fingerprint(items)
        XCTAssertEqual(fingerprint.count, 12)
        XCTAssertEqual(EvalDataset.fingerprint(items.reversed()), fingerprint, "order must not matter")
        var moved = items
        let copy = directory.appendingPathComponent("elsewhere/a.wav")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first, to: copy)
        moved[0].audio = copy.path
        XCTAssertEqual(EvalDataset.fingerprint(moved), fingerprint, "the same audio elsewhere is the same data")
        moved[1].text = "Three."
        XCTAssertNotEqual(EvalDataset.fingerprint(moved), fingerprint)

        XCTAssertEqual(EvalDataset.name(forManifest: URL(fileURLWithPath: "/x/eval/say/manifest.jsonl")), "say")
        XCTAssertEqual(EvalDataset.name(forManifest: URL(fileURLWithPath: "/x/eval/verified.jsonl")), "verified")
    }
}
