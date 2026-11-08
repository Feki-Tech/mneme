import MnemeCore
import SwiftUI

/// Every passage the recogniser was unsure about, across the archive: listen, correct or confirm.
struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: PlayerModel
    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        Group {
            if model.flagged.isEmpty {
                ContentUnavailableView(
                    "Nothing to review",
                    systemImage: "checkmark.seal",
                    description: Text("Passages the recogniser is unsure about appear here, so you can listen, correct or confirm them.")
                )
            } else {
                List {
                    ForEach(model.flagged) { item in
                        ReviewRow(
                            item: item,
                            isActive: player.isWithin(item.audioURL, start: item.start, end: item.end),
                            isEditing: editing == item.id,
                            draft: $draft,
                            onPlay: { player.play(url: item.audioURL, from: item.start, until: item.end) },
                            onEdit: {
                                draft = item.text
                                editing = item.id
                            },
                            onSave: { save(item) },
                            onCancel: { editing = nil },
                            onConfirm: { confirm(item) },
                            onOpen: { model.route = .entry(item.entryID) }
                        )
                    }
                }
            }
        }
        .navigationTitle("Review")
        .navigationSubtitle(model.flagged.isEmpty ? "" : "\(model.flagged.count) passage(s)")
    }

    private func save(_ item: FlaggedSegment) {
        let text = draft
        Task {
            if await model.correct(entryID: item.entryID, segment: item.segmentIndex, text: text) {
                editing = nil
            }
        }
    }

    private func confirm(_ item: FlaggedSegment) {
        Task {
            await model.confirm(entryID: item.entryID, segment: item.segmentIndex)
        }
    }
}

struct ReviewRow: View {
    let item: FlaggedSegment
    let isActive: Bool
    let isEditing: Bool
    @Binding var draft: String
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: onOpen) {
                    Text(item.title ?? Formatters.date(item.recordedAt))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.link)
                .help("Open the entry")
                Text("\(Formatters.position(item.start))–\(Formatters.position(item.end))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                FlagBadges(flags: item.flags)
            }
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
                Text(item.text)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Button(action: onPlay) {
                        Label("Listen", systemImage: "play.circle")
                    }
                    Button(action: onEdit) {
                        Label("Correct", systemImage: "pencil")
                    }
                    Button(action: onConfirm) {
                        Label("It's right", systemImage: "checkmark.circle")
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
        )
    }
}
