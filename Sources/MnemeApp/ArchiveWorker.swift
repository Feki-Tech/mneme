import Foundation
import MnemeCore
import MnemeSpeech

/// Owns the archive and the speech engine, off the main thread. Calls are serialised by the actor;
/// transcriptions are additionally queued one at a time by `AppModel`.
actor ArchiveWorker {
    private let archiveRoot: URL
    private let modelsDirectory: URL
    private var profile: ModelProfile
    private var storeValue: ArchiveStore?
    private var pipelineValue: IngestPipeline?
    /// The model load in progress, shared by everything that needs the model (one load at a time).
    private var loadTask: Task<Void, Error>?

    init(archiveRoot: URL, modelsDirectory: URL, profile: ModelProfile) {
        self.archiveRoot = archiveRoot
        self.modelsDirectory = modelsDirectory
        self.profile = profile
    }

    private func store() throws -> ArchiveStore {
        if let storeValue {
            return storeValue
        }
        let opened = try ArchiveStore(root: archiveRoot)
        storeValue = opened
        return opened
    }

    /// The model is only ever loaded from this Mac: downloads happen solely through `downloadModel`.
    private func pipeline() throws -> IngestPipeline {
        if let pipelineValue {
            return pipelineValue
        }
        let engine = WhisperEngine(profile: profile, modelsDirectory: modelsDirectory)
        let created = IngestPipeline(archive: try store(), engine: engine, allowDownload: false)
        pipelineValue = created
        return created
    }

    // MARK: Model

    func setProfile(_ newProfile: ModelProfile) {
        guard newProfile != profile else { return }
        profile = newProfile
        pipelineValue = nil
        loadTask = nil
    }

    /// Loads the model once and keeps it in memory, so a recording is transcribed as soon as it is saved.
    /// Concurrent callers wait for the same load.
    func ensureModelLoaded() async throws {
        let engine = try pipeline().engine
        if engine.isLoaded {
            return
        }
        if let loadTask {
            return try await loadTask.value
        }
        let task = Task {
            try await engine.load(allowDownload: false)
        }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
        } catch {
            loadTask = nil
            throw error
        }
    }

    func isModelReady() -> Bool {
        ModelLocator.readyModelFolder(variant: profile.variant, base: modelsDirectory) != nil
    }

    /// True once the model is loaded in this session (the first load can take minutes).
    func isModelLoaded() -> Bool {
        pipelineValue?.engine.isLoaded ?? false
    }

    /// Downloads the model the user chose, then loads it once so it is prepared for offline use.
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let chosen = profile
        try await WhisperEngine.download(profile: chosen, modelsDirectory: modelsDirectory, progress: progress)
        let engine = WhisperEngine(profile: chosen, modelsDirectory: modelsDirectory)
        try await engine.load(allowDownload: true)
        if chosen == profile {
            pipelineValue = IngestPipeline(archive: try store(), engine: engine, allowDownload: false)
        }
    }

    // MARK: Reading

    func entries() throws -> [EntrySummary] {
        try store().recentEntries(limit: 2000)
    }

    func details(id: String) throws -> EntryDetails {
        try store().entryDetails(id: id)
    }

    func search(_ query: String) throws -> [SearchHit] {
        try store().search(query, limit: 200)
    }

    func flaggedSegments() throws -> [FlaggedSegment] {
        try store().flaggedSegments()
    }

    func untranscribed() throws -> [String] {
        try store().untranscribedEntries()
    }

    func verify() throws -> IntegrityReport {
        try store().integrityReport()
    }

    // MARK: Writing

    /// Archives a recording without a transcript, so it is safe before transcription starts.
    ///
    /// A CAF working file is encoded to AAC first; the recording date is when the working file was created.
    /// If an earlier attempt was interrupted after the archive write, the existing entry is returned instead
    /// of a second one. The caller deletes the working file once this returns.
    func importRecording(url: URL, title: String?) throws -> EntryRecord {
        let archive = try store()
        guard url.pathExtension.lowercased() == "caf" else {
            let audio = try AudioPreparer.prepare(url)
            return try archive.ingestAudio(audio, title: title).entry
        }
        let encoded = url.deletingPathExtension().appendingPathExtension("m4a")
        if let existing = try archive.asset(originalFilename: encoded.lastPathComponent),
           let entry = try archive.entry(id: existing.entryID) {
            return entry
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let startedAt = attributes?[.creationDate] as? Date
        try AudioEncoder.encodeAAC(from: url, to: encoded)
        defer { try? FileManager.default.removeItem(at: encoded) }
        let audio = try AudioPreparer.prepare(encoded)
        return try archive.ingestAudio(audio, title: title, recordedAt: startedAt).entry
    }

    /// False once the entry has been deleted.
    func exists(entryID: String) -> Bool {
        (try? store().entry(id: entryID)) != nil
    }

    func transcribe(entryID: String, language: String?, progress: TranscriptionProgressHandler? = nil) async throws {
        try await ensureModelLoaded()
        try await pipeline().transcribeEntry(entryID, language: language, progress: progress)
    }

    func correct(entryID: String, segment: Int, text: String) throws -> CorrectionResult {
        try store().correctSegment(entryID: entryID, segmentIndex: segment, text: text)
    }

    func confirm(entryID: String, segment: Int) throws -> CorrectionResult {
        try store().confirmSegment(entryID: entryID, segmentIndex: segment)
    }

    func addNote(title: String?, body: String) throws -> String {
        try store().addNote(title: title, body: body).entry.id
    }

    func updateNote(entryID: String, title: String?, body: String) throws {
        _ = try store().updateNote(entryID: entryID, title: title, body: body)
    }

    func rename(entryID: String, title: String?) throws {
        try store().renameEntry(id: entryID, title: title)
    }

    func delete(entryID: String) throws {
        try store().deleteEntry(id: entryID)
    }

    // MARK: Settings

    func languageProfile() throws -> [String] {
        try store().languageProfile()
    }

    func setLanguageProfile(_ items: [String]) throws -> [String] {
        try store().setLanguageProfile(items)
    }

    func glossary() throws -> [String] {
        try store().glossary()
    }

    func mixedLanguages() throws -> Bool {
        try store().mixedLanguages()
    }

    func setMixedLanguages(_ enabled: Bool) throws {
        try store().setMixedLanguages(enabled)
    }

    func addGlossaryTerms(_ terms: [String]) throws {
        try store().addGlossaryTerms(terms)
    }

    func removeGlossaryTerm(_ term: String) throws {
        try store().removeGlossaryTerm(term)
    }
}
