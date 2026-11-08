import Foundation
import MnemeCore
import MnemeSpeech
import SwiftUI

/// The app's state. Archive work runs in `ArchiveWorker`; transcriptions run one at a time.
@MainActor
final class AppModel: ObservableObject {
    enum Route: Hashable {
        case home
        case entry(String)
        case recorder
        case newNote
        case review
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case voice = "Voice"
        case notes = "Notes"
        case attention = "To review"

        var id: String { rawValue }
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var route: Route = .home
    @Published var filter: Filter = .all
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published var notice: Notice?
    /// Entry waiting for the user to confirm its deletion.
    @Published var pendingDeletion: String?
    /// Glossary suggestions from the last correction.
    @Published var suggestions: [String] = []

    @Published private(set) var entries: [EntrySummary] = []
    @Published private(set) var searchHits: [SearchHit] = []
    @Published private(set) var details: EntryDetails?
    @Published private(set) var flagged: [FlaggedSegment] = []
    @Published private(set) var transcribingEntryID: String?
    @Published private(set) var queuedEntryIDs: [String] = []
    @Published private(set) var modelReady = false
    /// The model is loaded in this session; until then the first transcription also loads it.
    @Published private(set) var modelLoaded = false
    @Published private(set) var modelProfile: ModelProfile
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var languageProfile: [String] = []
    @Published private(set) var glossary: [String] = []

    let recorder = RecorderModel()
    let player = PlayerModel()
    let archiveRoot: URL
    let modelsDirectory: URL

    private let worker: ArchiveWorker
    private var searchTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var languageOverrides: [String: String] = [:]
    private var started = false

    private static let profileKey = "modelProfile"

    init(archiveRoot: URL = ArchiveStore.defaultRoot, modelsDirectory: URL = ModelLocator.defaultModelsDirectory) {
        let profile = ModelProfile.resolve(UserDefaults.standard.string(forKey: AppModel.profileKey) ?? ModelProfile.defaultProfile.name)
        self.archiveRoot = archiveRoot
        self.modelsDirectory = modelsDirectory
        self.modelProfile = profile
        self.worker = ArchiveWorker(archiveRoot: archiveRoot, modelsDirectory: modelsDirectory, profile: profile)
    }

    /// Recordings in progress, and any that could not be archived, live here (private to the user).
    var recordingsFolder: URL {
        archiveRoot.deletingLastPathComponent().appendingPathComponent("Recordings", isDirectory: true)
    }

    var visibleEntries: [EntrySummary] {
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
    var visibleSearchHits: [SearchHit] {
        var seen = Set<String>()
        return searchHits.filter { seen.insert($0.entryID).inserted }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await refreshSettings()
        await reload()
        await recoverRecordings()
        await refreshModelStatus()
        await queueUntranscribed()
    }

    func reload() async {
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

    func loadDetails(_ id: String) async {
        do {
            details = try await worker.details(id: id)
        } catch {
            details = nil
            show(error)
        }
    }

    // MARK: - Recording

    func startRecording() async {
        if recorder.permission != .granted {
            await recorder.requestPermission()
        }
        guard recorder.permission == .granted else {
            notice = Notice(
                title: "Microphone access is off",
                message: "Allow Mneme in System Settings > Privacy & Security > Microphone, then try again."
            )
            return
        }
        do {
            try recorder.start(in: recordingsFolder)
        } catch {
            show(error)
        }
    }

    /// Stops, archives the original at once, then queues the transcription.
    func finishRecording(title: String, language: String?) async {
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

    // MARK: - Transcription queue

    func queueTranscription(_ entryID: String, language: String? = nil) {
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
            modelLoaded = await worker.isModelLoaded()
            do {
                try await worker.transcribe(entryID: entryID, language: languageOverrides[entryID])
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

    func correct(entryID: String, segment: Int, text: String) async -> Bool {
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

    func confirm(entryID: String, segment: Int) async {
        do {
            _ = try await worker.confirm(entryID: entryID, segment: segment)
            await reload()
        } catch {
            show(error)
        }
    }

    func acceptSuggestions() async {
        let terms = suggestions
        suggestions = []
        await addGlossaryTerms(terms)
    }

    // MARK: - Notes, titles, deletion

    /// Saves a note; editing a saved note adds a version. `navigate` is false for the save made when the user
    /// leaves the editor, which must not change what they are looking at.
    func saveNote(entryID: String?, title: String, body: String, navigate: Bool = true) async -> Bool {
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

    func rename(entryID: String, title: String) async {
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

    func delete(entryID: String) async {
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

    func refreshSettings() async {
        do {
            languageProfile = try await worker.languageProfile()
            glossary = try await worker.glossary()
        } catch {
            show(error)
        }
    }

    func setLanguage(_ code: String, enabled: Bool) async {
        var codes = languageProfile.filter { $0 != code }
        if enabled {
            codes.append(code)
        }
        await setLanguages(codes)
    }

    func setLanguages(_ codes: [String]) async {
        do {
            languageProfile = try await worker.setLanguageProfile(codes)
        } catch {
            show(error)
        }
    }

    func addGlossaryTerms(_ terms: [String]) async {
        guard !terms.isEmpty else { return }
        do {
            try await worker.addGlossaryTerms(terms)
            glossary = try await worker.glossary()
        } catch {
            show(error)
        }
    }

    func removeGlossaryTerm(_ term: String) async {
        do {
            try await worker.removeGlossaryTerm(term)
            glossary = try await worker.glossary()
        } catch {
            show(error)
        }
    }

    func refreshModelStatus() async {
        modelReady = await worker.isModelReady()
    }

    func selectModel(named name: String) async {
        let profile = ModelProfile.resolve(name)
        UserDefaults.standard.set(profile.name, forKey: AppModel.profileKey)
        modelProfile = profile
        await worker.setProfile(profile)
        await refreshModelStatus()
        await queueUntranscribed()
    }

    /// Started only by the user's click in Settings: the one place where Mneme uses the network.
    func downloadModel() async {
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
            await queueUntranscribed()
        } catch {
            notice = Notice(title: "The model could not be downloaded", message: error.localizedDescription)
        }
        isDownloading = false
        downloadProgress = nil
    }

    func verifyArchive() async {
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

    func show(_ error: Error) {
        notice = Notice(title: "Something went wrong", message: error.localizedDescription)
    }
}
