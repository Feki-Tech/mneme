import Foundation
import XCTest
@testable import MnemeCore

final class ArchiveStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ArchiveStore!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
        store = try ArchiveStore(root: directory.appendingPathComponent("archive", isDirectory: true))
    }

    override func tearDownWithError() throws {
        store = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeAudio(_ name: String = "memo.wav", frequency: Double = 440, seconds: Double = 3) throws -> PreparedAudio {
        let url = directory.appendingPathComponent(name)
        try Fixtures.writeTone(to: url, seconds: seconds, frequency: frequency)
        return try AudioPreparer.prepare(url)
    }

    func testIngestStoresTranscriptAndVerifiedOriginal() throws {
        let audio = try makeAudio()
        let transcript = Fixtures.transcript(segments: [(0, 1.2, "Please call Stella."), (1.3, 2.8, "Ask her to bring these things.")])
        let result = try store.ingestVoice(audio, transcript: transcript, title: "  Groceries  ")

        XCTAssertEqual(result.entry.title, "Groceries")
        XCTAssertEqual(result.entry.kind, .voice)
        XCTAssertEqual(result.entry.language, "en")
        XCTAssertEqual(result.transcript.version, 1)
        XCTAssertTrue(result.transcript.isCurrent)
        XCTAssertTrue(result.sanitization.isClean)
        XCTAssertEqual(result.transcript.transcript, transcript, "A clean transcript must be stored exactly as given")
        XCTAssertEqual(result.transcript.transcript.text, "Please call Stella. Ask her to bring these things.")

        let details = try store.entryDetails(id: result.entry.id)
        XCTAssertEqual(details.transcript?.transcript, transcript)
        XCTAssertEqual(details.versions, [1])
        XCTAssertEqual(details.asset?.durationSeconds ?? 0, 3, accuracy: 0.01)
        let stored = try XCTUnwrap(details.audioURL)
        XCTAssertEqual(try FileHasher.sha256(of: stored), audio.sha256)
        let permissions = try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o444, "Originals are read-only")
    }

    func testDuplicateRecordingIsRejected() throws {
        let audio = try makeAudio()
        let first = try store.ingestVoice(audio, transcript: Fixtures.transcript(segments: [(0, 1, "Hello there.")]))
        XCTAssertThrowsError(try store.ingestVoice(audio, transcript: Fixtures.transcript(segments: [(0, 1, "Hello again.")]))) { error in
            XCTAssertEqual(error as? ArchiveError, .duplicateRecording(entryID: first.entry.id))
        }
        XCTAssertEqual(try store.recentEntries().count, 1)
    }

    func testInvalidTranscriptWritesNothing() throws {
        let audio = try makeAudio()
        let broken = Fixtures.transcript(with: [Fixtures.segment(0, 0, .nan, "Broken.")])
        XCTAssertThrowsError(try store.ingestVoice(audio, transcript: broken))
        XCTAssertEqual(try store.recentEntries().count, 0)
        XCTAssertNil(try store.asset(sha256: audio.sha256))
        let relative = store.blobs.relativePath(sha256: audio.sha256, fileExtension: audio.fileExtension)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.blobs.url(forRelativePath: relative).path))
    }

    func testFailedDatabaseWriteRemovesTheNewOriginal() throws {
        let audio = try makeAudio()
        let relative = store.blobs.relativePath(sha256: audio.sha256, fileExtension: audio.fileExtension)
        let now = Timestamps.string(Timestamps.now())
        // A conflicting row makes the asset insert fail after the original has been copied.
        try store.database.run(
            "INSERT INTO entry (id, created_at, recorded_at, kind) VALUES ('e0', ?, ?, 'voice')",
            [.text(now), .text(now)]
        )
        try store.database.run(
            "INSERT INTO asset (id, entry_id, sha256, media_type, byte_size, blob_path, imported_at) VALUES ('a0', 'e0', ?, 'audio/wav', 1, ?, ?)",
            [.text(String(repeating: "0", count: 64)), .text(relative), .text(now)]
        )
        XCTAssertThrowsError(try store.ingestVoice(audio, transcript: Fixtures.transcript(segments: [(0, 1, "Hello.")])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.blobs.url(forRelativePath: relative).path))
        XCTAssertEqual(try store.recentEntries().count, 1)
        XCTAssertEqual(try store.database.int("SELECT COUNT(*) FROM transcript"), 0)
    }

    func testSanitizationIsAppliedBeforeWriting() throws {
        let audio = try makeAudio(seconds: 3)
        var hallucination = Fixtures.segment(3, 5, 6, "Thanks for watching.")
        hallucination.avgLogprob = -1.4
        let raw = Fixtures.transcript(with: [
            Fixtures.segment(0, 0, 1, "<|startoftranscript|><|en|> Hello   world <|0.00|>"),
            Fixtures.segment(1, 1, 2, "   "),
            Fixtures.segment(2, 2, 3.2, "Goodbye."),
            hallucination,
        ])
        let result = try store.ingestVoice(audio, transcript: raw)
        let segments = result.transcript.transcript.segments
        XCTAssertEqual(segments.map { $0.text }, ["Hello world", "Goodbye."])
        XCTAssertEqual(segments.map { $0.index }, [0, 1])
        XCTAssertEqual(segments[1].end, 3, accuracy: 0.01)
        XCTAssertEqual(result.sanitization.droppedEmptySegments, 1)
        XCTAssertEqual(result.sanitization.droppedOutOfRangeSegments, 1)
        XCTAssertEqual(result.sanitization.clampedTimestamps, 1)
    }

    func testCorrectionAddsVersionAndKeepsHistory() throws {
        let audio = try makeAudio()
        let result = try store.ingestVoice(audio, transcript: Fixtures.transcript(segments: [
            (0, 1.5, "Please call Stela."),
            (1.6, 2.9, "We meet on Wensday."),
        ]))
        let correction = try store.correctSegment(entryID: result.entry.id, segmentIndex: 0, text: "  Please call   Stella. ")
        XCTAssertEqual(correction.transcript.version, 2)
        XCTAssertEqual(correction.glossarySuggestions, ["Stella"])
        let segments = correction.transcript.transcript.segments
        XCTAssertEqual(segments[0].text, "Please call Stella.")
        XCTAssertEqual(segments[0].flags, [.userVerified])
        XCTAssertTrue(segments[0].words.isEmpty)
        XCTAssertEqual(segments[1].text, "We meet on Wensday.")
        XCTAssertEqual(correction.transcript.transcript.provenance.engine, ArchiveStore.correctionEngine)
        XCTAssertEqual(correction.transcript.transcript.provenance.settings["based_on_version"], "1")
        XCTAssertEqual(correction.transcript.transcript.provenance.settings["source_engine"], "test-engine")

        let details = try store.entryDetails(id: result.entry.id)
        XCTAssertEqual(details.versions, [1, 2])
        XCTAssertEqual(details.transcript?.version, 2)
        let original = try store.entryDetails(id: result.entry.id, version: 1)
        XCTAssertEqual(original.transcript?.transcript.segments[0].text, "Please call Stela.")
        XCTAssertEqual(original.transcript?.isCurrent, false)
        XCTAssertThrowsError(try store.entryDetails(id: result.entry.id, version: 7))

        // Only the current version is searchable.
        XCTAssertEqual(try store.search("Stella").count, 1)
        XCTAssertEqual(try store.search("Stela").count, 0)

        XCTAssertThrowsError(try store.correctSegment(entryID: result.entry.id, segmentIndex: 9, text: "x"))
        XCTAssertThrowsError(try store.correctSegment(entryID: result.entry.id, segmentIndex: 1, text: "   "))
    }

    func testRetranscriptionAddsVersionAndUpdatesLanguage() throws {
        let audio = try makeAudio()
        let result = try store.ingestVoice(audio, transcript: Fixtures.transcript(language: "en", segments: [(0, 1, "Bonjour tout le monde.")]))
        let added = try store.addTranscriptVersion(
            assetID: result.asset.id,
            transcript: Fixtures.transcript(language: "fr", segments: [(0, 1, "Bonjour tout le monde.")])
        )
        XCTAssertEqual(added.record.version, 2)
        XCTAssertEqual(try store.entry(id: result.entry.id)?.language, "fr")
        XCTAssertEqual(try store.currentTranscript(assetID: result.asset.id)?.id, added.record.id)
        XCTAssertEqual(try store.search("monde").count, 1)
    }

    func testSearchIgnoresCaseAndDiacriticsAndIsInjectionSafe() throws {
        let audio = try makeAudio()
        _ = try store.ingestVoice(audio, transcript: Fixtures.transcript(language: "fr", segments: [(0, 2, "Nous sommes allés à Münster en été.")]))
        let hits = try store.search("munster")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].snippet.contains("[Münster]"), hits[0].snippet)
        XCTAssertEqual(try store.search("ETE").count, 1)
        XCTAssertEqual(try store.search("all").count, 1, "The last word matches as a prefix")
        XCTAssertEqual(try store.search("\"; DROP TABLE entry; --").count, 0)
        XCTAssertEqual(try store.search("   ").count, 0)
        XCTAssertEqual(try store.recentEntries().count, 1)
    }

    func testResolveEntryIDBySuffixOrPrefix() throws {
        let audio = try makeAudio()
        let result = try store.ingestVoice(audio, transcript: Fixtures.transcript(segments: [(0, 1, "Hello.")]))
        let id = result.entry.id
        XCTAssertEqual(try store.resolveEntryID(id), id)
        XCTAssertEqual(try store.resolveEntryID(String(id.suffix(8))), id)
        XCTAssertEqual(try store.resolveEntryID(String(id.prefix(13)).uppercased()), id)
        XCTAssertThrowsError(try store.resolveEntryID("abc"))
        XCTAssertThrowsError(try store.resolveEntryID("zzzz"))
        XCTAssertThrowsError(try store.resolveEntryID("ffffffff"))
    }

    func testGlossaryKeepsOrderAndIgnoresCaseDuplicates() throws {
        XCTAssertEqual(try store.addGlossaryTerms(["Stella", "Sfax", "  New   York "]), ["Stella", "Sfax", "New York"])
        XCTAssertEqual(try store.addGlossaryTerms(["stella", "Kairouan"]), ["Kairouan"])
        XCTAssertEqual(try store.glossary(), ["Stella", "Sfax", "New York", "Kairouan"])
        XCTAssertTrue(try store.removeGlossaryTerm("SFAX"))
        XCTAssertFalse(try store.removeGlossaryTerm("Tozeur"))
        XCTAssertEqual(try store.glossary(), ["Stella", "New York", "Kairouan"])
        XCTAssertThrowsError(try store.addGlossaryTerms(["   "]))
        XCTAssertThrowsError(try store.addGlossaryTerms([String(repeating: "a", count: 101)]))
    }

    func testLanguageProfileIsValidatedAndOrdered() throws {
        XCTAssertEqual(try store.setLanguageProfile(["French", "en-GB", "ara", "fr"]), ["fr", "en", "ar"])
        XCTAssertEqual(try store.languageProfile(), ["fr", "en", "ar"])
        XCTAssertThrowsError(try store.setLanguageProfile(["klingon"])) { error in
            XCTAssertEqual(error as? ArchiveError, .invalidLanguageCode("klingon"))
        }
        XCTAssertEqual(try store.languageProfile(), ["fr", "en", "ar"])
        try store.setLanguageProfile([])
        XCTAssertEqual(try store.languageProfile(), [])
    }

    func testVerifiedSegmentsFormAnEvaluationSet() throws {
        let audio = try makeAudio()
        let result = try store.ingestVoice(audio, transcript: Fixtures.transcript(segments: [(0, 1.4, "First part."), (1.5, 2.9, "Second prat.")]))
        XCTAssertTrue(try store.verifiedSegments().isEmpty)
        _ = try store.correctSegment(entryID: result.entry.id, segmentIndex: 1, text: "Second part.")
        let items = try store.verifiedSegments()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Second part.")
        XCTAssertEqual(items[0].start, 1.5)
        XCTAssertEqual(items[0].end, 2.9)
        XCTAssertEqual(items[0].language, "en")
        XCTAssertEqual(items[0].accent, "self")
        XCTAssertEqual(items[0].id, "\(result.entry.id)#1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].audio))
    }

    func testIntegrityReportDetectsTampering() throws {
        let audio = try makeAudio()
        let result = try store.ingestVoice(audio, transcript: Fixtures.transcript(segments: [(0, 1, "Hello.")]))
        let healthy = try store.integrityReport()
        XCTAssertTrue(healthy.isHealthy, "\(healthy)")
        XCTAssertEqual(healthy.checkedBlobs, 1)

        let blob = store.audioURL(for: result.asset)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blob.path)
        try Data("tampered".utf8).write(to: blob)
        let report = try store.integrityReport()
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.corruptedBlobs, [result.asset.blobPath])
    }

    func testReopeningKeepsDataAndSchemaVersion() throws {
        let root = store.root
        let audio = try makeAudio()
        let result = try store.ingestVoice(audio, transcript: Fixtures.transcript(segments: [(0, 1, "Persisted.")]))
        store = nil
        let reopened = try ArchiveStore(root: root)
        XCTAssertEqual(try reopened.database.userVersion(), Schema.version)
        XCTAssertEqual(try reopened.entryDetails(id: result.entry.id).transcript?.transcript, result.transcript.transcript)
    }

    func testNewerSchemaIsRefused() throws {
        let root = store.root
        try store.database.execute("PRAGMA user_version = 99")
        store = nil
        XCTAssertThrowsError(try ArchiveStore(root: root)) { error in
            XCTAssertEqual(error as? ArchiveError, .schemaTooNew(found: 99, supported: Schema.version))
        }
    }

    func testRecentEntriesAreOrderedByRecordingDate() throws {
        let older = try makeAudio("older.wav", frequency: 300)
        let newer = try makeAudio("newer.wav", frequency: 500)
        let olderDate = Date(timeIntervalSince1970: 1_600_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try store.ingestVoice(newer, transcript: Fixtures.transcript(segments: [(0, 1, "Newer.")]), recordedAt: newerDate)
        let second = try store.ingestVoice(older, transcript: Fixtures.transcript(segments: [(0, 1, "Older.")]), recordedAt: olderDate)
        let entries = try store.recentEntries()
        XCTAssertEqual(entries.map { $0.entry.id }, [first.entry.id, second.entry.id])
        XCTAssertEqual(entries[1].entry.recordedAt, olderDate)
        XCTAssertEqual(entries[0].preview, "Newer.")
        XCTAssertEqual(entries[0].transcriptVersion, 1)
    }
}
