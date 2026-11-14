import MnemeAppSupport
import MnemeCore
import SwiftUI

struct EntryDetailView: View {
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
            await model.loadDetails(entryID)
        }
    }
}

struct VoiceEntryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: PlayerModel
    let details: EntryDetails

    @State private var title: String
    @FocusState private var titleFocused: Bool
    @State private var editingSegment: Int?
    @State private var draft = ""

    init(details: EntryDetails) {
        self.details = details
        _title = State(initialValue: details.entry.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
            if let audioURL = details.audioURL {
                PlayerBar(url: audioURL, duration: details.asset?.durationSeconds ?? 0)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            Divider()
            transcriptArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(Formatters.title(for: details.entry, preview: details.transcript?.transcript.text ?? ""))
        .onDisappear(perform: commitTitle)
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    model.pendingDeletion = details.entry.id
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this entry")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Untitled recording", text: $title)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { _, focused in
                    if !focused {
                        commitTitle()
                    }
                }
            Text(metadata)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Saves the title when the user presses Return, leaves the field or leaves the entry.
    private func commitTitle() {
        let edited = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard edited != (details.entry.title ?? "") else { return }
        let entryID = details.entry.id
        Task {
            await model.rename(entryID: entryID, title: edited)
        }
    }

    private var metadata: String {
        var parts = [Formatters.date(details.entry.recordedAt)]
        if let duration = details.asset?.durationSeconds {
            parts.append(Formatters.duration(duration))
        }
        if let transcript = details.transcript {
            let decision = transcript.transcript.language
            if decision.source == .mixed {
                let names = transcript.transcript.speechByLanguage.map { Formatters.languageName($0.code) }
                parts.append(ListFormatter.localizedString(byJoining: names) + " (switches detected per sentence)")
            } else {
                parts.append("\(Formatters.languageName(decision.code)) (\(languageSource(decision.source)))")
            }
            if details.versions.count > 1 {
                parts.append("version \(transcript.version) of \(details.versions.count)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func languageSource(_ source: LanguageDecision.Source) -> String {
        switch source {
        case .forced: return "chosen"
        case .profile: return "your language"
        case .detected: return "detected"
        case .constrained: return "detected among your languages"
        case .model: return "detected by the model"
        case .fallback: return "default"
        case .mixed: return "several languages"
        }
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if let record = details.transcript {
            if record.transcript.segments.isEmpty {
                ContentUnavailableView("No speech detected", systemImage: "waveform.slash")
            } else {
                transcriptList(record.transcript)
            }
        } else if model.transcribingEntryID == details.entry.id {
            TranscribingView()
        } else if model.queuedEntryIDs.contains(details.entry.id) {
            ProgressView("Waiting to be transcribed…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.modelReady {
            ContentUnavailableView {
                Label("Not transcribed yet", systemImage: "text.badge.xmark")
            } description: {
                Text("The recording is safely archived. Install a speech model to transcribe it on this Mac.")
            } actions: {
                SettingsLink {
                    Text("Open Settings")
                }
            }
        } else {
            ContentUnavailableView {
                Label("Not transcribed yet", systemImage: "text.badge.xmark")
            } actions: {
                Button("Transcribe") {
                    model.queueTranscription(details.entry.id)
                }
            }
        }
    }

    private func transcriptList(_ transcript: Transcript) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(transcript.segments, id: \.index) { segment in
                    SegmentRow(
                        segment: segment,
                        languageTag: transcript.language.source == .mixed ? (segment.language ?? transcript.language.code) : nil,
                        isActive: player.isWithin(details.audioURL, start: segment.start, end: segment.end),
                        isEditing: editingSegment == segment.index,
                        draft: $draft,
                        onPlay: { play(segment) },
                        onEdit: { beginEditing(segment) },
                        onSave: { save(segment) },
                        onCancel: { editingSegment = nil },
                        onConfirm: { confirm(segment) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func play(_ segment: TranscribedSegment) {
        guard let url = details.audioURL else { return }
        player.play(url: url, from: segment.start, until: segment.end)
    }

    private func beginEditing(_ segment: TranscribedSegment) {
        draft = segment.text
        editingSegment = segment.index
    }

    private func save(_ segment: TranscribedSegment) {
        let text = draft
        let entryID = details.entry.id
        Task {
            if await model.correct(entryID: entryID, segment: segment.index, text: text) {
                editingSegment = nil
            }
        }
    }

    private func confirm(_ segment: TranscribedSegment) {
        let entryID = details.entry.id
        Task {
            await model.confirm(entryID: entryID, segment: segment.index)
        }
    }
}

struct PlayerBar: View {
    @EnvironmentObject private var player: PlayerModel
    let url: URL
    let duration: Double

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayback(url: url)
            } label: {
                Image(systemName: player.plays(url) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [.option])
            .help("Play or pause (⌥Space)")
            Slider(value: position, in: 0...max(duration, 0.1))
            Text("\(Formatters.position(isCurrent ? player.currentTime : 0)) / \(Formatters.duration(duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var isCurrent: Bool {
        player.url == url
    }

    private var position: Binding<Double> {
        Binding(get: { isCurrent ? player.currentTime : 0 }, set: { time in
            if isCurrent {
                player.seek(to: time)
            } else {
                player.play(url: url, from: time)
            }
        })
    }
}

/// Progress of the transcription, with the text decoded so far.
struct TranscribingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let fraction = model.transcriptionProgress, model.modelLoaded {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 260)
                    Text("Transcribing on this Mac… \(Int((fraction * 100).rounded())) %")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading the speech model, then transcribing…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !model.modelLoaded {
                Text("The first load after installing a model can take a few minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.partialTranscript.isEmpty {
                ScrollView {
                    Text(model.partialTranscript)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

struct SegmentRow: View {
    let segment: TranscribedSegment
    /// The segment's language, shown when the recording mixes languages.
    var languageTag: String? = nil
    let isActive: Bool
    let isEditing: Bool
    @Binding var draft: String
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onPlay) {
                Text(Formatters.position(segment.start))
                    .font(.callout.monospacedDigit())
            }
            .buttonStyle(.link)
            .help("Play this passage")
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Corrected text", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save", action: onSave)
                            .keyboardShortcut(.defaultAction)
                        Button("Cancel", action: onCancel)
                            .keyboardShortcut(.cancelAction)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let languageTag {
                            Text(languageTag.uppercased())
                                .font(.caption2.weight(.semibold).monospaced())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                                .help(Formatters.languageName(languageTag))
                        }
                        Text(segment.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !segment.flags.isEmpty {
                        FlagBadges(flags: segment.flags)
                    }
                }
            }
            if !isEditing {
                if segment.needsReview {
                    Button(action: onConfirm) {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("The text is right: mark it as verified")
                }
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Correct this passage")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.14) : (segment.needsReview ? Color.orange.opacity(0.06) : Color.clear))
        )
    }
}

struct FlagBadges: View {
    let flags: Set<QualityFlag>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(flags.sorted(), id: \.self) { flag in
                Text(Formatters.flagLabel(flag))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color(for: flag).opacity(0.18)))
                    .foregroundStyle(color(for: flag))
            }
        }
    }

    private func color(for flag: QualityFlag) -> Color {
        flag == .userVerified ? .green : .orange
    }
}
