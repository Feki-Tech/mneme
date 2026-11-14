import MnemeAppSupport
import MnemeCore
import SwiftUI
import UIKit

/// One entry: a voice recording with its player and transcript, or a note in its editor.
struct EntryView: View {
    @EnvironmentObject private var model: AppModel
    let entryID: String

    var body: some View {
        Group {
            if let details = model.details, details.entry.id == entryID {
                if details.entry.kind == .text {
                    NoteEditorView(
                        entryID: entryID,
                        initialTitle: details.entry.title ?? "",
                        initialBody: details.note?.body ?? "",
                        version: details.note?.version
                    )
                    .id(entryID)
                } else {
                    VoiceEntryView(details: details)
                        .id(entryID)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: entryID) {
            if model.route != .entry(entryID) {
                model.route = .entry(entryID)
            }
            await model.loadDetails(entryID)
        }
    }
}

struct VoiceEntryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: PlayerModel
    let details: EntryDetails

    @State private var title: String
    @State private var editing: EditableSegment?
    @State private var shareItems: ShareItems?

    init(details: EntryDetails) {
        self.details = details
        _title = State(initialValue: details.entry.title ?? "")
    }

    var body: some View {
        List {
            Section {
                TextField("Title", text: $title, axis: .vertical)
                    .font(.title2.weight(.semibold))
                    .submitLabel(.done)
                    .onSubmit(commitTitle)
                metadata
            }
            .listRowSeparator(.hidden)
            if let audioURL = details.audioURL {
                Section {
                    PlayerControls(url: audioURL, duration: details.asset?.durationSeconds ?? 0)
                }
            }
            transcriptSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Formatters.title(for: details.entry, preview: details.transcript?.transcript.text ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: commitTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task {
                            let files = await model.exportFiles(entryID: details.entry.id)
                            if !files.isEmpty { shareItems = ShareItems(urls: files) }
                        }
                    } label: {
                        Label("Share Recording and Transcript…", systemImage: "square.and.arrow.up")
                    }
                    if details.transcript != nil || details.entry.kind == .voice {
                        Button {
                            model.queueTranscription(details.entry.id)
                        } label: {
                            Label(details.transcript == nil ? "Transcribe" : "Transcribe Again", systemImage: "text.badge.plus")
                        }
                        .disabled(!model.modelReady || model.transcribingEntryID == details.entry.id)
                    }
                    Divider()
                    Button(role: .destructive) {
                        model.pendingDeletion = details.entry.id
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editing) { segment in
            SegmentEditor(segment: segment, audioURL: details.audioURL) { text in
                Task { _ = await model.correct(entryID: details.entry.id, segment: segment.index, text: text) }
            }
        }
        .sheet(item: $shareItems) { items in
            ActivityView(items: items.urls)
                .presentationDetents([.medium, .large])
        }
        .safeAreaInset(edge: .bottom) {
            if !model.suggestions.isEmpty {
                GlossarySuggestionBar()
            }
        }
        .confirmationDialog(
            "Delete this entry permanently?",
            isPresented: Binding(get: { model.pendingDeletion == details.entry.id }, set: { if !$0 { model.pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.pendingDeletion = nil
                Task { await model.delete(entryID: details.entry.id) }
            }
        } message: {
            Text("The recording and every transcript version are removed from this iPhone. This cannot be undone.")
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(Formatters.date(details.entry.recordedAt))
            if let duration = details.asset?.durationSeconds {
                Text("·")
                Text(Formatters.duration(duration))
            }
            if let transcript = details.transcript {
                Text("·")
                Text(transcript.transcript.language.source == .mixed ? "Several languages" : Formatters.languageName(transcript.transcript.language.code))
                if details.versions.count > 1 {
                    Text("·")
                    Text("v\(transcript.version)")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let record = details.transcript {
            let transcript = record.transcript
            let mixed = transcript.language.source == .mixed
            Section {
                ForEach(transcript.segments, id: \.index) { segment in
                    SegmentRow(segment: segment, showLanguage: mixed, audioURL: details.audioURL)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let audioURL = details.audioURL {
                                player.play(url: audioURL, from: segment.start, until: segment.end)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                editing = EditableSegment(index: segment.index, text: segment.text, start: segment.start, end: segment.end)
                            } label: {
                                Label("Correct", systemImage: "pencil")
                            }
                            .tint(Theme.accent)
                        }
                        .swipeActions(edge: .leading) {
                            if segment.needsReview {
                                Button {
                                    Task { await model.confirm(entryID: details.entry.id, segment: segment.index) }
                                } label: {
                                    Label("Correct as is", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                        }
                        .contextMenu {
                            Button {
                                editing = EditableSegment(index: segment.index, text: segment.text, start: segment.start, end: segment.end)
                            } label: {
                                Label("Correct…", systemImage: "pencil")
                            }
                            if segment.needsReview {
                                Button {
                                    Task { await model.confirm(entryID: details.entry.id, segment: segment.index) }
                                } label: {
                                    Label("Mark as Correct", systemImage: "checkmark")
                                }
                            }
                            Button {
                                UIPasteboard.general.string = segment.text
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                }
            } header: {
                Text("Transcript")
            } footer: {
                Text("Tap a passage to hear it. Swipe left to correct it; passages marked in orange were hard to hear.")
            }
        } else {
            Section("Transcript") {
                if model.transcribingEntryID == details.entry.id {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: model.transcriptionProgress.map { min($0, 1) }) {
                            Text(model.modelLoaded ? "Transcribing on this iPhone…" : "Loading the speech model…")
                        }
                        if !model.partialTranscript.isEmpty {
                            Text(model.partialTranscript)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if model.queuedEntryIDs.contains(details.entry.id) {
                    Label("Waiting for the recording before it", systemImage: "clock")
                        .foregroundStyle(.secondary)
                } else if !model.modelReady {
                    Text("Install a speech model in Settings; this recording is transcribed right after.")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Transcribe Now") {
                        model.queueTranscription(details.entry.id)
                    }
                }
            }
        }
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (details.entry.title ?? "") else { return }
        Task { await model.rename(entryID: details.entry.id, title: trimmed) }
    }
}

struct EditableSegment: Identifiable {
    let index: Int
    let text: String
    let start: Double
    let end: Double

    var id: Int { index }
}

struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct SegmentRow: View {
    @EnvironmentObject private var player: PlayerModel
    let segment: TranscribedSegment
    let showLanguage: Bool
    let audioURL: URL?

    var body: some View {
        let playing = player.isPlaying && player.isWithin(audioURL, start: segment.start, end: segment.end)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Formatters.duration(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(playing ? Theme.accent : .secondary)
                if showLanguage, let language = segment.language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.text)
                    .foregroundStyle(playing ? Theme.accent : .primary)
                if segment.needsReview {
                    Text(segment.flags.filter { $0 != .userVerified }.sorted().map(Formatters.flagLabel).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if segment.flags.contains(.userVerified) {
                    Label("Verified", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(segment.needsReview ? Color.orange.opacity(0.08) : nil)
    }
}

struct PlayerControls: View {
    @EnvironmentObject private var player: PlayerModel
    let url: URL
    let duration: Double

    var body: some View {
        let active = player.plays(url)
        let total = active && player.duration > 0 ? player.duration : duration
        let position = active ? player.currentTime : 0
        HStack(spacing: 14) {
            Button {
                player.togglePlayback(url: url)
            } label: {
                Image(systemName: active && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel(active && player.isPlaying ? "Pause" : "Play")
            VStack(spacing: 2) {
                Slider(
                    value: Binding(get: { min(position, max(total, 0.01)) }, set: { player.seek(to: $0) }),
                    in: 0...max(total, 0.01)
                )
                .disabled(!active)
                HStack {
                    Text(Formatters.duration(position))
                    Spacer()
                    Text(Formatters.duration(total))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Correcting a passage adds a new transcript version; the earlier one is kept.
struct SegmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerModel
    let segment: EditableSegment
    let audioURL: URL?
    let save: (String) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(segment: EditableSegment, audioURL: URL?, save: @escaping (String) -> Void) {
        self.segment = segment
        self.audioURL = audioURL
        self.save = save
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                        .focused($focused)
                } footer: {
                    Text("Your correction becomes a new version of the transcript; the original stays available. Names you correct can be added to the glossary.")
                }
                if let audioURL {
                    Section {
                        Button {
                            player.play(url: audioURL, from: segment.start, until: segment.end)
                        } label: {
                            Label("Play \(Formatters.duration(segment.start))–\(Formatters.duration(segment.end))", systemImage: "play.fill")
                        }
                    }
                }
            }
            .navigationTitle("Correct Passage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty, trimmed != segment.text {
                            save(trimmed)
                        }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

struct GlossarySuggestionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add to the glossary so they are spelled this way next time?")
                .font(.subheadline)
            Text(model.suggestions.joined(separator: ", "))
                .font(.subheadline.weight(.semibold))
            HStack {
                Button("Not Now") { model.suggestions = [] }
                    .buttonStyle(.bordered)
                Button("Add") { Task { await model.acceptSuggestions() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

/// The system share sheet (AirDrop, Files, Mail…).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
