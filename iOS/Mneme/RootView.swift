import MnemeAppSupport
import MnemeCore
import SwiftUI
import UniformTypeIdentifiers

enum Destination: Hashable {
    case entry(String)
    case review
}

enum Sheet: String, Identifiable {
    case recorder
    case newNote
    case settings

    var id: String { rawValue }
}

/// Navigation for the phone: the archive list at the root, entries and the review queue pushed on top, and the
/// recorder, a new note and settings as sheets. Follows `AppModel.route`, which the shared model sets after a
/// recording, an import or a saved note.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("onboardingDone") private var onboardingDone = false
    let launch: LaunchOptions

    @State private var path: [Destination] = []
    @State private var sheet: Sheet?
    @State private var showOnboarding = false
    @State private var appliedLaunchScreen = false

    var body: some View {
        NavigationStack(path: $path) {
            ArchiveListView(sheet: $sheet, path: $path)
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .entry(let id):
                        EntryView(entryID: id)
                    case .review:
                        ReviewView()
                    }
                }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .recorder:
                RecorderView()
            case .newNote:
                NavigationStack {
                    NoteEditorView(entryID: nil, initialTitle: "", initialBody: "")
                }
            case .settings:
                SettingsView()
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                onboardingDone = true
                showOnboarding = false
            }
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .fileImporter(isPresented: $model.isImportingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                Task { await model.importAudioFiles(urls) }
            }
        }
        .onOpenURL { url in
            // Audio shared to Mneme from Files, Voice Memos or another app.
            Task { await model.importAudioFiles([url]) }
        }
        .onChange(of: model.route) { _, route in
            follow(route)
        }
        .onChange(of: path) { _, newPath in
            if case .entry(let id) = model.route, !newPath.contains(.entry(id)) {
                model.route = .home
            }
        }
        .task {
            await model.start()
            if !onboardingDone && !launch.demo {
                showOnboarding = true
            }
            applyLaunchScreen()
        }
    }

    private func follow(_ route: AppModel.Route) {
        switch route {
        case .entry(let id):
            sheet = nil
            if path.last != .entry(id) {
                if path.last == .review {
                    path.append(.entry(id))
                } else {
                    path = [.entry(id)]
                }
            }
        case .home:
            if case .entry = path.last {
                path.removeLast()
            }
        case .review:
            path = [.review]
        case .recorder:
            sheet = .recorder
        case .newNote:
            sheet = .newNote
        }
    }

    /// Opens the screen named by `-screen` once the archive has loaded (screenshots and UI review).
    private func applyLaunchScreen() {
        guard !appliedLaunchScreen, let screen = launch.screen else { return }
        appliedLaunchScreen = true
        switch screen {
        case "entry":
            if let first = model.entries.first(where: { $0.entry.kind == .voice && !$0.needsTranscription }) {
                path = [.entry(first.id)]
            }
        case "note":
            if let first = model.entries.first(where: { $0.entry.kind == .text }) {
                path = [.entry(first.id)]
            }
        case "review":
            path = [.review]
        case "recorder":
            sheet = .recorder
        case "settings":
            sheet = .settings
        case "onboarding":
            showOnboarding = true
        case "search":
            model.searchText = "Lisbon"
        default:
            break
        }
    }
}
