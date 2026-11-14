import MnemeAppSupport
import MnemeCore
import SwiftUI

/// Passages the recogniser was unsure about, across the whole archive. Each one is confirmed or corrected.
struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: PlayerModel
    @State private var editing: FlaggedSegment?

    var body: some View {
        List {
            if model.flagged.isEmpty {
                ContentUnavailableView(
                    "Nothing to review",
                    systemImage: "checkmark.seal",
                    description: Text("Passages that were hard to hear appear here, so you can check them against the recording.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.flagged) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.title?.isEmpty == false ? item.title! : Formatters.date(item.recordedAt))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(Formatters.duration(item.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.text)
                            Text(item.flags.filter { $0 != .userVerified }.sorted().map(Formatters.flagLabel).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.orange)
                            HStack(spacing: 10) {
                                Button {
                                    player.play(url: item.audioURL, from: item.start, until: item.end)
                                } label: {
                                    Label("Listen", systemImage: "play.fill")
                                }
                                Button {
                                    editing = item
                                } label: {
                                    Label("Correct", systemImage: "pencil")
                                }
                                Button {
                                    Task { await model.confirm(entryID: item.entryID, segment: item.segmentIndex) }
                                } label: {
                                    Label("It's Right", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .labelStyle(.titleAndIcon)
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button {
                                model.route = .entry(item.entryID)
                            } label: {
                                Label("Open Recording", systemImage: "waveform")
                            }
                        }
                    }
                } footer: {
                    Text("Corrections become new transcript versions and are used to measure the model on your own voice.")
                }
            }
        }
        .navigationTitle("To Review")
        .sheet(item: $editing) { item in
            SegmentEditor(
                segment: EditableSegment(index: item.segmentIndex, text: item.text, start: item.start, end: item.end),
                audioURL: item.audioURL
            ) { text in
                Task { _ = await model.correct(entryID: item.entryID, segment: item.segmentIndex, text: text) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.suggestions.isEmpty {
                GlossarySuggestionBar()
            }
        }
    }
}
