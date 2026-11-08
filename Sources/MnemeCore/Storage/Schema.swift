import Foundation

/// Versioned schema migrations, tracked in SQLite's `user_version`.
enum Schema {
    static var version: Int {
        migrations.count
    }

    static let migrations: [String] = [v1, v2, v3]

    static func migrate(_ database: Database) throws {
        let current = try database.userVersion()
        guard current <= migrations.count else {
            throw ArchiveError.schemaTooNew(found: current, supported: migrations.count)
        }
        for index in current..<migrations.count {
            try database.transaction {
                try database.execute(migrations[index])
                try database.execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    // STRICT tables reject values of the wrong type; CHECK constraints reject impossible values.
    private static let v1 = """
        CREATE TABLE entry (
            id TEXT PRIMARY KEY NOT NULL,
            created_at TEXT NOT NULL,
            recorded_at TEXT NOT NULL,
            title TEXT,
            kind TEXT NOT NULL CHECK (kind IN ('voice', 'text', 'video')),
            language TEXT,
            privacy TEXT NOT NULL DEFAULT 'standard' CHECK (privacy IN ('standard', 'vault'))
        ) STRICT;

        CREATE INDEX entry_recorded_at ON entry (recorded_at);

        CREATE TABLE asset (
            id TEXT PRIMARY KEY NOT NULL,
            entry_id TEXT NOT NULL REFERENCES entry (id) ON DELETE CASCADE,
            sha256 TEXT NOT NULL UNIQUE CHECK (length(sha256) = 64),
            media_type TEXT NOT NULL,
            original_filename TEXT,
            byte_size INTEGER NOT NULL CHECK (byte_size > 0),
            duration_s REAL CHECK (duration_s IS NULL OR duration_s > 0),
            blob_path TEXT NOT NULL UNIQUE,
            imported_at TEXT NOT NULL
        ) STRICT;

        CREATE INDEX asset_entry ON asset (entry_id);

        CREATE TABLE transcript (
            id TEXT PRIMARY KEY NOT NULL,
            asset_id TEXT NOT NULL REFERENCES asset (id) ON DELETE CASCADE,
            version INTEGER NOT NULL CHECK (version >= 1),
            language TEXT NOT NULL CHECK (length(language) BETWEEN 2 AND 3),
            language_probability REAL CHECK (language_probability IS NULL OR language_probability BETWEEN 0 AND 1),
            language_source TEXT NOT NULL,
            model_top_language TEXT,
            text TEXT NOT NULL,
            engine TEXT NOT NULL,
            model_id TEXT NOT NULL,
            settings_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            processing_s REAL,
            flagged_segments INTEGER NOT NULL DEFAULT 0 CHECK (flagged_segments >= 0),
            is_current INTEGER NOT NULL DEFAULT 1 CHECK (is_current IN (0, 1)),
            UNIQUE (asset_id, version)
        ) STRICT;

        -- At most one current transcript per recording; older versions stay for auditing.
        CREATE UNIQUE INDEX transcript_one_current ON transcript (asset_id) WHERE is_current = 1;

        CREATE TABLE segment (
            transcript_id TEXT NOT NULL REFERENCES transcript (id) ON DELETE CASCADE,
            idx INTEGER NOT NULL CHECK (idx >= 0),
            start_s REAL NOT NULL CHECK (start_s >= 0),
            end_s REAL NOT NULL,
            text TEXT NOT NULL,
            avg_logprob REAL,
            compression_ratio REAL,
            no_speech_prob REAL CHECK (no_speech_prob IS NULL OR no_speech_prob BETWEEN 0 AND 1),
            temperature REAL,
            flags TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (transcript_id, idx),
            CHECK (end_s >= start_s)
        ) STRICT;

        CREATE TABLE word (
            transcript_id TEXT NOT NULL,
            segment_idx INTEGER NOT NULL,
            idx INTEGER NOT NULL CHECK (idx >= 0),
            text TEXT NOT NULL,
            start_s REAL NOT NULL CHECK (start_s >= 0),
            end_s REAL NOT NULL,
            probability REAL CHECK (probability IS NULL OR probability BETWEEN 0 AND 1),
            PRIMARY KEY (transcript_id, segment_idx, idx),
            FOREIGN KEY (transcript_id, segment_idx) REFERENCES segment (transcript_id, idx) ON DELETE CASCADE,
            CHECK (end_s >= start_s)
        ) STRICT;

        -- Full-text index over the segments of current transcripts; diacritics are ignored (munster finds Münster).
        CREATE VIRTUAL TABLE segment_fts USING fts5 (
            text,
            transcript_id UNINDEXED,
            segment_idx UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TABLE glossary_term (
            term TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
            added_at TEXT NOT NULL
        ) STRICT;

        CREATE TABLE setting (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        ) STRICT;

        CREATE TABLE processing_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            at TEXT NOT NULL,
            operation TEXT NOT NULL,
            target_id TEXT,
            model_id TEXT,
            tier TEXT NOT NULL DEFAULT 'device',
            detail TEXT
        ) STRICT;
        """

    // Written notes, versioned like transcripts, with their own full-text index (title and body).
    private static let v2 = """
        CREATE TABLE note_version (
            id TEXT PRIMARY KEY NOT NULL,
            entry_id TEXT NOT NULL REFERENCES entry (id) ON DELETE CASCADE,
            version INTEGER NOT NULL CHECK (version >= 1),
            body TEXT NOT NULL CHECK (length(body) > 0),
            created_at TEXT NOT NULL,
            is_current INTEGER NOT NULL DEFAULT 1 CHECK (is_current IN (0, 1)),
            UNIQUE (entry_id, version)
        ) STRICT;

        CREATE UNIQUE INDEX note_one_current ON note_version (entry_id) WHERE is_current = 1;

        CREATE VIRTUAL TABLE note_fts USING fts5 (
            text,
            entry_id UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """

    // The language each segment was decoded in, for speakers who switch languages within a recording.
    private static let v3 = """
        ALTER TABLE segment ADD COLUMN language TEXT CHECK (language IS NULL OR length(language) BETWEEN 2 AND 3);
        """
}
