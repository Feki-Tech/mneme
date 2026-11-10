import Foundation
import XCTest
@testable import MnemeCore

final class EvaluationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testManifestRoundTripUsesRelativePaths() throws {
        let audio = directory.appendingPathComponent("clips/a.wav")
        let manifestURL = directory.appendingPathComponent("manifest.jsonl")
        let items = [
            EvalItem(id: "a", audio: audio.path, text: "Hello there.", language: "English", accent: "scottish", region: "uk", speaker: "s1", start: 0.5, end: 2),
            EvalItem(audio: "/elsewhere/b.wav", text: "Bonjour.", language: "fr"),
        ]
        try Manifest.write(items, to: manifestURL)
        let raw = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"audio\":\"clips/a.wav\""), raw)
        XCTAssertTrue(raw.contains("\"audio\":\"/elsewhere/b.wav\""), raw)

        let read = try Manifest.read(manifestURL)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read[0].audio, audio.standardizedFileURL.path)
        XCTAssertEqual(read[0].language, "en")
        XCTAssertEqual(read[0].start, 0.5)
        XCTAssertEqual(read[1].audio, "/elsewhere/b.wav")
        XCTAssertNil(read[1].accent)
    }

    func testManifestSkipsCommentsAndReportsTheFailingLine() throws {
        let url = directory.appendingPathComponent("bad.jsonl")
        try Data("# comment\n\n{\"audio\": \"a.wav\", \"text\": \"ok\"}\n{\"audio\": \"b.wav\"}\n".utf8).write(to: url)
        XCTAssertThrowsError(try Manifest.read(url)) { error in
            guard case .invalidManifest(let line, _)? = error as? ArchiveError else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(line, 4)
        }
        try Data("{\"audio\": \"a.wav\", \"text\": \"ok\", \"start\": 3, \"end\": 1}\n".utf8).write(to: url)
        XCTAssertThrowsError(try Manifest.read(url))
        try Data("{\"audio\": \"a.wav\", \"text\": \"ok\", \"language\": \"elvish\"}\n".utf8).write(to: url)
        XCTAssertThrowsError(try Manifest.read(url))
    }

    func testCSVHandlesQuotesCommasNewlinesAndCRLF() {
        let text = "\u{FEFF}name,quote,notes\r\n1,\"x, y\",\"he said \"\"hi\"\"\"\r\n2,,\"two\nlines\"\n\n3,last,\"\""
        let rows = CSV.parse(text)
        XCTAssertEqual(rows, [
            ["name", "quote", "notes"],
            ["1", "x, y", "he said \"hi\""],
            ["2", "", "two\nlines"],
            ["3", "last", ""],
        ])
        let records = CSV.records(text)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0]["quote"], "x, y")
    }

    func testSpeechAccentArchiveManifest() throws {
        let dataset = directory.appendingPathComponent("saa", isDirectory: true)
        let recordings = dataset.appendingPathComponent("recordings/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        for name in ["afrikaans1", "afrikaans2", "afrikaans10", "arabic3"] {
            try Data([1, 2, 3]).write(to: recordings.appendingPathComponent("\(name).mp3"))
        }
        try Data("Please  call\nStella.".utf8).write(to: dataset.appendingPathComponent("reading-passage.txt"))
        let csv = """
            age,age_onset,birthplace,filename,native_language,sex,speakerid,country,file_missing?
            27,9,"virginia, south africa",afrikaans10,afrikaans,female,3,south africa,FALSE
            40,5,"pretoria, south africa",afrikaans1,afrikaans,male,1,south africa,FALSE
            38,6,"cape town, south africa",afrikaans2,afrikaans,female,2,south africa,FALSE
            25,12,"tunis, tunisia",arabic3,arabic,male,9,tunisia,FALSE
            30,10,"cairo, egypt",arabic4,arabic,male,10,egypt,FALSE
            31,10,"sfax, tunisia",arabic5,arabic,female,11,tunisia,TRUE
            """
        try Data(csv.utf8).write(to: dataset.appendingPathComponent("speakers_all.csv"))

        let items = try SpeechAccentArchive.manifest(datasetDirectory: dataset, maxPerAccent: 2)
        XCTAssertEqual(items.map { $0.id }, ["afrikaans1", "afrikaans2", "arabic3"])
        XCTAssertEqual(items[0].text, "Please call Stella.")
        XCTAssertEqual(items[0].language, "en")
        XCTAssertEqual(items[2].accent, "arabic")
        XCTAssertEqual(items[2].region, "tunisia")
        XCTAssertEqual(items[2].speaker, "9")
        XCTAssertTrue(items[0].audio.hasSuffix("afrikaans1.mp3"))
    }

    func testReporterAggregatesWorstFirst() {
        func result(_ accent: String, _ errors: Int, _ length: Int, detected: String = "en", failed: Bool = false) -> EvalResult {
            EvalResult(
                item: EvalItem(audio: "/a.wav", text: "x", language: "en", accent: accent, region: accent == "scottish" ? "uk" : nil),
                hypothesis: "x",
                detectedLanguage: detected,
                words: EditCounts(substitutions: errors, referenceLength: length),
                characters: EditCounts(substitutions: errors, referenceLength: length * 5),
                audioSeconds: 10,
                processingSeconds: 2,
                error: failed ? "boom" : nil
            )
        }
        let results = [
            result("scottish", 1, 10),
            result("scottish", 3, 10),
            result("nigerian", 1, 20, detected: "yo"),
            result("indian", 0, 10),
            result("indian", 0, 10, failed: true),
        ]
        let summary = EvalReporter.summarize(results)
        XCTAssertEqual(summary.overall.items, 5)
        XCTAssertEqual(summary.overall.failed, 1)
        XCTAssertEqual(summary.overall.wer ?? 0, 5.0 / 50.0, accuracy: 1e-12)
        XCTAssertEqual(summary.overall.languageMismatches, 1)
        XCTAssertEqual(summary.byAccent.map { $0.name }, ["scottish", "nigerian", "indian"])
        XCTAssertEqual(summary.byAccent[0].wer ?? 0, 0.2, accuracy: 1e-12)
        XCTAssertEqual(summary.byRegion.map { $0.name }, ["uk", "unknown"])
        XCTAssertEqual(summary.realTimeFactor ?? 0, 0.2, accuracy: 1e-12)

        let markdown = EvalReporter.markdown(summary, settings: [("Model", "test")])
        XCTAssertTrue(markdown.contains("| scottish | 2 | 20.0% |"), markdown)
        XCTAssertTrue(markdown.contains("## By accent (worst first)"))
    }

    /// A recording that switches languages is judged on its sequence of segment languages, not on the single
    /// language of the recording (the longest stretch).
    func testCodeSwitchingItemsAreJudgedOnTheirLanguageSequence() throws {
        let item = EvalItem(id: "en-fr-1", audio: "/tmp/en-fr-1.wav", text: "Hello. Bonjour.", language: "en", languages: ["en", "fr"])
        let followed = EvalResult(item: item, detectedLanguage: "fr", segmentLanguages: ["en", "fr"])
        XCTAssertFalse(followed.languageMismatch, "the longer French stretch decides the recording's language; the sequence is right")
        XCTAssertTrue(EvalResult(item: item, detectedLanguage: "en", segmentLanguages: ["en"]).languageMismatch)
        XCTAssertTrue(EvalResult(item: item, detectedLanguage: "fr", segmentLanguages: ["fr", "en"]).languageMismatch)
        XCTAssertFalse(EvalResult(item: item, detectedLanguage: "fr", segmentLanguages: ["en", "en", "fr"]).languageMismatch)
        XCTAssertFalse(EvalResult(item: item, segmentLanguages: ["en", "fr"], error: "boom").languageMismatch)

        // Without a sequence, the reference language decides, as before.
        let plain = EvalItem(audio: "/tmp/a.wav", text: "Hello.", language: "en")
        XCTAssertTrue(EvalResult(item: plain, detectedLanguage: "fr", segmentLanguages: ["en"]).languageMismatch)

        // Manifests resolve the codes of a sequence like the reference language, and reject unknown ones.
        let manifestURL = directory.appendingPathComponent("cs.jsonl")
        try Data("""
            {"audio": "a.wav", "text": "Hello. Bonjour.", "language": "en", "languages": ["English", "fr-FR"]}
            """.utf8).write(to: manifestURL)
        XCTAssertEqual(try Manifest.read(manifestURL).first?.languages, ["en", "fr"])
        try Data("""
            {"audio": "a.wav", "text": "Hello.", "languages": ["en", "klingon"]}
            """.utf8).write(to: manifestURL)
        XCTAssertThrowsError(try Manifest.read(manifestURL))
    }
}
