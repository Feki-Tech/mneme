import MnemeAppSupport
import MnemeCore
import SwiftUI

/// Records with the screen locked or another app in front (background audio). The recording is archived the
/// moment it stops, then transcribed on the device.
struct RecorderView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecorderModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var language = ""
    @State private var levels: [Double] = Array(repeating: 0, count: 48)
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TextField("Title (optional)", text: $title)
                    .font(.title3)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                if !model.languageProfile.isEmpty {
                    Picker("Language", selection: $language) {
                        Text(model.languageProfile.count > 1 ? "Identify automatically" : Formatters.languageName(model.languageProfile[0])).tag("")
                        if model.languageProfile.count > 1 {
                            ForEach(model.languageProfile, id: \.self) { code in
                                Text(Formatters.languageName(code)).tag(code)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                LevelMeter(levels: levels, active: recorder.isRecording)
                    .frame(height: 90)
                Text(Formatters.duration(recorder.elapsed))
                    .font(.system(size: 54, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(recorder.isRecording ? .primary : .secondary)
                Text(recorder.isRecording
                    ? "Recording. It continues with the screen locked."
                    : "Tap to start. Everything stays on this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
                recordButton
            }
            .padding(24)
            .navigationTitle(recorder.isRecording ? "Recording" : "New Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(recorder.isRecording ? "Discard" : "Cancel") {
                        if recorder.isRecording {
                            confirmDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    recorder.discard()
                    dismiss()
                }
                Button("Keep Recording", role: .cancel) {}
            }
            .onChange(of: recorder.level) { _, level in
                guard recorder.isRecording else { return }
                levels.removeFirst()
                levels.append(level)
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(recorder.isRecording)
    }

    private var recordButton: some View {
        Button {
            Task {
                if recorder.isRecording {
                    await model.finishRecording(title: title, language: language.isEmpty ? nil : language)
                    dismiss()
                } else {
                    await model.startRecording()
                }
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Theme.record.opacity(0.35), lineWidth: 5)
                    .frame(width: 92, height: 92)
                RoundedRectangle(cornerRadius: recorder.isRecording ? 8 : 40, style: .continuous)
                    .fill(Theme.record)
                    .frame(width: recorder.isRecording ? 36 : 76, height: recorder.isRecording ? 36 : 76)
                    .animation(.spring(duration: 0.3), value: recorder.isRecording)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop and save" : "Start recording")
    }
}

struct LevelMeter: View {
    let levels: [Double]
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            let barWidth = geometry.size.width / CGFloat(levels.count)
            HStack(alignment: .center, spacing: 0) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = max(levels[index], 0.03)
                    Capsule()
                        .fill(active ? Theme.record.opacity(0.4 + 0.6 * level) : Color.secondary.opacity(0.25))
                        .frame(width: max(barWidth - 3, 1), height: max(4, geometry.size.height * level))
                        .frame(width: barWidth)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
