import MnemeCore
import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: RecorderModel
    @State private var title = ""
    @State private var language = ""
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(recorder.isRecording ? Formatters.position(recorder.elapsed) : "Ready to record")
                .font(.system(size: 40, weight: .light, design: .rounded).monospacedDigit())
            LevelMeter(level: recorder.level)
                .frame(width: 320, height: 8)
                .opacity(recorder.isRecording ? 1 : 0.3)
            Button {
                toggleRecording()
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 76))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .help(recorder.isRecording ? "Stop and save" : "Start recording")

            VStack(spacing: 10) {
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)
                Picker("Language", selection: $language) {
                    Text("Automatic").tag("")
                    ForEach(model.languageProfile, id: \.self) { code in
                        Text(Formatters.languageName(code)).tag(code)
                    }
                }
            }
            .frame(width: 320)

            if recorder.isRecording {
                Button("Discard Recording", role: .destructive) {
                    recorder.discard()
                }
            }
            if isSaving {
                ProgressView("Saving…")
            }
            Text(footnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("New Recording")
    }

    private var footnote: String {
        if recorder.permission == .denied {
            return "Microphone access is off. Allow Mneme in System Settings > Privacy & Security > Microphone."
        }
        if !model.modelReady {
            return "The recording is saved as soon as you stop. It will be transcribed once a speech model is installed."
        }
        return "The recording is saved as soon as you stop, then transcribed on this Mac."
    }

    private func toggleRecording() {
        if recorder.isRecording {
            isSaving = true
            let chosenTitle = title
            let chosenLanguage = language.isEmpty ? nil : language
            Task {
                await model.finishRecording(title: chosenTitle, language: chosenLanguage)
                isSaving = false
                title = ""
            }
        } else {
            Task {
                await model.startRecording()
            }
        }
    }
}

struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.9 ? Color.red : Color.green)
                    .frame(width: proxy.size.width * max(0, min(1, level)))
            }
        }
    }
}
