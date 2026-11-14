import MnemeAppSupport
import MnemeCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $model.filter) {
                ForEach(AppModel.Filter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            List(selection: selection) {
                if isSearching {
                    searchResults
                } else {
                    reviewSection
                    entriesSection
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search transcripts and notes")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.route = .recorder
                } label: {
                    Label("New Recording", systemImage: "mic.circle")
                }
                .help("New recording (⌘R)")
                Button {
                    model.route = .newNote
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New note (⌘N)")
            }
        }
    }

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selection: Binding<AppModel.Route?> {
        Binding(get: { model.route == .home ? nil : model.route }, set: { route in
            model.route = route ?? .home
        })
    }

    private var reviewSection: some View {
        Section {
            HStack {
                Label("Review", systemImage: "exclamationmark.bubble")
                Spacer()
                if !model.flagged.isEmpty {
                    Text("\(model.flagged.count)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                }
            }
            .tag(AppModel.Route.review)
        }
    }

    private var entriesSection: some View {
        Section("Entries") {
            ForEach(model.visibleEntries) { summary in
                EntryRow(summary: summary, status: status(of: summary))
                    .tag(AppModel.Route.entry(summary.id))
                    .contextMenu {
                        Button("Delete…", role: .destructive) {
                            model.pendingDeletion = summary.id
                        }
                    }
            }
        }
    }

    private var searchResults: some View {
        Section("Results") {
            if model.visibleSearchHits.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.visibleSearchHits) { hit in
                SearchHitRow(hit: hit)
                    .tag(AppModel.Route.entry(hit.entryID))
            }
        }
    }

    private func status(of summary: EntrySummary) -> EntryRow.Status {
        if model.transcribingEntryID == summary.id {
            return .transcribing
        }
        if model.queuedEntryIDs.contains(summary.id) {
            return .queued
        }
        if summary.needsTranscription {
            return .untranscribed
        }
        return summary.flaggedSegments > 0 ? .flagged(summary.flaggedSegments) : .normal
    }
}

struct EntryRow: View {
    enum Status {
        case normal
        case transcribing
        case queued
        case untranscribed
        case flagged(Int)
    }

    let summary: EntrySummary
    let status: Status

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: summary.entry.kind == .voice ? "waveform" : "text.alignleft")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(Formatters.title(for: summary.entry, preview: summary.preview))
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if summary.entry.title != nil && !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            statusView
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [Formatters.date(summary.entry.recordedAt)]
        if let duration = summary.durationSeconds {
            parts.append(Formatters.duration(duration))
        }
        if let language = summary.entry.language {
            parts.append(language.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .normal:
            EmptyView()
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .help("Transcribing on this Mac")
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .help("Waiting to be transcribed")
        case .untranscribed:
            Image(systemName: "text.badge.xmark")
                .foregroundStyle(.secondary)
                .help("Not transcribed yet")
        case .flagged(let count):
            Text("\(count)")
                .font(.caption)
                .padding(.horizontal, 5)
                .background(Capsule().fill(Color.orange.opacity(0.25)))
                .help("\(count) passage(s) to review")
        }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: hit.kind == .voice ? "waveform" : "text.alignleft")
                    .foregroundStyle(.secondary)
                Text(hit.title ?? Formatters.date(hit.recordedAt))
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(highlighted(hit.snippet))
                .font(.caption)
                .lineLimit(3)
            if let start = hit.start {
                Text("at \(Formatters.position(start))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// The archive marks matches with [brackets]; show them in bold instead.
    private func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var remaining = Substring(snippet)
        while let open = remaining.firstIndex(of: "["), let close = remaining[open...].firstIndex(of: "]") {
            result += AttributedString(String(remaining[..<open]))
            var match = AttributedString(String(remaining[remaining.index(after: open)..<close]))
            match.inlinePresentationIntent = .stronglyEmphasized
            result += match
            remaining = remaining[remaining.index(after: close)...]
        }
        result += AttributedString(String(remaining))
        return result
    }
}
