import Foundation
import XCTest
@testable import MnemeCore

/// Notes, audio-first ingest, review queue, renaming, deletion and schema migration.
final class ArchiveEntriesTests: XCTestCase {
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

    private func makeAudio(_ name: String = "memo.wav", frequency: Double = 440) throws -> PreparedAudio {
        let url = directory.appendingPathComponent(name)
        try Fixtures.writeTone(to: url, seconds: 3, frequency: frequency)
        return try AudioPreparer.prepare(url)
    }

    func testNotesAreVersionedSearchableAndLanguageTagged() throws {
        let first = try store.addNote(
            title: "Idées",
            body: "  Je voudrais écrire un livre sur la mémoire et les langues.\r\nDeuxième ligne.  "
        )
        XCTAssertEqual(first.entry.kind, .text)
        XCTAssertEqual(first.note.version, 1)
        XCTAssertEqual(first.note.body, "Je voudrais écrire un livre sur la mémoire et les langues.\nDeuxième ligne.")
        XCTAssertEqual(first.entry.language, "fr")
        XCTAssertEqual(try store.search("memoire").map { $0.source }, [.note])

        let second = try store.updateNote(entryID: first.entry.id, title: "Idées", body: "Je voudrais écrire un roman.")
        XCTAssertEqual(second.version, 2)
        XCTAssertTrue(try store.search("memoire").isEmpty, "Only the current version is searchable")
        XCTAssertEqual(try store.search("roman").first?.entryID, first.entry.id)
        XCTAssertEqual(try store.search("idees").first?.source, .note, "The title is indexed with the note")

        let details = try store.entryDetails(id: first.entry.id)
        XCTAssertEqual(details.noteVersions, [1, 2])
        XCTAssertEqual(details.note?.body, "Je voudrais écrire un roman.")
        XCTAssertEqual(try store.entryDetails(id: first.entry.id, version: 1).note?.body.hasPrefix("Je voudrais écrire un livre"), true)

        let unchanged = try store.updateNote(entryID: first.entry.id, title: "Idées", body: " Je voudrais écrire un roman. ")
        XCTAssertEqual(unchanged.version, 2, "Saving the same text adds no version")
        XCTAssertThrowsError(try store.addNote(title: nil, body: " \n\t "))
    }

    func testRecentEntriesListNotesAndRecordings() throws {
        let audio = try makeAudio()
        _ = try store.ingestAudio(audio, recordedAt: Date(timeIntervalSince1970: 1_600_000_000))
        let note = try store.addNote(title: nil, body: "Line one.\nLine two.")
        let entries = try store.recentEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, note.entry.id)
        XCTAssertEqual(entries[0].preview, "Line one. Line two.")
        XCTAssertFalse(entries[0].needsTranscription)
        XCTAssertTrue(entries[1].needsTranscription)
    }

    func testRecordingIsArchivedBeforeTranscription() throws {
        let audio = try makeAudio()
        let archived = try store.ingestAudio(audio, title: "Morning")
        XCTAssertNil(archived.entry.language)
        XCTAssertEqual(archived.asset.sha256, audio.sha256)
        XCTAssertEqual(try store.untranscribedEntries(), [archived.entry.id])
        XCTAssertThrowsError(try store.ingestAudio(audio)) { error in
            XCTAssertEqual(error as? ArchiveError, .duplicateRecording(entryID: archived.entry.id))
        }

        let added = try store.addTranscriptVersion(
            assetID: archived.asset.id,
            transcript: Fixtures.transcript(segments: [(0, 1, "Good morning.")])
        )
        XCTAssertEqual(added.record.version, 1)
        XCTAssertTrue(try store.untranscribedEntries().isEmpty)
        XCTAssertEqual(try store.entry(id: archived.entry.id)?.language, "en")
        XCTAssertEqual(try store.search("morning").map { $0.source }, [.transcript], "A title hit for the same entry is not repeated")
        XCTAssertEqual(try store.search("morn").first?.segmentIndex, 0)
    }

    func testFlaggedSegmentsAreQueuedUntilConfirmed() throws {
        let audio = try makeAudio()
        var shaky = Fixtures.segment(1, 1.5, 2.9, "Second prat.")
        shaky.avgLogprob = -1.3
        let result = try store.ingestVoice(audio, transcript: Fixtures.transcript(with: [
            Fixtures.segment(0, 0, 1.4, "First part."),
            shaky,
        ]))
        let queue = try store.flaggedSegments()
        XCTAssertEqual(queue.map { $0.segmentIndex }, [1])
        XCTAssertEqual(queue.first?.flags, [.lowConfidence])
        XCTAssertEqual(queue.first?.transcriptVersion, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue[0].audioURL.path))

        _ = try store.confirmSegment(entryID: result.entry.id, segmentIndex: 1)
        XCTAssertTrue(try store.flaggedSegments().isEmpty)
        let segment = try store.entryDetails(id: result.entry.id).transcript?.transcript.segments[1]
        XCTAssertEqual(segment?.text, "Second prat.")
        XCTAssertEqual(segment?.flags, [.userVerified])
    }

    func testConfirmingLeavesTheQueueButKeepsEstimatedTiming() throws {
        let audio = try makeAudio()
        let result = try store.ingestVoice(audio, transcript: Fixtures.transcript(with: [
            Fixtures.segment(0, 0, 1.4, "First part."),
            Fixtures.segment(1, 4.2, 5.0, "Placed after the end."),
        ]))
        XCTAssertEqual(try store.flaggedSegments().map { $0.flags }, [[.unreliableTiming]])
        XCTAssertEqual(try store.recentEntries().first?.flaggedSegments, 1)

        _ = try store.confirmSegment(entryID: result.entry.id, segmentIndex: 1)
        XCTAssertTrue(try store.flaggedSegments().isEmpty)
        XCTAssertEqual(try store.recentEntries().first?.flaggedSegments, 0)
        let segment = try store.entryDetails(id: result.entry.id).transcript?.transcript.segments[1]
        XCTAssertEqual(segment?.flags, [.unreliableTiming, .userVerified])
        XCTAssertEqual(segment?.text, "Placed after the end.")
    }

    func testSegmentLanguagesOfAMixedRecordingAreStoredAndExported() throws {
        let audio = try makeAudio()
        var french = Fixtures.segment(0, 0, 1.8, "Ce matin, j'ai relu le chapitre.")
        french.language = "fr"
        var english = Fixtures.segment(1, 1.9, 2.9, "Then I sent it.")
        english.language = "EN"
        let transcript = Transcript(
            language: LanguageDecision(code: "en", probability: 0.5, source: .mixed),
            segments: [french, english],
            provenance: Provenance(engine: "test-engine", modelID: "test-model")
        )
        let result = try store.ingestVoice(audio, transcript: transcript)
        let stored = try XCTUnwrap(try store.entryDetails(id: result.entry.id).transcript?.transcript)
        XCTAssertEqual(stored.segments.map { $0.language }, ["fr", "en"])
        XCTAssertEqual(stored.language.source, .mixed)
        XCTAssertEqual(stored.language.code, "fr", "The language spoken longest labels the transcript")
        XCTAssertEqual(stored.language.probability ?? 0, 1.8 / 2.8, accuracy: 0.001)
        XCTAssertEqual(try store.entry(id: result.entry.id)?.language, "fr")

        _ = try store.correctSegment(entryID: result.entry.id, segmentIndex: 1, text: "Then I sent it to London.")
        let corrected = try XCTUnwrap(try store.entryDetails(id: result.entry.id).transcript?.transcript)
        XCTAssertEqual(corrected.segments[1].language, "en", "A correction keeps the segment's language")
        XCTAssertEqual(try store.verifiedSegments().map { $0.language }, ["en"])
    }

    func testTheMixedLanguagesSettingChoosesTheStrategy() throws {
        XCTAssertTrue(try store.mixedLanguages())
        XCTAssertEqual(try store.languageStrategy(), .sentence)
        try store.setMixedLanguages(false)
        XCTAssertFalse(try store.mixedLanguages())
        XCTAssertEqual(try store.languageStrategy(), .recording)
        try store.setMixedLanguages(true)
        XCTAssertEqual(try store.languageStrategy(), .sentence)
    }

    func testRenamingUpdatesTitlesAndTheNoteIndex() throws {
        let audio = try makeAudio()
        let voice = try store.ingestAudio(audio)
        try store.renameEntry(id: voice.entry.id, title: "  Walk in Sidi Bou Said ")
        XCTAssertEqual(try store.entry(id: voice.entry.id)?.title, "Walk in Sidi Bou Said")
        XCTAssertEqual(try store.search("Sidi").first?.source, .title)

        let note = try store.addNote(title: "Draft", body: "Some thoughts.")
        try store.renameEntry(id: note.entry.id, title: "Carthage")
        XCTAssertEqual(try store.search("carthage").first?.entryID, note.entry.id)
        XCTAssertTrue(try store.search("draft").isEmpty)
        try store.renameEntry(id: note.entry.id, title: nil)
        XCTAssertNil(try store.entry(id: note.entry.id)?.title)
    }

    func testDeletingAnEntryRemovesEverything() throws {
        let audio = try makeAudio()
        let recording = try store.ingestVoice(audio, transcript: Fixtures.transcript(segments: [(0, 1, "Secret plans.")]))
        let note = try store.addNote(title: "Private", body: "Another secret.")
        let blob = store.audioURL(for: recording.asset)

        try store.deleteEntry(id: recording.entry.id)
        XCTAssertNil(try store.entry(id: recording.entry.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertEqual(try store.search("secret").map { $0.entryID }, [note.entry.id])
        for table in ["asset", "transcript", "segment", "word", "segment_fts"] {
            XCTAssertEqual(try store.database.int("SELECT COUNT(*) FROM \(table)"), 0, table)
        }

        try store.deleteEntry(id: note.entry.id)
        for table in ["entry", "note_version", "note_fts"] {
            XCTAssertEqual(try store.database.int("SELECT COUNT(*) FROM \(table)"), 0, table)
        }
        XCTAssertTrue(try store.integrityReport().isHealthy)
        XCTAssertThrowsError(try store.deleteEntry(id: note.entry.id))
    }

    func testArchiveFromTheFirstVersionIsUpgraded() throws {
        let root = directory.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let database = try Database(path: root.appendingPathComponent(ArchiveStore.databaseFilename).path)
            try database.execute(Schema.migrations[0])
            try database.execute("PRAGMA user_version = 1")
            let now = Timestamps.string(Timestamps.now())
            try database.run(
                "INSERT INTO entry (id, created_at, recorded_at, title, kind) VALUES ('e1', ?, ?, 'Old entry', 'voice')",
                [.text(now), .text(now)]
            )
        }
        let upgraded = try ArchiveStore(root: root)
        XCTAssertEqual(try upgraded.database.userVersion(), Schema.version)
        XCTAssertEqual(try upgraded.entry(id: "e1")?.title, "Old entry")
        XCTAssertNoThrow(try upgraded.addNote(title: nil, body: "Written after the upgrade."))
    }
}
