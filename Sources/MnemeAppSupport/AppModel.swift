import Foundation
import MnemeCore
import MnemeSpeech
import SwiftUI

/// The app's state. Archive work runs in `ArchiveWorker`; transcriptions run one at a time.
@MainActor
public final class AppModel: ObservableObject {
    public enum Route: Hashable {
        case home
        case entry(String)
        case recorder
        case newNote
        case review
    }

    public enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case voice = "Voice"
        case notes = "Notes"
        case attention = "To review"

        public var id: String { rawValue }
    }

    public struct Notice: Identifiable {
        public let id = UUID()
        public let title: String
        public let message: String
    }

    @Published public var route: Route = .home
    @Published public var filter: Filter = .all
    @Published public var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published public var notice: Notice?
    /// Entry waiting for the user to confirm its deletion.
    @Published public var pendingDeletion: String?
    /// The file picker for importing recordings is open.
    @Published public var isImportingFiles = false
    /// Glossary suggestions from the last correction.
    @Published public var suggestions: [String] = []

    @Published public private(set) var entries: [EntrySummary] = []
    @Published public private(set) var searchHits: [SearchHit] = []
    @Published public private(set) var details: EntryDetails?
    @Published public private(set) var flagged: [FlaggedSegment] = []
    @Published public private(set) var transcribingEntryID: String?
    @Published public private(set) var queuedEntryIDs: [String] = []
    @Published public private(set) var modelReady = false
    /// The model is loaded in this session; until then the first transcription also loads it.
    @Published public private(set) var modelLoaded = false
    /// The model is being loaded ahead of time (at launch or when a recording starts).
    @Published public private(set) var isPreparingModel = false
    /// Share of the current transcription done, and its text so far.
    @Published public private(set) var transcriptionProgress: Double?
    @Published public private(set) var partialTranscript = ""
    /// Each sentence gets its own language (for speakers who switch languages within a recording).
    @Published public private(set) var mixedLanguages = true
    @Published public private(set) var modelProfile: ModelProfile
    @Published public private(set) var isDownloading = false
    @Published public private(set) var downloadProgress: Double?
    @Published public private(set) var languageProfile: [String] = []
    @Published public private(set) var glossary: [String] = []

    public let recorder = RecorderModel()
    public let player = PlayerModel()
    public let archiveRoot: URL
    public let modelsDirectory: URL

    private let worker: ArchiveWorker
    private var searchTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var languageOverrides: [String: String] = [:]
    private var started = false

    private static let profileKey = "modelProfile"

    public init(archiveRoot: URL = ArchiveStore.defaultRoot, modelsDirectory: URL = ModelLocator.defaultModelsDirectory) {
        let profile = ModelProfile.resolve(UserDefaults.standard.string(forKey: AppModel.profileKey) ?? ModelProfile.defaultProfile.name)
        self.archiveRoot = archiveRoot
        self.modelsDirectory = modelsDirectory
        self.modelProfile = profile
        self.worker = ArchiveWorker(archiveRoot: archiveRoot, modelsDirectory: modelsDirectory, profile: profile)
    }

    /// Recordings in progress, and any that could not be archived, live here (private to the user).
    public var recordingsFolder: URL {
        archiveRoot.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
    }

    public var visibleEntries: [EntrySummary] {
        switch filter {
        case .all:
            return entries
        case .voice:
            return entries.filter { $0.entry.kind == .voice }
        case .notes:
            return entries.filter { $0.entry.kind == .text }
        case .attention:
            return entries.filter { $0.flaggedSegments > 0 || $0.needsTranscription }
        }
    }

    /// Search results, one row per entry (the best match).
    public var visibleSearchHits: [SearchHit] {
        var seen = Set<String>()
        return searchHits.filter { seen.insert($0.entryID).inserted }
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !started else { return }
        started = true
        #if os(iOS)
        // Models can be downloaded again: they stay out of the iPhone's backups.
        Self.setExcludedFromBackup(modelsDirectory, true)
        Self.setExcludedFromBackup(archiveRoot.deletingLastPathComponent(), !includeArchiveInBackups)
        #endif
        await refreshSettings()
        await reload()
        await recoverRecordings()
        await refreshModelStatus()
        await queueUntranscribed()
        prepareModel()
    }

    /// Loads the model in the background so the next transcription starts at once. Loading the large model
    /// takes several seconds, and minutes the first time after an installation while Core ML prepares it.
    public func prepareModel() {
        guard modelReady, !modelLoaded, !isPreparingModel else { return }
        isPreparingModel = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.worker.ensureModelLoaded()
                self.modelLoaded = true
            } catch {
                // Reported when a transcription needs the model.
            }
            self.isPreparingModel = false
        }
    }

    public func reload() async {
        do {
            entries = try await worker.entries()
            flagged = try await worker.flaggedSegments()
            if case .entry(let id) = route {
                await loadDetails(id)
            }
        } catch {
            show(error)
        }
    }

    public func loadDetails(_ id: String) async {
        do {
            details = try await worker.details(id: id)
        } catch {
            details = nil
            show(error)
        }
    }

    // MARK: - Recording

    public func startRecording() async {
        if recorder.permission != .granted {
            await recorder.requestPermission()
        }
        guard recorder.permission == .granted else {
            #if os(iOS)
            let place = "Settings > Privacy & Security > Microphone"
            #else
            let place = "System Settings > Privacy & Security > Microphone"
            #endif
            notice = Notice(title: "Microphone access is off", message: "Allow Mneme in \(place), then try again.")
            return
        }
        do {
            try recorder.start(in: recordingsFolder)
            prepareModel()
        } catch {
            show(error)
        }
    }

    /// Stops, archives the original at once, then queues the transcription.
    public func finishRecording(title: String, language: String?) async {
        let length = recorder.elapsed
        guard let url = recorder.stop() else { return }
        if length < 0.5 {
            try? FileManager.default.removeItem(at: url)
            notice = Notice(title: "Nothing was kept", message: "The recording was shorter than half a second.")
            return
        }
        if let entryID = await archiveRecording(url, title: title) {
            route = .entry(entryID)
            queueTranscription(entryID, language: language)
        }
    }

    /// Returns the entry ID. The working file is removed only after the archive has verified its copy.
    private func archiveRecording(_ url: URL, title: String?, quiet: Bool = false) async -> String? {
        do {
            let entry = try await worker.importRecording(url: url, title: title)
            try? FileManager.default.removeItem(at: url)
            await reload()
            return entry.id
        } catch ArchiveError.duplicateRecording(let entryID) {
            // Archived before, byte for byte: the archive's copy has already been verified.
            try? FileManager.default.removeItem(at: url)
            return entryID
        } catch {
            if !quiet {
                notice = Notice(
                    title: "The recording was kept but not archived",
                    message: "\(error.localizedDescription)\n\nThe file is still in \(url.path) and will be retried at the next launch."
                )
            }
            return nil
        }
    }

    /// Archives recordings left behind by an interrupted session: working files (.caf) keep everything
    /// recorded up to the interruption. An .m4a next to a .caf is an unfinished encoding and is redone.
    private func recoverRecordings() async {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: nil) else {
            return
        }
        let workingNames = Set(files.filter { $0.pathExtension.lowercased() == "caf" }.map { $0.deletingPathExtension().lastPathComponent })
        var failed: [URL] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let kind = file.pathExtension.lowercased()
            guard kind == "caf" || kind == "m4a", file.lastPathComponent != recorder.activeFileName else {
                continue
            }
            if kind == "m4a" && workingNames.contains(file.deletingPathExtension().lastPathComponent) {
                try? fileManager.removeItem(at: file)
                continue
            }
            if await archiveRecording(file, title: nil, quiet: true) == nil {
                failed.append(file)
            }
        }
        guard !failed.isEmpty else { return }
        let damaged = recordingsFolder.appendingPathComponent("Not archived", isDirectory: true)
        try? fileManager.createDirectory(at: damaged, withIntermediateDirectories: true)
        for file in failed {
            try? fileManager.moveItem(at: file, to: damaged.appendingPathComponent(file.lastPathComponent))
        }
        notice = Notice(
            title: "Some recordings could not be archived",
            message: "\(failed.count) unfinished recording(s) from an earlier session could not be read. They were moved to \(damaged.path)."
        )
    }

    // MARK: - Import and export

    /// Archives audio files (for example recordings exported by Mneme on an iPhone) and queues their transcription.
    /// Files written by Mneme keep their recording date and title, which are part of their names.
    public func importAudioFiles(_ urls: [URL]) async {
        var imported: [String] = []
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                imported.append(try await worker.importRecording(url: url, title: nil).id)
            } catch ArchiveError.duplicateRecording(let entryID) {
                imported.append(entryID)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        await reload()
        for entryID in imported {
            queueTranscription(entryID)
        }
        if let first = imported.first, imported.count == 1 {
            route = .entry(first)
        }
        if !failures.isEmpty {
            notice = Notice(title: "Some files could not be imported", message: failures.joined(separator: "\n"))
        }
    }

    /// The entry's original recording and a Markdown copy, in a temporary folder, ready to share.
    public func exportFiles(entryID: String) async -> [URL] {
        do {
            return try await worker.exportFiles(entryID: entryID, to: exportDirectory)
        } catch {
            show(error)
            return []
        }
    }

    /// Every entry's recording and Markdown copy in one folder.
    public func exportAll() async -> URL? {
        do {
            return try await worker.exportAll(to: exportDirectory)
        } catch {
            show(error)
            return nil
        }
    }

    private var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Mneme exports", isDirectory: true)
    }

    #if os(iOS)
    private static let backupKey = "includeArchiveInBackups"

    /// Whether the archive (not the models) is part of the iPhone's iCloud or computer backups. On by default, so a
    /// lost phone does not mean lost recordings.
    public var includeArchiveInBackups: Bool {
        get { UserDefaults.standard.object(forKey: Self.backupKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.backupKey)
            Self.setExcludedFromBackup(archiveRoot.deletingLastPathComponent(), !newValue)
            Self.setExcludedFromBackup(modelsDirectory, true)
        }
    }

    private static func setExcludedFromBackup(_ folder: URL, _ excluded: Bool) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        var target = folder
        try? target.setResourceValues(values)
    }
    #endif

    // MARK: - Transcription queue

    public func queueTranscription(_ entryID: String, language: String? = nil) {
        if let language {
            languageOverrides[entryID] = language
        }
        guard modelReady else { return }
        guard transcribingEntryID != entryID, !queuedEntryIDs.contains(entryID) else { return }
        queuedEntryIDs.append(entryID)
        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while !queuedEntryIDs.isEmpty {
            let entryID = queuedEntryIDs.removeFirst()
            transcribingEntryID = entryID
            transcriptionProgress = 0
            partialTranscript = ""
            modelLoaded = await worker.isModelLoaded()
            do {
                try await worker.transcribe(entryID: entryID, language: languageOverrides[entryID]) { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.transcribingEntryID == entryID else { return }
                        self.modelLoaded = true
                        self.transcriptionProgress = update.fractionCompleted
                        self.partialTranscript = update.text
                    }
                }
                languageOverrides[entryID] = nil
                modelLoaded = true
            } catch {
                if await worker.isModelLoaded() {
                    notice = Notice(title: "Transcription failed", message: error.localizedDescription)
                } else {
                    // Without a working model every queued recording would fail the same way.
                    queuedEntryIDs.removeAll()
                    notice = Notice(
                        title: "The speech model could not be loaded",
                        message: "\(error.localizedDescription)\n\nYour recordings stay archived and can be transcribed later."
                    )
                }
            }
            transcribingEntryID = nil
            transcriptionProgress = nil
            partialTranscript = ""
            await reload()
        }
        queueTask = nil
    }

    private func queueUntranscribed() async {
        guard modelReady, let pending = try? await worker.untranscribed() else { return }
        for entryID in pending {
            queueTranscription(entryID)
        }
    }

    // MARK: - Review and corrections

    public func correct(entryID: String, segment: Int, text: String) async -> Bool {
        do {
            let result = try await worker.correct(entryID: entryID, segment: segment, text: text)
            suggestions = result.glossarySuggestions
            await reload()
            return true
        } catch {
            show(error)
            return false
        }
    }

    public func confirm(entryID: String, segment: Int) async {
        do {
            _ = try await worker.confirm(entryID: entryID, segment: segment)
            await reload()
        } catch {
            show(error)
        }
    }

    public func acceptSuggestions() async {
        let terms = suggestions
        suggestions = []
        await addGlossaryTerms(terms)
    }

    // MARK: - Notes, titles, deletion

    /// Saves a note; editing a saved note adds a version. `navigate` is false for the save made when the user
    /// leaves the editor, which must not change what they are looking at.
    public func saveNote(entryID: String?, title: String, body: String, navigate: Bool = true) async -> Bool {
        do {
            let id: String
            if let entryID {
                try await worker.updateNote(entryID: entryID, title: title, body: body)
                id = entryID
            } else {
                id = try await worker.addNote(title: title, body: body)
            }
            if navigate {
                route = .entry(id)
            }
            await reload()
            return true
        } catch {
            // Leaving the editor of a note that was just deleted: there is nothing left to save.
            if !navigate, let entryID, !(await worker.exists(entryID: entryID)) {
                return false
            }
            show(error)
            return false
        }
    }

    public func rename(entryID: String, title: String) async {
        do {
            try await worker.rename(entryID: entryID, title: title)
            await reload()
        } catch {
            // A title edit left pending on an entry that was just deleted.
            if await worker.exists(entryID: entryID) {
                show(error)
            }
        }
    }

    public func delete(entryID: String) async {
        guard transcribingEntryID != entryID else {
            notice = Notice(
                title: "This recording is being transcribed",
                message: "Delete it once the transcription has finished."
            )
            return
        }
        do {
            if let audioURL = try? await worker.details(id: entryID).audioURL, player.url == audioURL {
                player.stop()
            }
            try await worker.delete(entryID: entryID)
            queuedEntryIDs.removeAll { $0 == entryID }
            languageOverrides[entryID] = nil
            if route == .entry(entryID) {
                route = .home
                details = nil
            }
            await reload()
        } catch {
            show(error)
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchHits = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            let hits = (try? await self.worker.search(query)) ?? []
            if !Task.isCancelled {
                self.searchHits = hits
            }
        }
    }

    // MARK: - Settings

    public func refreshSettings() async {
        do {
            languageProfile = try await worker.languageProfile()
            glossary = try await worker.glossary()
            mixedLanguages = try await worker.mixedLanguages()
        } catch {
            show(error)
        }
    }

    public func setLanguage(_ code: String, enabled: Bool) async {
        var codes = languageProfile.filter { $0 != code }
        if enabled {
            codes.append(code)
        }
        await setLanguages(codes)
    }

    public func setLanguages(_ codes: [String]) async {
        do {
            languageProfile = try await worker.setLanguageProfile(codes)
        } catch {
            show(error)
        }
    }

    public func setMixedLanguages(_ enabled: Bool) async {
        do {
            try await worker.setMixedLanguages(enabled)
            mixedLanguages = try await worker.mixedLanguages()
        } catch {
            show(error)
        }
    }

    public func addGlossaryTerms(_ terms: [String]) async {
        guard !terms.isEmpty else { return }
        do {
            try await worker.addGlossaryTerms(terms)
            glossary = try await worker.glossary()
        } catch {
            show(error)
        }
    }

    public func removeGlossaryTerm(_ term: String) async {
        do {
            try await worker.removeGlossaryTerm(term)
            glossary = try await worker.glossary()
        } catch {
            show(error)
        }
    }

    public func refreshModelStatus() async {
        modelReady = await worker.isModelReady()
    }

    public func selectModel(named name: String) async {
        let profile = ModelProfile.resolve(name)
        UserDefaults.standard.set(profile.name, forKey: AppModel.profileKey)
        modelProfile = profile
        await worker.setProfile(profile)
        modelLoaded = false
        await refreshModelStatus()
        await queueUntranscribed()
        prepareModel()
    }

    /// Started only by the user's click in Settings: the one place where Mneme uses the network.
    public func downloadModel() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        do {
            try await worker.downloadModel { fraction in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = fraction
                }
            }
            await refreshModelStatus()
            modelLoaded = await worker.isModelLoaded()
            await queueUntranscribed()
        } catch {
            notice = Notice(title: "The model could not be downloaded", message: error.localizedDescription)
        }
        isDownloading = false
        downloadProgress = nil
    }

    public func verifyArchive() async {
        do {
            let report = try await worker.verify()
            var lines = [
                "Database: \(report.databaseCheck)",
                "Search index: \(report.searchIndexCheck)",
                "Recordings checked: \(report.checkedBlobs)",
            ]
            if !report.missingBlobs.isEmpty {
                lines.append("Missing: \(report.missingBlobs.count)")
            }
            if !report.corruptedBlobs.isEmpty {
                lines.append("Damaged: \(report.corruptedBlobs.count)")
            }
            notice = Notice(
                title: report.isHealthy ? "The archive is intact" : "Problems were found",
                message: lines.joined(separator: "\n")
            )
        } catch {
            show(error)
        }
    }

    // MARK: - Errors

    public func show(_ error: Error) {
        notice = Notice(title: "Something went wrong", message: error.localizedDescription)
    }
}
