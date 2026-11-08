import MnemeCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecorderModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if recorder.isRecording && model.route != .recorder {
                    RecordingBanner()
                }
                if !model.modelReady {
                    ModelBanner()
                } else if model.isPreparingModel && model.transcribingEntryID == nil {
                    PreparingBanner()
                }
                if !model.suggestions.isEmpty {
                    SuggestionBanner()
                }
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(model.notice?.title ?? "", isPresented: noticeShown, presenting: model.notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .confirmationDialog("Delete this entry?", isPresented: deletionShown, presenting: model.pendingDeletion) { entryID in
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete(entryID: entryID)
                }
            }
        } message: { _ in
            Text("Its recording, transcripts, notes and history are removed from this Mac. This cannot be undone.")
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { shown in
            if !shown {
                model.notice = nil
            }
        })
    }

    private var deletionShown: Binding<Bool> {
        Binding(get: { model.pendingDeletion != nil }, set: { shown in
            if !shown {
                model.pendingDeletion = nil
            }
        })
    }
}

struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.route {
        case .home:
            WelcomeView()
        case .entry(let id):
            EntryDetailView(entryID: id)
        case .recorder:
            RecorderView()
        case .newNote:
            NoteEditorView(entryID: nil)
        case .review:
            ReviewView()
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Your private archive", systemImage: "waveform.and.mic")
        } description: {
            Text("Record a thought or write a note. Recordings, transcripts and notes stay on this Mac.")
        } actions: {
            VStack(spacing: 14) {
                HStack {
                    Button("New Recording") {
                        model.route = .recorder
                    }
                    Button("New Note") {
                        model.route = .newNote
                    }
                }
                .fixedSize()
                if model.languageProfile.isEmpty {
                    VStack(spacing: 6) {
                        Text("Tell Mneme which languages you speak, so an accent is never mistaken for another language.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        SettingsLink {
                            Text("Choose Languages…")
                        }
                    }
                    .frame(maxWidth: 380)
                }
            }
        }
    }
}

/// Shown while a recording continues in the background of another screen.
struct RecordingBanner: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecorderModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            Text("Recording · \(Formatters.position(recorder.elapsed))")
                .font(.callout.monospacedDigit())
            Spacer()
            Button("Show Recorder") {
                model.route = .recorder
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
    }
}

/// The model is loading ahead of the next transcription.
struct PreparingBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Preparing the speech model so recordings are transcribed right away. The first time after an installation this takes a few minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }
}

struct ModelBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .foregroundStyle(.orange)
            Text("No speech model is installed yet. Recordings are saved now and transcribed once you install a model.")
                .font(.callout)
            Spacer()
            SettingsLink {
                Text("Install…")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

struct SuggestionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .foregroundStyle(.blue)
            Text("Add to your glossary so future recordings spell them right: \(model.suggestions.joined(separator: ", "))")
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Add") {
                Task {
                    await model.acceptSuggestions()
                }
            }
            Button("Not now") {
                model.suggestions = []
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.10))
    }
}
