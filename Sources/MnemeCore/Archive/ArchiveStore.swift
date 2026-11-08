import Foundation

/// Health of the archive: SQLite structure, the search index and every stored original.
public struct IntegrityReport: Sendable {
    public var databaseCheck: String
    public var foreignKeyViolations: Int
    public var searchIndexCheck: String
    public var checkedBlobs: Int
    public var missingBlobs: [String]
    public var corruptedBlobs: [String]

    public var isHealthy: Bool {
        databaseCheck == "ok" && foreignKeyViolations == 0 && searchIndexCheck == "ok"
            && missingBlobs.isEmpty && corruptedBlobs.isEmpty
    }
}

/// The on-device archive: SQLite metadata and transcripts plus content-addressed original recordings.
///
/// Write guarantees:
/// - Transcripts are validated and normalised by `TranscriptSanitizer` before anything is written.
/// - Every write runs in one transaction and is read back and compared with the validated input
///   before it commits; any difference rolls the whole write back.
/// - Originals are copied once, verified against their SHA-256 and made read-only.
/// - Transcripts are never overwritten: a correction or re-transcription adds a new version.
public final class ArchiveStore {
    public let root: URL
    public let database: Database
    public let blobs: BlobStore
    public var sanitizer: TranscriptSanitizer

    public static let databaseFilename = "archive.sqlite"
    public static let correctionEngine = "user-correction"
    public static let languageProfileKey = "language_profile"
    public static let mixedLanguagesKey = "mixed_languages"

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Mneme/Archive", isDirectory: true)
    }

    public init(root: URL = ArchiveStore.defaultRoot, sanitizer: TranscriptSanitizer = TranscriptSanitizer()) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let databaseURL = root.appendingPathComponent(ArchiveStore.databaseFilename)
        let opened = try Database(path: databaseURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        try Schema.migrate(opened)
        // Deleted index entries are removed from the FTS5 structures too (SQLite 3.42+; ignored when unsupported).
        try? opened.execute("INSERT INTO segment_fts (segment_fts, rank) VALUES ('secure-delete', 1)")
        try? opened.execute("INSERT INTO note_fts (note_fts, rank) VALUES ('secure-delete', 1)")
        self.root = root
        self.database = opened
        self.blobs = BlobStore(root: root)
        self.sanitizer = sanitizer
    }

    public var databaseURL: URL {
        root.appendingPathComponent(ArchiveStore.databaseFilename)
    }

    // MARK: - Writing

    /// Archives a voice recording with its first transcript.
    @discardableResult
    public func ingestVoice(
        _ audio: PreparedAudio,
        transcript: Transcript,
        title: String? = nil,
        recordedAt: Date? = nil
    ) throws -> IngestResult {
        let sanitized = try sanitizer.sanitize(transcript, duration: audio.durationSeconds)
        let clean = sanitized.transcript
        let archived = try archiveRecording(
            audio,
            title: title,
            recordedAt: recordedAt,
            language: clean.language.code
        ) { (entry: EntryRecord, asset: AssetRecord, now: Date) -> TranscriptRecord in
            let transcriptID = Identifiers.newID(at: now)
            try insertTranscript(id: transcriptID, assetID: asset.id, version: 1, transcript: clean, createdAt: now)
            try appendLog(
                "ingest",
                target: entry.id,
                modelID: clean.provenance.modelID,
                detail: "transcript v1, \(clean.segments.count) segments, \(sanitized.report.summary)"
            )
            return try verifiedCurrentTranscript(assetID: asset.id, expectedID: transcriptID, expected: clean)
        }
        return IngestResult(entry: archived.entry, asset: archived.asset, transcript: archived.result, sanitization: sanitized.report)
    }

    /// Archives a recording without a transcript, so it is safe before transcription starts or if transcription
    /// fails. Add the transcript later with `addTranscriptVersion(assetID:transcript:)`.
    @discardableResult
    public func ingestAudio(
        _ audio: PreparedAudio,
        title: String? = nil,
        recordedAt: Date? = nil
    ) throws -> (entry: EntryRecord, asset: AssetRecord) {
        let archived = try archiveRecording(
            audio,
            title: title,
            recordedAt: recordedAt,
            language: nil
        ) { (entry: EntryRecord, _: AssetRecord, _: Date) -> Void in
            try appendLog("import", target: entry.id, modelID: nil, detail: "recording without transcript")
        }
        return (archived.entry, archived.asset)
    }

    /// Copies the original into the blob store, then writes the entry and asset rows in one transaction and reads
    /// them back; `body` runs inside the same transaction. On failure a newly created blob is removed again.
    private func archiveRecording<T>(
        _ audio: PreparedAudio,
        title: String?,
        recordedAt: Date?,
        language: String?,
        then body: (EntryRecord, AssetRecord, Date) throws -> T
    ) throws -> (entry: EntryRecord, asset: AssetRecord, result: T) {
        if let existing = try self.asset(sha256: audio.sha256) {
            throw ArchiveError.duplicateRecording(entryID: existing.entryID)
        }
        let stored = try blobs.store(source: audio.url, sha256: audio.sha256, fileExtension: audio.fileExtension)
        let now = Timestamps.now()
        let entryRecord = EntryRecord(
            id: Identifiers.newID(at: now),
            createdAt: now,
            recordedAt: Timestamps.truncated(recordedAt ?? audio.fileDate ?? now),
            title: Self.cleanTitle(title),
            kind: .voice,
            language: language
        )
        let assetRecord = AssetRecord(
            id: Identifiers.newID(at: now),
            entryID: entryRecord.id,
            sha256: audio.sha256,
            mediaType: audio.mediaType,
            originalFilename: audio.originalFilename,
            byteSize: audio.byteSize,
            durationSeconds: audio.durationSeconds.isFinite && audio.durationSeconds > 0 ? audio.durationSeconds : nil,
            blobPath: stored.relativePath,
            importedAt: now
        )
        do {
            return try database.transaction { () -> (entry: EntryRecord, asset: AssetRecord, result: T) in
                try insertEntry(entryRecord)
                try insertAsset(assetRecord)
                let storedEntry = try verifiedEntry(entryRecord)
                let storedAsset = try verifiedAsset(assetRecord)
                let result = try body(storedEntry, storedAsset, now)
                return (entry: storedEntry, asset: storedAsset, result: result)
            }
        } catch {
            if stored.created {
                blobs.remove(relativePath: stored.relativePath)
            }
            if let sqliteError = error as? SQLiteError, sqliteError.isConstraintViolation,
               let existing = try? self.asset(sha256: audio.sha256) {
                throw ArchiveError.duplicateRecording(entryID: existing.entryID)
            }
            throw error
        }
    }

    /// Adds a transcript version for a stored recording and makes it current. Earlier versions are kept.
    @discardableResult
    public func addTranscriptVersion(assetID: String, transcript: Transcript) throws -> (record: TranscriptRecord, report: SanitizationReport) {
        guard let recording = try self.asset(id: assetID) else {
            throw ArchiveError.notFound("recording \(assetID)")
        }
        let sanitized = try sanitizer.sanitize(transcript, duration: recording.durationSeconds)
        let clean = sanitized.transcript
        let now = Timestamps.now()
        let transcriptID = Identifiers.newID(at: now)
        let record = try database.transaction { () -> TranscriptRecord in
            let latest = try database.int("SELECT MAX(version) FROM transcript WHERE asset_id = ?", [.text(recording.id)]) ?? 0
            try database.run(
                "UPDATE transcript SET is_current = 0 WHERE asset_id = ? AND is_current = 1",
                [.text(recording.id)]
            )
            // Only current transcripts are searchable.
            try database.run(
                "DELETE FROM segment_fts WHERE transcript_id IN (SELECT id FROM transcript WHERE asset_id = ?)",
                [.text(recording.id)]
            )
            try insertTranscript(id: transcriptID, assetID: recording.id, version: latest + 1, transcript: clean, createdAt: now)
            try database.run("UPDATE entry SET language = ? WHERE id = ?", [.text(clean.language.code), .text(recording.entryID)])
            try appendLog(
                clean.provenance.engine == ArchiveStore.correctionEngine ? "correct" : (latest == 0 ? "transcribe" : "retranscribe"),
                target: recording.entryID,
                modelID: clean.provenance.modelID,
                detail: "transcript v\(latest + 1), \(sanitized.report.summary)"
            )
            return try verifiedCurrentTranscript(assetID: recording.id, expectedID: transcriptID, expected: clean)
        }
        return (record, sanitized.report)
    }

    /// Replaces the text of one segment, as a new transcript version. The segment is marked as verified by the user.
    public func correctSegment(entryID: String, segmentIndex: Int, text: String) throws -> CorrectionResult {
        let details = try entryDetails(id: entryID)
        guard let recording = details.asset, let current = details.transcript else {
            throw ArchiveError.notFound("a transcript for entry \(entryID)")
        }
        let corrected = TranscriptSanitizer.cleanText(text)
        guard !corrected.isEmpty else {
            throw ArchiveError.invalidArgument("The corrected text is empty.")
        }
        guard let position = current.transcript.segments.firstIndex(where: { $0.index == segmentIndex }) else {
            throw ArchiveError.notFound("segment \(segmentIndex) of entry \(entryID)")
        }
        var updated = current.transcript
        let original = updated.segments[position].text
        updated.segments[position].text = corrected
        if corrected != original {
            // Word timings belong to the old wording; a confirmation keeps them.
            updated.segments[position].words = []
        }
        updated.segments[position].flags = updated.segments[position].flags.intersection([.unreliableTiming]).union([.userVerified])
        var settings = current.transcript.provenance.settings
        settings["based_on_version"] = String(current.version)
        settings["edited_segment"] = String(segmentIndex)
        if current.transcript.provenance.engine != ArchiveStore.correctionEngine {
            settings["source_engine"] = current.transcript.provenance.engine
        }
        updated.provenance = Provenance(
            engine: ArchiveStore.correctionEngine,
            modelID: current.transcript.provenance.modelID,
            settings: settings
        )
        updated.processingSeconds = nil
        let added = try addTranscriptVersion(assetID: recording.id, transcript: updated)
        let terms = try glossary()
        let suggestions = GlossarySuggester.suggestions(original: original, corrected: corrected, glossary: terms)
        return CorrectionResult(transcript: added.record, glossarySuggestions: suggestions)
    }

    // MARK: - Reading

    public func entry(id: String) throws -> EntryRecord? {
        try database.query(
            "SELECT \(ArchiveStore.entryColumns) FROM entry WHERE id = ?",
            [.text(id)]
        ) { (row: Row) -> EntryRecord in
            try ArchiveStore.entryRecord(row)
        }.first
    }

    public func entryDetails(id: String, version: Int? = nil) throws -> EntryDetails {
        guard let record = try entry(id: id) else {
            throw ArchiveError.notFound("entry \(id)")
        }
        let recording = try assets(entryID: record.id).first
        var transcriptRecord: TranscriptRecord?
        var versions: [Int] = []
        var audioURL: URL?
        if let recording {
            versions = try database.query(
                "SELECT version FROM transcript WHERE asset_id = ? ORDER BY version",
                [.text(recording.id)]
            ) { (row: Row) -> Int in
                row.int(0)
            }
            if let version {
                transcriptRecord = try loadTranscript(where: "asset_id = ? AND version = ?", [.text(recording.id), .int(version)])
                if transcriptRecord == nil {
                    throw ArchiveError.notFound("version \(version) of entry \(record.id)")
                }
            } else {
                transcriptRecord = try currentTranscript(assetID: recording.id)
            }
            audioURL = blobs.url(forRelativePath: recording.blobPath)
        }
        var note: NoteRecord?
        var noteVersions: [Int] = []
        if record.kind == .text {
            noteVersions = try database.query(
                "SELECT version FROM note_version WHERE entry_id = ? ORDER BY version",
                [.text(record.id)]
            ) { (row: Row) -> Int in
                row.int(0)
            }
            if let version {
                note = try loadNote(where: "entry_id = ? AND version = ?", [.text(record.id), .int(version)])
                if note == nil {
                    throw ArchiveError.notFound("version \(version) of note \(record.id)")
                }
            } else {
                note = try currentNote(entryID: record.id)
            }
        }
        return EntryDetails(
            entry: record,
            asset: recording,
            transcript: transcriptRecord,
            versions: versions,
            audioURL: audioURL,
            note: note,
            noteVersions: noteVersions
        )
    }

    /// Resolves a full ID, or a unique prefix or suffix of at least 4 characters.
    public func resolveEntryID(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count >= 4 else {
            throw ArchiveError.invalidArgument("Use at least 4 characters of the entry ID.")
        }
        guard value.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw ArchiveError.notFound("entry \(input)")
        }
        if try entry(id: value) != nil {
            return value
        }
        let matches = try database.query(
            "SELECT id FROM entry WHERE id LIKE ? OR id LIKE ? LIMIT 2",
            [.text(value + "%"), .text("%" + value)]
        ) { (row: Row) -> String in
            row.string(0)
        }
        guard let first = matches.first else {
            throw ArchiveError.notFound("entry \(input)")
        }
        guard matches.count == 1 else {
            throw ArchiveError.ambiguousIdentifier(input)
        }
        return first
    }

    public func currentTranscript(assetID: String) throws -> TranscriptRecord? {
        try loadTranscript(where: "asset_id = ? AND is_current = 1", [.text(assetID)])
    }

    public func transcript(id: String) throws -> TranscriptRecord? {
        try loadTranscript(where: "id = ?", [.text(id)])
    }

    /// Most recently recorded entries first.
    public func recentEntries(limit: Int = 20) throws -> [EntrySummary] {
        try database.query("""
            SELECT e.id, e.created_at, e.recorded_at, e.title, e.kind, e.language,
                   a.duration_s, t.version, COALESCE(t.text, n.body), t.flagged_segments
            FROM entry e
            LEFT JOIN asset a ON a.entry_id = e.id
            LEFT JOIN transcript t ON t.asset_id = a.id AND t.is_current = 1
            LEFT JOIN note_version n ON n.entry_id = e.id AND n.is_current = 1
            ORDER BY e.recorded_at DESC, e.id DESC
            LIMIT ?
            """, [.int(max(1, limit))]) { (row: Row) -> EntrySummary in
            let record = try ArchiveStore.entryRecord(row)
            return EntrySummary(
                entry: record,
                durationSeconds: row.optionalDouble(6),
                transcriptVersion: row.isNull(7) ? nil : row.int(7),
                preview: ArchiveStore.preview(row.optionalString(8) ?? ""),
                flaggedSegments: row.isNull(9) ? 0 : row.int(9)
            )
        }
    }

    /// Full-text search over current transcripts and notes, plus titles. Diacritics and case are ignored in
    /// transcripts and notes, and the last word matches as a prefix. Best matches first.
    public func search(_ query: String, limit: Int = 20) throws -> [SearchHit] {
        let capped = max(1, limit)
        var scored: [(score: Double, hit: SearchHit)] = []
        if let expression = FTSQuery.make(query) {
            let transcriptHits = try database.query("""
                SELECT e.id, e.kind, e.title, e.recorded_at, s.idx, s.start_s, s.end_s,
                       snippet(segment_fts, 0, '[', ']', '…', 12), bm25(segment_fts)
                FROM segment_fts
                JOIN transcript t ON t.id = segment_fts.transcript_id AND t.is_current = 1
                JOIN asset a ON a.id = t.asset_id
                JOIN entry e ON e.id = a.entry_id
                JOIN segment s ON s.transcript_id = t.id AND s.idx = CAST(segment_fts.segment_idx AS INTEGER)
                WHERE segment_fts MATCH ?
                ORDER BY bm25(segment_fts), e.recorded_at DESC
                LIMIT ?
                """, [.text(expression), .int(capped)]) { (row: Row) -> (score: Double, hit: SearchHit) in
                let hit = try ArchiveStore.searchHit(row, source: .transcript, snippetColumn: 7, segmentColumns: 4)
                return (score: row.double(8), hit: hit)
            }
            let noteHits = try database.query("""
                SELECT e.id, e.kind, e.title, e.recorded_at,
                       snippet(note_fts, 0, '[', ']', '…', 16), bm25(note_fts)
                FROM note_fts
                JOIN entry e ON e.id = note_fts.entry_id
                WHERE note_fts MATCH ?
                ORDER BY bm25(note_fts), e.recorded_at DESC
                LIMIT ?
                """, [.text(expression), .int(capped)]) { (row: Row) -> (score: Double, hit: SearchHit) in
                let hit = try ArchiveStore.searchHit(row, source: .note, snippetColumn: 4, segmentColumns: nil)
                return (score: row.double(5), hit: hit)
            }
            scored = (transcriptHits + noteHits).sorted { $0.score < $1.score }
        }
        var hits = scored.map { $0.hit }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let pattern = "%" + ArchiveStore.escapeLike(trimmed) + "%"
            let titleHits = try database.query("""
                SELECT id, kind, title, recorded_at, title
                FROM entry
                WHERE title LIKE ? ESCAPE '\\'
                ORDER BY recorded_at DESC
                LIMIT ?
                """, [.text(pattern), .int(capped)]) { (row: Row) -> SearchHit in
                try ArchiveStore.searchHit(row, source: .title, snippetColumn: 4, segmentColumns: nil)
            }
            let found = Set(hits.map { $0.entryID })
            hits += titleHits.filter { !found.contains($0.entryID) }
        }
        return Array(hits.prefix(capped))
    }

    /// Maps columns id, kind, title, recorded_at, then optionally idx, start, end at `segmentColumns`.
    private static func searchHit(_ row: Row, source: SearchHit.Source, snippetColumn: Int32, segmentColumns: Int32?) throws -> SearchHit {
        let kindValue = row.string(1)
        guard let kind = EntryKind(rawValue: kindValue) else {
            throw ArchiveError.verificationFailed("unknown entry kind \(kindValue)")
        }
        let recordedAt = try date(row.string(3))
        return SearchHit(
            entryID: row.string(0),
            kind: kind,
            title: row.optionalString(2),
            recordedAt: recordedAt,
            source: source,
            segmentIndex: segmentColumns.map { row.int($0) },
            start: segmentColumns.map { row.double($0 + 1) },
            end: segmentColumns.map { row.double($0 + 2) },
            snippet: row.string(snippetColumn)
        )
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    public func asset(sha256: String) throws -> AssetRecord? {
        try database.query(
            "SELECT \(ArchiveStore.assetColumns) FROM asset WHERE sha256 = ?",
            [.text(sha256.lowercased())]
        ) { (row: Row) -> AssetRecord in
            try ArchiveStore.assetRecord(row)
        }.first
    }

    public func asset(id: String) throws -> AssetRecord? {
        try database.query(
            "SELECT \(ArchiveStore.assetColumns) FROM asset WHERE id = ?",
            [.text(id)]
        ) { (row: Row) -> AssetRecord in
            try ArchiveStore.assetRecord(row)
        }.first
    }

    public func assets(entryID: String) throws -> [AssetRecord] {
        try database.query(
            "SELECT \(ArchiveStore.assetColumns) FROM asset WHERE entry_id = ? ORDER BY imported_at, id",
            [.text(entryID)]
        ) { (row: Row) -> AssetRecord in
            try ArchiveStore.assetRecord(row)
        }
    }

    public func audioURL(for asset: AssetRecord) -> URL {
        blobs.url(forRelativePath: asset.blobPath)
    }

    /// Segments the user verified or corrected, as evaluation items: a personal accent dataset.
    public func verifiedSegments() throws -> [EvalItem] {
        try database.query("""
            SELECT e.id, a.blob_path, s.idx, s.start_s, s.end_s, s.text, COALESCE(s.language, t.language)
            FROM segment s
            JOIN transcript t ON t.id = s.transcript_id AND t.is_current = 1
            JOIN asset a ON a.id = t.asset_id
            JOIN entry e ON e.id = a.entry_id
            WHERE (',' || s.flags || ',') LIKE '%,user_verified,%'
            ORDER BY e.recorded_at, e.id, s.idx
            """) { (row: Row) -> EvalItem in
            EvalItem(
                id: "\(row.string(0))#\(row.int(2))",
                audio: blobs.url(forRelativePath: row.string(1)).path,
                text: row.string(5),
                language: row.string(6),
                accent: "self",
                speaker: "self",
                start: row.double(3),
                end: row.double(4)
            )
        }
    }

    // MARK: - Glossary, language profile and settings

    /// Glossary terms in the order they were added.
    public func glossary() throws -> [String] {
        try database.query("SELECT term FROM glossary_term ORDER BY rowid") { (row: Row) -> String in
            row.string(0)
        }
    }

    /// Adds terms (case-insensitively unique) and returns the ones that were new.
    @discardableResult
    public func addGlossaryTerms(_ terms: [String]) throws -> [String] {
        let cleaned = try terms.map { (term: String) -> String in
            let value = TranscriptSanitizer.cleanText(term)
            guard !value.isEmpty else {
                throw ArchiveError.invalidArgument("Glossary terms cannot be empty.")
            }
            guard value.count <= 100 else {
                throw ArchiveError.invalidArgument("Glossary terms are limited to 100 characters.")
            }
            return value
        }
        let now = Timestamps.string(Timestamps.now())
        return try database.transaction { () -> [String] in
            var added: [String] = []
            for term in cleaned {
                try database.run("INSERT OR IGNORE INTO glossary_term (term, added_at) VALUES (?, ?)", [.text(term), .text(now)])
                if database.changesInLastStatement > 0 {
                    added.append(term)
                }
            }
            return added
        }
    }

    @discardableResult
    public func removeGlossaryTerm(_ term: String) throws -> Bool {
        try database.run("DELETE FROM glossary_term WHERE term = ?", [.text(TranscriptSanitizer.cleanText(term))])
        return database.changesInLastStatement > 0
    }

    public func setting(_ key: String) throws -> String? {
        try database.query("SELECT value FROM setting WHERE key = ?", [.text(key)]) { (row: Row) -> String in
            row.string(0)
        }.first
    }

    /// Stores a setting; nil removes it.
    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try database.run(
                "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)]
            )
        } else {
            try database.run("DELETE FROM setting WHERE key = ?", [.text(key)])
        }
    }

    /// The languages the speaker uses, in priority order. Empty means unconstrained detection.
    public func languageProfile() throws -> [String] {
        guard let value = try setting(ArchiveStore.languageProfileKey) else { return [] }
        return value.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Validates and stores the language profile; an empty list clears it.
    @discardableResult
    public func setLanguageProfile(_ languages: [String]) throws -> [String] {
        let codes = try LanguagePolicy.validatedList(languages)
        try setSetting(ArchiveStore.languageProfileKey, codes.isEmpty ? nil : codes.joined(separator: ","))
        return codes
    }

    /// Whether the speaker switches languages within a recording (on unless turned off). With two or more
    /// languages in the profile, recordings are then identified sentence by sentence.
    public func mixedLanguages() throws -> Bool {
        try setting(ArchiveStore.mixedLanguagesKey) != "0"
    }

    public func setMixedLanguages(_ enabled: Bool) throws {
        try setSetting(ArchiveStore.mixedLanguagesKey, enabled ? nil : "0")
    }

    /// How recordings are divided for language identification. Only used when the profile lists two or
    /// more languages and no language was chosen for the recording. Without switching, one identification
    /// for the whole recording is the most robust choice (measured on the code-switching and accent sets).
    public func languageStrategy() throws -> LanguageStrategy {
        try mixedLanguages() ? .sentence : .recording
    }

    // MARK: - Integrity

    /// Checks the database structure, the search index and the checksum of every stored original.
    public func integrityReport() throws -> IntegrityReport {
        let databaseCheck = try database.query("PRAGMA integrity_check") { (row: Row) -> String in
            row.string(0)
        }.joined(separator: "; ")
        let foreignKeyViolations = try database.query("PRAGMA foreign_key_check") { (_: Row) -> Int in 1 }.count
        var searchIndexCheck = "ok"
        do {
            try database.run("INSERT INTO segment_fts (segment_fts) VALUES ('integrity-check')")
        } catch {
            searchIndexCheck = String(describing: error)
        }
        let records = try database.query("SELECT \(ArchiveStore.assetColumns) FROM asset ORDER BY imported_at, id") { (row: Row) -> AssetRecord in
            try ArchiveStore.assetRecord(row)
        }
        var missing: [String] = []
        var corrupted: [String] = []
        for record in records {
            let url = blobs.url(forRelativePath: record.blobPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing.append(record.blobPath)
                continue
            }
            let checksum = try? FileHasher.sha256(of: url)
            if checksum != record.sha256 {
                corrupted.append(record.blobPath)
            }
        }
        return IntegrityReport(
            databaseCheck: databaseCheck,
            foreignKeyViolations: foreignKeyViolations,
            searchIndexCheck: searchIndexCheck,
            checkedBlobs: records.count,
            missingBlobs: missing,
            corruptedBlobs: corrupted
        )
    }

    // MARK: - Private: inserts

    func insertEntry(_ record: EntryRecord) throws {
        try database.run(
            "INSERT INTO entry (id, created_at, recorded_at, title, kind, language) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(record.id),
                .text(Timestamps.string(record.createdAt)),
                .text(Timestamps.string(record.recordedAt)),
                .optional(record.title),
                .text(record.kind.rawValue),
                .optional(record.language),
            ]
        )
    }

    func insertAsset(_ record: AssetRecord) throws {
        try database.run("""
            INSERT INTO asset (id, entry_id, sha256, media_type, original_filename, byte_size, duration_s, blob_path, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
            .text(record.id),
            .text(record.entryID),
            .text(record.sha256),
            .text(record.mediaType),
            .optional(record.originalFilename),
            .integer(record.byteSize),
            .optional(record.durationSeconds),
            .text(record.blobPath),
            .text(Timestamps.string(record.importedAt)),
        ])
    }

    private func insertTranscript(id: String, assetID: String, version: Int, transcript: Transcript, createdAt: Date) throws {
        let settingsJSON = try ArchiveStore.encodeSettings(transcript.provenance.settings)
        try database.run("""
            INSERT INTO transcript (id, asset_id, version, language, language_probability, language_source,
                                    model_top_language, text, engine, model_id, settings_json, created_at,
                                    processing_s, flagged_segments, is_current)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            """, [
            .text(id),
            .text(assetID),
            .int(version),
            .text(transcript.language.code),
            .optional(transcript.language.probability),
            .text(transcript.language.source.rawValue),
            .optional(transcript.language.modelTopCode),
            .text(transcript.text),
            .text(transcript.provenance.engine),
            .text(transcript.provenance.modelID),
            .text(settingsJSON),
            .text(Timestamps.string(createdAt)),
            .optional(transcript.processingSeconds),
            .int(transcript.flaggedSegmentCount),
        ])
        for segment in transcript.segments {
            try database.run("""
                INSERT INTO segment (transcript_id, idx, start_s, end_s, text, avg_logprob, compression_ratio,
                                     no_speech_prob, temperature, flags, language)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                .text(id),
                .int(segment.index),
                .real(segment.start),
                .real(segment.end),
                .text(segment.text),
                .optional(segment.avgLogprob),
                .optional(segment.compressionRatio),
                .optional(segment.noSpeechProb),
                .optional(segment.temperature),
                .text(QualityFlag.encode(segment.flags)),
                .optional(segment.language),
            ])
            for (wordIndex, word) in segment.words.enumerated() {
                try database.run("""
                    INSERT INTO word (transcript_id, segment_idx, idx, text, start_s, end_s, probability)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [
                    .text(id),
                    .int(segment.index),
                    .int(wordIndex),
                    .text(word.text),
                    .real(word.start),
                    .real(word.end),
                    .optional(word.probability),
                ])
            }
            try database.run(
                "INSERT INTO segment_fts (text, transcript_id, segment_idx) VALUES (?, ?, ?)",
                [.text(segment.text), .text(id), .int(segment.index)]
            )
        }
    }

    func appendLog(_ operation: String, target: String?, modelID: String?, detail: String?) throws {
        try database.run(
            "INSERT INTO processing_log (at, operation, target_id, model_id, detail) VALUES (?, ?, ?, ?, ?)",
            [
                .text(Timestamps.string(Timestamps.now())),
                .text(operation),
                .optional(target),
                .optional(modelID),
                .optional(detail),
            ]
        )
    }

    // MARK: - Private: reads and verification

    private struct TranscriptHeader {
        var id: String
        var assetID: String
        var version: Int
        var isCurrent: Bool
        var createdAt: Date
        var language: LanguageDecision
        var provenance: Provenance
        var processingSeconds: Double?
    }

    private func loadTranscript(where clause: String, _ parameters: [SQLValue]) throws -> TranscriptRecord? {
        let headers = try database.query("""
            SELECT id, asset_id, version, is_current, created_at, language, language_probability, language_source,
                   model_top_language, engine, model_id, settings_json, processing_s
            FROM transcript
            WHERE \(clause)
            LIMIT 1
            """, parameters) { (row: Row) -> TranscriptHeader in
            let sourceValue = row.string(7)
            guard let source = LanguageDecision.Source(rawValue: sourceValue) else {
                throw ArchiveError.verificationFailed("unknown language source \(sourceValue)")
            }
            let createdAt = try ArchiveStore.date(row.string(4))
            let settings = try ArchiveStore.decodeSettings(row.string(11))
            return TranscriptHeader(
                id: row.string(0),
                assetID: row.string(1),
                version: row.int(2),
                isCurrent: row.bool(3),
                createdAt: createdAt,
                language: LanguageDecision(
                    code: row.string(5),
                    probability: row.optionalDouble(6),
                    source: source,
                    modelTopCode: row.optionalString(8)
                ),
                provenance: Provenance(engine: row.string(9), modelID: row.string(10), settings: settings),
                processingSeconds: row.optionalDouble(12)
            )
        }
        guard let header = headers.first else { return nil }
        let segments = try loadSegments(transcriptID: header.id)
        return TranscriptRecord(
            id: header.id,
            assetID: header.assetID,
            version: header.version,
            isCurrent: header.isCurrent,
            createdAt: header.createdAt,
            transcript: Transcript(
                language: header.language,
                segments: segments,
                provenance: header.provenance,
                processingSeconds: header.processingSeconds
            )
        )
    }

    private func loadSegments(transcriptID: String) throws -> [TranscribedSegment] {
        var segments = try database.query("""
            SELECT idx, start_s, end_s, text, avg_logprob, compression_ratio, no_speech_prob, temperature, flags, language
            FROM segment
            WHERE transcript_id = ?
            ORDER BY idx
            """, [.text(transcriptID)]) { (row: Row) -> TranscribedSegment in
            TranscribedSegment(
                index: row.int(0),
                start: row.double(1),
                end: row.double(2),
                text: row.string(3),
                avgLogprob: row.optionalDouble(4),
                compressionRatio: row.optionalDouble(5),
                noSpeechProb: row.optionalDouble(6),
                temperature: row.optionalDouble(7),
                words: [],
                flags: QualityFlag.decode(row.string(8)),
                language: row.optionalString(9)
            )
        }
        let words = try database.query("""
            SELECT segment_idx, text, start_s, end_s, probability
            FROM word
            WHERE transcript_id = ?
            ORDER BY segment_idx, idx
            """, [.text(transcriptID)]) { (row: Row) -> (Int, TranscribedWord) in
            (
                row.int(0),
                TranscribedWord(text: row.string(1), start: row.double(2), end: row.double(3), probability: row.optionalDouble(4))
            )
        }
        var positions: [Int: Int] = [:]
        for (offset, segment) in segments.enumerated() {
            positions[segment.index] = offset
        }
        for (segmentIndex, word) in words {
            if let offset = positions[segmentIndex] {
                segments[offset].words.append(word)
            }
        }
        return segments
    }

    /// Reads the transcript back inside the open transaction and compares it with what was meant to be written.
    private func verifiedCurrentTranscript(assetID: String, expectedID: String, expected: Transcript) throws -> TranscriptRecord {
        guard let record = try currentTranscript(assetID: assetID) else {
            throw ArchiveError.verificationFailed("the transcript could not be read back")
        }
        guard record.id == expectedID else {
            throw ArchiveError.verificationFailed("a different transcript is marked as current")
        }
        guard record.transcript == expected else {
            throw ArchiveError.verificationFailed(ArchiveStore.describeDifference(record.transcript, expected))
        }
        let indexed = try database.int("SELECT COUNT(*) FROM segment_fts WHERE transcript_id = ?", [.text(expectedID)]) ?? 0
        guard indexed == expected.segments.count else {
            throw ArchiveError.verificationFailed(
                "the search index has \(indexed) rows for \(expected.segments.count) segments"
            )
        }
        return record
    }

    func verifiedEntry(_ expected: EntryRecord) throws -> EntryRecord {
        guard let stored = try entry(id: expected.id) else {
            throw ArchiveError.verificationFailed("the entry could not be read back")
        }
        guard stored.kind == expected.kind, stored.title == expected.title, stored.language == expected.language,
              Timestamps.string(stored.createdAt) == Timestamps.string(expected.createdAt),
              Timestamps.string(stored.recordedAt) == Timestamps.string(expected.recordedAt) else {
            throw ArchiveError.verificationFailed("the stored entry differs from the input")
        }
        return stored
    }

    func verifiedAsset(_ expected: AssetRecord) throws -> AssetRecord {
        guard let stored = try asset(id: expected.id) else {
            throw ArchiveError.verificationFailed("the recording could not be read back")
        }
        guard stored.entryID == expected.entryID, stored.sha256 == expected.sha256,
              stored.mediaType == expected.mediaType, stored.originalFilename == expected.originalFilename,
              stored.byteSize == expected.byteSize, stored.durationSeconds == expected.durationSeconds,
              stored.blobPath == expected.blobPath,
              Timestamps.string(stored.importedAt) == Timestamps.string(expected.importedAt) else {
            throw ArchiveError.verificationFailed("the stored recording differs from the input")
        }
        return stored
    }

    static func describeDifference(_ stored: Transcript, _ expected: Transcript) -> String {
        if stored.language != expected.language { return "the language decision differs" }
        if stored.provenance != expected.provenance { return "the provenance differs" }
        if stored.processingSeconds != expected.processingSeconds { return "the processing time differs" }
        if stored.segments.count != expected.segments.count {
            return "\(stored.segments.count) segments were stored instead of \(expected.segments.count)"
        }
        for (lhs, rhs) in zip(stored.segments, expected.segments) where lhs != rhs {
            return "segment \(rhs.index) differs"
        }
        return "the stored transcript differs from the validated input"
    }

    // MARK: - Private: mapping helpers

    static let entryColumns = "id, created_at, recorded_at, title, kind, language"
    static let assetColumns =
        "id, entry_id, sha256, media_type, original_filename, byte_size, duration_s, blob_path, imported_at"

    static func entryRecord(_ row: Row) throws -> EntryRecord {
        let kindValue = row.string(4)
        guard let kind = EntryKind(rawValue: kindValue) else {
            throw ArchiveError.verificationFailed("unknown entry kind \(kindValue)")
        }
        let createdAt = try date(row.string(1))
        let recordedAt = try date(row.string(2))
        return EntryRecord(
            id: row.string(0),
            createdAt: createdAt,
            recordedAt: recordedAt,
            title: row.optionalString(3),
            kind: kind,
            language: row.optionalString(5)
        )
    }

    static func assetRecord(_ row: Row) throws -> AssetRecord {
        let importedAt = try date(row.string(8))
        return AssetRecord(
            id: row.string(0),
            entryID: row.string(1),
            sha256: row.string(2),
            mediaType: row.string(3),
            originalFilename: row.optionalString(4),
            byteSize: row.int64(5),
            durationSeconds: row.optionalDouble(6),
            blobPath: row.string(7),
            importedAt: importedAt
        )
    }

    static func date(_ value: String) throws -> Date {
        guard let date = Timestamps.date(value) else {
            throw ArchiveError.verificationFailed("invalid timestamp \(value)")
        }
        return date
    }

    static func encodeSettings(_ settings: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeSettings(_ json: String) throws -> [String: String] {
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        } catch {
            throw ArchiveError.verificationFailed("unreadable transcript settings")
        }
    }

    static func preview(_ text: String, length: Int = 100) -> String {
        let flat = TranscriptSanitizer.cleanText(text)
        guard flat.count > length else { return flat }
        return String(flat.prefix(length)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let cleaned = TranscriptSanitizer.cleanText(title)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(200))
    }
}
