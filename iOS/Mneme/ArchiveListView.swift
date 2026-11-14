import MnemeAppSupport
import MnemeCore
import SwiftUI

/// The archive: newest first, searchable (case and accents ignored), with a filter and a large record button.
struct ArchiveListView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var sheet: Sheet?
    @Binding var path: [Destination]
    @State private var deletion: String?

    var body: some View {
        List {
            if !model.modelReady {
                ModelMissingRow { sheet = .settings }
            }
            if model.transcribingEntryID != nil || !model.queuedEntryIDs.isEmpty {
                TranscriptionStatusRow()
            }
            if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                entriesSection
            } else {
                searchSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Mneme")
        .searchable(text: $model.searchText, prompt: "Search transcripts and notes")
        .refreshable { await model.reload() }
        .safeAreaInset(edge: .bottom) {
            RecordButtonBar { sheet = .recorder }
        }
        .confirmationDialog(
            "Delete this entry permanently?",
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deletion {
                    deletion = nil
                    Task { await model.delete(entryID: id) }
                }
            }
        } message: {
            Text("The entry, its recording and every version are removed from this iPhone. This cannot be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    sheet = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !model.flagged.isEmpty {
                    Button {
                        path.append(.review)
                    } label: {
                        Label("Review (\(model.flagged.count))", systemImage: "exclamationmark.bubble")
                    }
                }
                Menu {
                    Button {
                        sheet = .newNote
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    Button {
                        model.isImportingFiles = true
                    } label: {
                        Label("Import Recordings…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        Section {
            Picker("Show", selection: $model.filter) {
                ForEach(AppModel.Filter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
        if model.visibleEntries.isEmpty {
            Section {
                ContentUnavailableView {
                    Label(model.entries.isEmpty ? "Nothing archived yet" : "Nothing here", systemImage: model.entries.isEmpty ? "waveform" : "tray")
                } description: {
                    Text(model.entries.isEmpty
                        ? "Tap the record button and say what is on your mind. It is transcribed on this iPhone and never leaves it."
                        : "No entries match this filter.")
                }
                .listRowBackground(Color.clear)
            }
        } else {
            ForEach(groupedEntries) { group in
                Section(group.title) {
                    ForEach(group.entries) { summary in
                        NavigationLink(value: Destination.entry(summary.id)) {
                            EntryRow(summary: summary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deletion = summary.id
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        if model.visibleSearchHits.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
                .listRowBackground(Color.clear)
        } else {
            Section("\(model.visibleSearchHits.count) found") {
                ForEach(model.visibleSearchHits) { hit in
                    NavigationLink(value: Destination.entry(hit.entryID)) {
                        SearchHitRow(hit: hit)
                    }
                }
            }
        }
    }

    /// Today, Yesterday, then one section per month.
    private var groupedEntries: [EntryGroup] {
        let calendar = Calendar.current
        var groups: [EntryGroup] = []
        for summary in model.visibleEntries {
            let date = summary.entry.recordedAt
            let title: String
            if calendar.isDateInToday(date) {
                title = "Today"
            } else if calendar.isDateInYesterday(date) {
                title = "Yesterday"
            } else {
                title = date.formatted(.dateTime.month(.wide).year())
            }
            if groups.last?.title == title {
                groups[groups.count - 1].entries.append(summary)
            } else {
                groups.append(EntryGroup(title: title, entries: [summary]))
            }
        }
        return groups
    }
}

struct EntryGroup: Identifiable {
    let title: String
    var entries: [EntrySummary]

    var id: String { title }
}

struct EntryRow: View {
    @EnvironmentObject private var model: AppModel
    let summary: EntrySummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: summary.entry.kind == .voice ? "waveform" : "note.text")
                .font(.body.weight(.semibold))
                .foregroundStyle(summary.entry.kind == .voice ? Theme.accent : .orange)
                .frame(width: 30, height: 30)
                .background(
                    (summary.entry.kind == .voice ? Theme.accent : Color.orange).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(Formatters.title(for: summary.entry, preview: summary.preview))
                    .font(.headline)
                    .lineLimit(1)
                if !summary.preview.isEmpty, summary.entry.title?.isEmpty == false {
                    Text(summary.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(summary.entry.recordedAt.formatted(date: .omitted, time: .shortened))
                    if summary.entry.kind == .voice, let duration = summary.durationSeconds {
                        Text("·")
                        Text(Formatters.duration(duration))
                    }
                    if let language = summary.entry.language {
                        Text("·")
                        Text(language.uppercased())
                    }
                    status
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        if model.transcribingEntryID == summary.id {
            Text("·")
            Label("Transcribing", systemImage: "ellipsis")
                .foregroundStyle(Theme.accent)
        } else if summary.needsTranscription {
            Text("·")
            Text(model.queuedEntryIDs.contains(summary.id) ? "Queued" : "Not transcribed")
                .foregroundStyle(.orange)
        } else if summary.flaggedSegments > 0 {
            Text("·")
            Label("\(summary.flaggedSegments)", systemImage: "exclamationmark.bubble")
                .foregroundStyle(.orange)
        }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hit.title?.isEmpty == false ? hit.title! : (hit.kind == .voice ? "Voice recording" : "Note"))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let start = hit.start {
                    Text(Formatters.duration(start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(highlighted(hit.snippet))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text(Formatters.date(hit.recordedAt))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Search snippets mark matches with [ and ]; shown in bold.
    private func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        var current = ""
        func flush() {
            var part = AttributedString(current)
            if bold {
                part.font = .subheadline.bold()
                part.foregroundColor = .primary
            }
            result += part
            current = ""
        }
        for character in snippet {
            if character == "[" || character == "]" {
                flush()
                bold = character == "["
            } else {
                current.append(character)
            }
        }
        flush()
        return result
    }
}

struct ModelMissingRow: View {
    @EnvironmentObject private var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Install the speech model", systemImage: "arrow.down.circle")
                    .font(.headline)
                Text("Recordings are kept and transcribed as soon as a model is installed. The model is downloaded once (\(model.modelProfile.approximateDownloadSize)); after that, Mneme works offline.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Choose a Model", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }
}

struct TranscriptionStatusRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView()
                    Text(model.modelLoaded ? "Transcribing on this iPhone…" : "Loading the speech model…")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if !model.queuedEntryIDs.isEmpty {
                        Text("\(model.queuedEntryIDs.count) waiting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let progress = model.transcriptionProgress, progress > 0 {
                    ProgressView(value: min(progress, 1))
                }
                if !model.partialTranscript.isEmpty {
                    Text(model.partialTranscript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

struct RecordButtonBar: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(Theme.record)
                        .frame(width: 72, height: 72)
                        .shadow(color: Theme.record.opacity(0.35), radius: 10, y: 4)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel("Record")
            Spacer()
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }
}
