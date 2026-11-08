import Foundation

/// Written notes, titles, deletion and the review queues.
extension ArchiveStore {
    // MARK: - Notes

    /// Archives a written note. Its language is identified on the device when the text is long enough.
    @discardableResult
    public func addNote(title: String?, body: String, recordedAt: Date? = nil) throws -> (entry: EntryRecord, note: NoteRecord) {
        let text = try NoteText.validated(body)
        let now = Timestamps.now()
        let cleanTitle = ArchiveStore.cleanTitle(title)
        let entryRecord = EntryRecord(
            id: Identifiers.newID(at: now),
            createdAt: now,
            recordedAt: Timestamps.truncated(recordedAt ?? now),
            title: cleanTitle,
            kind: .text,
            language: NoteText.detectLanguage(text)
        )
        let noteID = Identifiers.newID(at: now)
        return try database.transaction { () -> (entry: EntryRecord, note: NoteRecord) in
            try insertEntry(entryRecord)
            try insertNoteVersion(id: noteID, entryID: entryRecord.id, version: 1, body: text, createdAt: now)
            try indexNote(entryID: entryRecord.id, title: cleanTitle, body: text)
            try appendLog("note", target: entryRecord.id, modelID: nil, detail: "note v1")
            let storedEntry = try verifiedEntry(entryRecord)
            let storedNote = try verifiedCurrentNote(entryID: entryRecord.id, expectedID: noteID, body: text)
            return (entry: storedEntry, note: storedNote)
        }
    }

    /// Saves an edited note as a new version; earlier versions are kept. A changed title is updated in place.
    @discardableResult
    public func updateNote(entryID: String, title: String?, body: String) throws -> NoteRecord {
        guard let record = try entry(id: entryID), record.kind == .text,
              let current = try currentNote(entryID: entryID) else {
            throw ArchiveError.notFound("note \(entryID)")
        }
        let text = try NoteText.validated(body)
        let cleanTitle = ArchiveStore.cleanTitle(title)
        if current.body == text && record.title == cleanTitle {
            return current
        }
        let now = Timestamps.now()
        let noteID = Identifiers.newID(at: now)
        return try database.transaction { () -> NoteRecord in
            try database.run(
                "UPDATE entry SET title = ?, language = ? WHERE id = ?",
                [.optional(cleanTitle), .optional(NoteText.detectLanguage(text)), .text(entryID)]
            )
            try indexNote(entryID: entryID, title: cleanTitle, body: text)
            if current.body == text {
                try appendLog("rename", target: entryID, modelID: nil, detail: nil)
                return current
            }
            let latest = try database.int("SELECT MAX(version) FROM note_version WHERE entry_id = ?", [.text(entryID)]) ?? 0
            try database.run(
                "UPDATE note_version SET is_current = 0 WHERE entry_id = ? AND is_current = 1",
                [.text(entryID)]
            )
            try insertNoteVersion(id: noteID, entryID: entryID, version: latest + 1, body: text, createdAt: now)
            try appendLog("note", target: entryID, modelID: nil, detail: "note v\(latest + 1)")
            return try verifiedCurrentNote(entryID: entryID, expectedID: noteID, body: text)
        }
    }

    public func currentNote(entryID: String) throws -> NoteRecord? {
        try loadNote(where: "entry_id = ? AND is_current = 1", [.text(entryID)])
    }

    func loadNote(where clause: String, _ parameters: [SQLValue]) throws -> NoteRecord? {
        try database.query(
            "SELECT id, entry_id, version, is_current, created_at, body FROM note_version WHERE \(clause) LIMIT 1",
            parameters
        ) { (row: Row) -> NoteRecord in
            let createdAt = try ArchiveStore.date(row.string(4))
            return NoteRecord(
                id: row.string(0),
                entryID: row.string(1),
                version: row.int(2),
                isCurrent: row.bool(3),
                createdAt: createdAt,
                body: row.string(5)
            )
        }.first
    }

    func insertNoteVersion(id: String, entryID: String, version: Int, body: String, createdAt: Date) throws {
        try database.run(
            "INSERT INTO note_version (id, entry_id, version, body, created_at, is_current) VALUES (?, ?, ?, ?, ?, 1)",
            [.text(id), .text(entryID), .int(version), .text(body), .text(Timestamps.string(createdAt))]
        )
    }

    /// The search index holds the title and the current body of each note.
    func indexNote(entryID: String, title: String?, body: String) throws {
        try database.run("DELETE FROM note_fts WHERE entry_id = ?", [.text(entryID)])
        let text = [title, body].compactMap { $0 }.joined(separator: "\n")
        try database.run("INSERT INTO note_fts (text, entry_id) VALUES (?, ?)", [.text(text), .text(entryID)])
    }

    func verifiedCurrentNote(entryID: String, expectedID: String, body: String) throws -> NoteRecord {
        guard let stored = try currentNote(entryID: entryID) else {
            throw ArchiveError.verificationFailed("the note could not be read back")
        }
        guard stored.id == expectedID, stored.body == body else {
            throw ArchiveError.verificationFailed("the stored note differs from the input")
        }
        let indexed = try database.int("SELECT COUNT(*) FROM note_fts WHERE entry_id = ?", [.text(entryID)]) ?? 0
        guard indexed == 1 else {
            throw ArchiveError.verificationFailed("the search index has \(indexed) rows for the note")
        }
        return stored
    }

    // MARK: - Titles and deletion

    /// Sets or clears an entry's title.
    public func renameEntry(id: String, title: String?) throws {
        guard let record = try entry(id: id) else {
            throw ArchiveError.notFound("entry \(id)")
        }
        let cleanTitle = ArchiveStore.cleanTitle(title)
        guard cleanTitle != record.title else { return }
        try database.transaction {
            try database.run("UPDATE entry SET title = ? WHERE id = ?", [.optional(cleanTitle), .text(id)])
            if record.kind == .text, let note = try currentNote(entryID: id) {
                try indexNote(entryID: id, title: cleanTitle, body: note.body)
            }
            try appendLog("rename", target: id, modelID: nil, detail: nil)
        }
    }

    /// Permanently deletes an entry with its recordings, transcripts, notes and search entries.
    /// Database pages are overwritten (secure_delete) and the original files are removed.
    public func deleteEntry(id: String) throws {
        let recordings = try assets(entryID: id)
        try database.transaction {
            try database.run("""
                DELETE FROM segment_fts WHERE transcript_id IN (
                    SELECT t.id FROM transcript t JOIN asset a ON a.id = t.asset_id WHERE a.entry_id = ?
                )
                """, [.text(id)])
            try database.run("DELETE FROM note_fts WHERE entry_id = ?", [.text(id)])
            try database.run("DELETE FROM entry WHERE id = ?", [.text(id)])
            guard database.changesInLastStatement == 1 else {
                throw ArchiveError.notFound("entry \(id)")
            }
            try appendLog("delete", target: id, modelID: nil, detail: "\(recordings.count) recording(s)")
        }
        for recording in recordings {
            blobs.remove(relativePath: recording.blobPath)
        }
        try? database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// The recording archived from a file with this name, if any. The app names each recording uniquely, so an
    /// import interrupted after the archive write can resume without creating a second entry.
    public func asset(originalFilename name: String) throws -> AssetRecord? {
        try database.query(
            "SELECT \(ArchiveStore.assetColumns) FROM asset WHERE original_filename = ? ORDER BY imported_at LIMIT 1",
            [.text(name)]
        ) { (row: Row) -> AssetRecord in
            try ArchiveStore.assetRecord(row)
        }.first
    }

    // MARK: - Review queues

    /// Voice entries whose recording has no transcript yet, oldest first.
    public func untranscribedEntries() throws -> [String] {
        try database.query("""
            SELECT e.id
            FROM entry e
            JOIN asset a ON a.entry_id = e.id
            WHERE NOT EXISTS (SELECT 1 FROM transcript t WHERE t.asset_id = a.id)
            ORDER BY e.created_at, e.id
            """) { (row: Row) -> String in
            row.string(0)
        }
    }

    /// Segments of current transcripts carrying a quality warning, most recent entries first.
    public func flaggedSegments(limit: Int = 500) throws -> [FlaggedSegment] {
        let rows = try database.query("""
            SELECT e.id, e.title, e.recorded_at, t.version, s.idx, s.start_s, s.end_s, s.text, s.flags, a.blob_path
            FROM segment s
            JOIN transcript t ON t.id = s.transcript_id AND t.is_current = 1
            JOIN asset a ON a.id = t.asset_id
            JOIN entry e ON e.id = a.entry_id
            WHERE s.flags != '' AND instr(s.flags, 'user_verified') = 0
            ORDER BY e.recorded_at DESC, e.id, s.idx
            LIMIT ?
            """, [.int(max(1, limit))]) { (row: Row) -> FlaggedSegment in
            let recordedAt = try ArchiveStore.date(row.string(2))
            return FlaggedSegment(
                entryID: row.string(0),
                title: row.optionalString(1),
                recordedAt: recordedAt,
                transcriptVersion: row.int(3),
                segmentIndex: row.int(4),
                start: row.double(5),
                end: row.double(6),
                text: row.string(7),
                flags: QualityFlag.decode(row.string(8)),
                audioURL: blobs.url(forRelativePath: row.string(9))
            )
        }
        return rows.filter { !$0.flags.isEmpty && !$0.flags.contains(.userVerified) }
    }

    /// Confirms that a segment's text is right: a new version in which the segment is marked as verified.
    @discardableResult
    public func confirmSegment(entryID: String, segmentIndex: Int) throws -> CorrectionResult {
        let details = try entryDetails(id: entryID)
        guard let segment = details.transcript?.transcript.segments.first(where: { $0.index == segmentIndex }) else {
            throw ArchiveError.notFound("segment \(segmentIndex) of entry \(entryID)")
        }
        return try correctSegment(entryID: entryID, segmentIndex: segmentIndex, text: segment.text)
    }
}
