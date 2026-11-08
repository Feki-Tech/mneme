import ArgumentParser
import Foundation
import MnemeCore
import MnemeSpeech

struct IngestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Transcribe audio files on this Mac and add them to the archive."
    )

    @Argument(help: "Audio files: wav, m4a, mp3, aiff, caf or flac.", completion: .file())
    var files: [String] = []

    @Option(help: "Title of the entry (one file only).")
    var title: String?

    @Option(name: .customLong("recorded-at"), help: "When it was recorded, for example 2026-11-07 or 2026-11-07T09:30:00Z (default: the file's creation date).")
    var recordedAt: String?

    @Option(help: "Language spoken, for example en, fr or ar (default: identified within your language profile).")
    var language: String?

    @Flag(help: "Transcribe files that are already archived again, as a new transcript version.")
    var retranscribe = false

    @Flag(help: "Print results as JSON.")
    var json = false

    @OptionGroup var archive: ArchiveOptions
    @OptionGroup var model: ModelOptions

    func validate() throws {
        if files.isEmpty {
            throw ValidationError("Give at least one audio file.")
        }
        if title != nil && files.count > 1 {
            throw ValidationError("--title applies to a single file.")
        }
        if let language, LanguagePolicy.resolve(language) == nil {
            throw ValidationError("Unsupported language “\(language)”. Use an ISO 639 code such as en, fr or ar.")
        }
        if let recordedAt, DateParsing.parse(recordedAt) == nil {
            throw ValidationError("Could not read the date “\(recordedAt)”. Use 2026-11-07 or 2026-11-07T09:30:00Z.")
        }
    }

    func run() async throws {
        let store = try archive.open()
        let engine = model.makeEngine()
        try model.requireModel(engine)
        let pipeline = IngestPipeline(archive: store, engine: engine, allowDownload: model.allowDownload)
        let allowDownload = model.allowDownload
        pipeline.willLoadModel = { profile in
            Console.status(Console.loadingMessage(for: profile, allowDownload: allowDownload, isReady: engine.isReady))
        }
        let forcedLanguage = language.flatMap { LanguagePolicy.resolve($0) }
        let date = recordedAt.flatMap { DateParsing.parse($0) }

        var outputs: [IngestOutput] = []
        var failures = 0
        for path in files {
            let url = Paths.url(path)
            do {
                let outcome = try await pipeline.ingest(
                    url,
                    title: title,
                    recordedAt: date,
                    language: forcedLanguage,
                    retranscribe: retranscribe
                )
                let output = Self.output(for: outcome, file: url.lastPathComponent)
                outputs.append(output)
                if !json {
                    Self.printOutcome(outcome, file: url.lastPathComponent)
                }
            } catch {
                failures += 1
                Console.status("Not archived: \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if json {
            try Console.json(outputs)
        }
        if failures > 0 {
            throw ExitCode.failure
        }
    }

    static func output(for outcome: IngestPipeline.Outcome, file: String) -> IngestOutput {
        switch outcome {
        case .created(let result):
            let transcript = result.transcript.transcript
            return IngestOutput(
                file: file,
                outcome: "created",
                entryID: result.entry.id,
                transcriptVersion: result.transcript.version,
                language: transcript.language.code,
                languageSource: transcript.language.source.rawValue,
                segments: transcript.segments.count,
                flaggedSegments: transcript.flaggedSegmentCount,
                sanitization: result.sanitization,
                text: transcript.text
            )
        case .duplicate(let entryID):
            return IngestOutput(file: file, outcome: "duplicate", entryID: entryID)
        case .retranscribed(let entryID, let record, let report):
            return IngestOutput(
                file: file,
                outcome: "retranscribed",
                entryID: entryID,
                transcriptVersion: record.version,
                language: record.transcript.language.code,
                languageSource: record.transcript.language.source.rawValue,
                segments: record.transcript.segments.count,
                flaggedSegments: record.transcript.flaggedSegmentCount,
                sanitization: report,
                text: record.transcript.text
            )
        }
    }

    static func printOutcome(_ outcome: IngestPipeline.Outcome, file: String) {
        switch outcome {
        case .created(let result):
            let transcript = result.transcript.transcript
            Console.out("Archived \(file) as entry \(Format.shortID(result.entry.id)) "
                + "(\(Format.duration(result.asset.durationSeconds)), \(Format.language(transcript.language)), "
                + "\(transcript.segments.count) segments, \(transcript.flaggedSegmentCount) flagged for review)")
            if !result.sanitization.isClean {
                Console.out("  Validation: \(result.sanitization.summary)")
            }
            Console.out("  \(transcript.text.isEmpty ? "(no speech detected)" : transcript.text)")
        case .duplicate(let entryID):
            Console.out("Skipped \(file): already archived as entry \(Format.shortID(entryID)) (use --retranscribe for a new version).")
        case .retranscribed(let entryID, let record, let report):
            Console.out("Saved transcript v\(record.version) of entry \(Format.shortID(entryID)) "
                + "(\(Format.language(record.transcript.language)), \(record.transcript.flaggedSegmentCount) flagged)")
            if !report.isClean {
                Console.out("  Validation: \(report.summary)")
            }
            Console.out("  \(record.transcript.text)")
        }
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List archived entries, most recent first.")

    @Option(help: "Number of entries.")
    var limit: Int = 20

    @Flag(help: "Print as JSON.")
    var json = false

    @OptionGroup var archive: ArchiveOptions

    func run() throws {
        let entries = try archive.open().recentEntries(limit: limit)
        if json {
            try Console.json(entries.map(EntryOutput.init))
            return
        }
        guard !entries.isEmpty else {
            Console.out("The archive is empty. Add a recording with: mneme ingest <file>")
            return
        }
        Console.out("\(Format.pad("ID", 10))\(Format.pad("Recorded", 18))\(Format.pad("Length", 8))\(Format.pad("Lang", 6))\(Format.pad("Ver", 5))\(Format.pad("Flags", 7))Title / text")
        for summary in entries {
            let label: String
            if let title = summary.entry.title {
                label = summary.preview.isEmpty ? title : "\(title): \(summary.preview)"
            } else {
                label = summary.preview
            }
            let version = summary.transcriptVersion.map { "v\($0)" } ?? "–"
            Console.out(
                Format.pad(Format.shortID(summary.entry.id), 10)
                    + Format.pad(Format.date(summary.entry.recordedAt), 18)
                    + Format.pad(Format.duration(summary.durationSeconds), 8)
                    + Format.pad(summary.entry.language ?? "–", 6)
                    + Format.pad(version, 5)
                    + Format.pad(String(summary.flaggedSegments), 7)
                    + label
            )
        }
    }
}

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show an entry with its transcript segments.")

    @Argument(help: "Entry ID, or at least 4 characters of it.")
    var entry: String

    @Option(name: [.customShort("v"), .customLong("transcript-version")], help: "Transcript version (default: the current one).")
    var transcriptVersion: Int?

    @Flag(help: "Include word timings.")
    var words = false

    @Flag(help: "Print as JSON.")
    var json = false

    @OptionGroup var archive: ArchiveOptions

    func run() throws {
        let store = try archive.open()
        let entryID = try store.resolveEntryID(entry)
        let details = try store.entryDetails(id: entryID, version: transcriptVersion)
        if json {
            try Console.json(ShowOutput(
                id: details.entry.id,
                title: details.entry.title,
                kind: details.entry.kind.rawValue,
                recordedAt: Timestamps.string(details.entry.recordedAt),
                createdAt: Timestamps.string(details.entry.createdAt),
                audioPath: details.audioURL?.path,
                sha256: details.asset?.sha256,
                durationSeconds: details.asset?.durationSeconds,
                versions: details.versions,
                transcriptVersion: details.transcript?.version,
                transcriptIsCurrent: details.transcript?.isCurrent,
                transcript: details.transcript?.transcript,
                note: details.note?.body,
                noteVersion: details.note?.version,
                noteVersions: details.entry.kind == .text ? details.noteVersions : nil
            ))
            return
        }
        Console.out("Entry     \(details.entry.id)")
        if let title = details.entry.title {
            Console.out("Title     \(title)")
        }
        Console.out("Recorded  \(Format.date(details.entry.recordedAt))")
        if let asset = details.asset {
            Console.out("Audio     \(details.audioURL?.path ?? asset.blobPath) (\(Format.duration(asset.durationSeconds)), \(asset.originalFilename ?? asset.mediaType))")
            Console.out("SHA-256   \(asset.sha256)")
        }
        if let note = details.note {
            let versions = details.noteVersions.map { "v\($0)" }.joined(separator: ", ")
            Console.out("Kind      written note, version v\(note.version) of \(versions)")
            if let language = details.entry.language {
                Console.out("Language  \(language)")
            }
            Console.out("")
            Console.out(note.body)
            return
        }
        guard let record = details.transcript else {
            Console.out(details.asset == nil ? "No transcript." : "Not transcribed yet.")
            return
        }
        let transcript = record.transcript
        let versions = details.versions.map { "v\($0)" }.joined(separator: ", ")
        Console.out("Version   v\(record.version)\(record.isCurrent ? " (current)" : "") of \(versions)")
        Console.out("Language  \(Format.language(transcript.language))")
        Console.out("Model     \(transcript.provenance.engine) / \(transcript.provenance.modelID)")
        if let seconds = transcript.processingSeconds {
            Console.out(String(format: "Processed in %.1f s", seconds))
        }
        Console.out("")
        let mixed = transcript.language.source == .mixed
        for segment in transcript.segments {
            let marks = Format.flags(segment.flags)
            let tag = mixed ? "[\(segment.language ?? transcript.language.code)] " : ""
            Console.out("#\(segment.index)  \(Format.position(segment.start))–\(Format.position(segment.end))  \(tag)\(segment.text)\(marks.isEmpty ? "" : "  " + marks)")
            if words {
                for word in segment.words {
                    let probability = word.probability.map { String(format: " p=%.2f", $0) } ?? ""
                    Console.out("      \(Format.position(word.start))–\(Format.position(word.end))  \(word.text)\(probability)")
                }
            }
        }
        if transcript.flaggedSegmentCount > 0 {
            Console.out("")
            Console.out("Flagged segments are worth checking. Fix one with: mneme correct \(Format.shortID(details.entry.id)) <segment> \"corrected text\"")
        }
    }
}

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search all current transcripts (case and accents ignored; the last word matches as a prefix)."
    )

    @Argument(help: "Words to search for.")
    var words: [String] = []

    @Option(help: "Maximum number of results.")
    var limit: Int = 20

    @Flag(help: "Print as JSON.")
    var json = false

    @OptionGroup var archive: ArchiveOptions

    func validate() throws {
        if words.isEmpty {
            throw ValidationError("Give at least one word to search for.")
        }
    }

    func run() throws {
        let hits = try archive.open().search(words.joined(separator: " "), limit: limit)
        if json {
            try Console.json(hits.map(SearchOutput.init))
            return
        }
        guard !hits.isEmpty else {
            Console.out("No matches.")
            return
        }
        for hit in hits {
            let title = hit.title.map { " \($0)" } ?? ""
            let location: String
            switch hit.source {
            case .transcript:
                location = "#\(hit.segmentIndex ?? 0) \(Format.position(hit.start ?? 0))"
            case .note:
                location = "note"
            case .title:
                location = "title"
            }
            Console.out("\(Format.shortID(hit.entryID))  \(Format.date(hit.recordedAt))\(title)  \(location)  \(hit.snippet)")
        }
    }
}

struct CorrectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "correct",
        abstract: "Correct one transcript segment. A new version is saved; earlier versions are kept.",
        discussion: "Corrected segments are marked as verified. They form your personal accent dataset (see export-verified)."
    )

    @Argument(help: "Entry ID, or at least 4 characters of it.")
    var entry: String

    @Argument(help: "Segment number, as shown by `mneme show`.")
    var segment: Int

    @Argument(help: "The corrected text.")
    var text: [String] = []

    @OptionGroup var archive: ArchiveOptions

    func validate() throws {
        if text.isEmpty {
            throw ValidationError("Give the corrected text.")
        }
    }

    func run() throws {
        let store = try archive.open()
        let entryID = try store.resolveEntryID(entry)
        let result = try store.correctSegment(entryID: entryID, segmentIndex: segment, text: text.joined(separator: " "))
        Console.out("Saved transcript v\(result.transcript.version) of entry \(Format.shortID(entryID)); segment \(segment) is marked as verified.")
        if !result.glossarySuggestions.isEmpty {
            let quoted = result.glossarySuggestions.map { "\"\($0)\"" }.joined(separator: " ")
            Console.out("New names or terms in your correction. To help future transcriptions spell them correctly:")
            Console.out("  mneme glossary add \(quoted)")
        }
    }
}

struct GlossaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "glossary",
        abstract: "Names and terms the recogniser should spell correctly (passed to Whisper as a prompt).",
        subcommands: [Add.self, Remove.self, Show.self],
        defaultSubcommand: Show.self
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Add terms.")

        @Argument(help: "Terms; quote terms that contain spaces.")
        var terms: [String] = []

        @OptionGroup var archive: ArchiveOptions

        func run() throws {
            guard !terms.isEmpty else {
                throw ValidationError("Give at least one term.")
            }
            let added = try archive.open().addGlossaryTerms(terms)
            Console.out(added.isEmpty ? "No new terms." : "Added: \(added.joined(separator: ", "))")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a term.")

        @Argument(help: "The term to remove.")
        var term: String

        @OptionGroup var archive: ArchiveOptions

        func run() throws {
            let removed = try archive.open().removeGlossaryTerm(term)
            Console.out(removed ? "Removed “\(term)”." : "“\(term)” is not in the glossary.")
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List terms in the order they were added.")

        @OptionGroup var archive: ArchiveOptions

        func run() throws {
            let terms = try archive.open().glossary()
            Console.out(terms.isEmpty ? "The glossary is empty." : terms.joined(separator: "\n"))
        }
    }
}

struct LanguagesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "languages",
        abstract: "The languages you speak. Language identification is restricted to them.",
        discussion: """
            Accented speech is often identified as the wrong language and then transcribed in it. \
            With a profile, Mneme chooses only among your languages; with a single language it skips \
            identification entirely.
            """,
        subcommands: [SetProfile.self, Show.self, Clear.self, Mixed.self],
        defaultSubcommand: Show.self
    )

    struct SetProfile: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Set your languages, most used first.")

        @Argument(help: "Codes or names, for example: en fr ar.")
        var languages: [String] = []

        @OptionGroup var archive: ArchiveOptions

        func run() throws {
            guard !languages.isEmpty else {
                throw ValidationError("Give at least one language, for example: mneme languages set en fr ar")
            }
            let codes = try archive.open().setLanguageProfile(languages.flatMap { LanguagePolicy.parseList($0) })
            Console.out("Language profile: \(LanguagesCommand.describe(codes))")
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show your languages.")

        @OptionGroup var archive: ArchiveOptions

        func run() throws {
            let codes = try archive.open().languageProfile()
            Console.out(codes.isEmpty
                ? "No language profile: any of Whisper's 100 languages can be identified. Set one with: mneme languages set en fr"
                : "Language profile: \(LanguagesCommand.describe(codes))")
        }
    }

    struct Mixed: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mixed",
            abstract: "Whether you switch languages within a recording (on by default).",
            discussion: """
                On: with two or more languages in the profile, each sentence gets its own language, so a \
                recording that switches from French to English is transcribed in both. Off: one language for \
                the whole recording, a little faster.
                """
        )

        @Argument(help: "on or off (omit to show the current setting).")
        var value: String?

        @OptionGroup var archive: ArchiveOptions

        func run() throws {
            let store = try archive.open()
            if let value {
                switch value.lowercased() {
                case "on", "yes", "true", "1":
                    try store.setMixedLanguages(true)
                case "off", "no", "false", "0":
                    try store.setMixedLanguages(false)
                default:
                    throw ValidationError("Use on or off.")
                }
            }
            let enabled = try store.mixedLanguages()
            Console.out(enabled
                ? "Mixed languages: on (each sentence gets its own language)."
                : "Mixed languages: off (one language per recording).")
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "clear", abstract: "Remove the profile.")

        @OptionGroup var archive: ArchiveOptions

        func run() throws {
            try archive.open().setLanguageProfile([])
            Console.out("Language profile cleared.")
        }
    }

    static func describe(_ codes: [String]) -> String {
        codes.map { code in
            WhisperLanguages.name(for: code).map { "\(code) (\($0))" } ?? code
        }.joined(separator: ", ")
    }
}

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check the database, the search index and the checksum of every stored recording."
    )

    @OptionGroup var archive: ArchiveOptions

    func run() throws {
        let report = try archive.open().integrityReport()
        Console.out("Database:      \(report.databaseCheck)")
        Console.out("Foreign keys:  \(report.foreignKeyViolations == 0 ? "ok" : "\(report.foreignKeyViolations) violation(s)")")
        Console.out("Search index:  \(report.searchIndexCheck)")
        Console.out("Recordings:    \(report.checkedBlobs) checked, \(report.missingBlobs.count) missing, \(report.corruptedBlobs.count) corrupted")
        for path in report.missingBlobs {
            Console.out("  missing:   \(path)")
        }
        for path in report.corruptedBlobs {
            Console.out("  corrupted: \(path)")
        }
        if !report.isHealthy {
            throw ExitCode.failure
        }
        Console.out("The archive is intact.")
    }
}

struct PathsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "paths", abstract: "Show where the archive and models are stored.")

    @OptionGroup var archive: ArchiveOptions
    @OptionGroup var model: ModelOptions

    func run() throws {
        Console.out("Archive:   \(archive.root.path)")
        Console.out("Database:  \(archive.root.appendingPathComponent(ArchiveStore.databaseFilename).path)")
        Console.out("Models:    \(model.modelsDirectory.path)")
    }
}

struct NoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Add a written note to the archive."
    )

    @Argument(help: "The note text (quote it).")
    var text: [String] = []

    @Option(help: "Title of the note.")
    var title: String?

    @OptionGroup var archive: ArchiveOptions

    func run() throws {
        guard !text.isEmpty else {
            throw ValidationError("Give the text of the note.")
        }
        let result = try archive.open().addNote(title: title, body: text.joined(separator: " "))
        let language = result.entry.language.map { ", language \($0)" } ?? ""
        Console.out("Saved note \(Format.shortID(result.entry.id))\(language).")
    }
}

struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Permanently delete an entry with its recording, transcripts and notes."
    )

    @Argument(help: "Entry ID, or at least 4 characters of it.")
    var entry: String

    @Flag(help: "Confirm the deletion; it cannot be undone.")
    var yes = false

    @OptionGroup var archive: ArchiveOptions

    func run() throws {
        let store = try archive.open()
        let entryID = try store.resolveEntryID(entry)
        guard yes else {
            throw ValidationError("Deleting \(Format.shortID(entryID)) cannot be undone. Add --yes to confirm.")
        }
        try store.deleteEntry(id: entryID)
        Console.out("Deleted entry \(Format.shortID(entryID)).")
    }
}
