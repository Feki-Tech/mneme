import MnemeAppSupport
import MnemeCore
import MnemeSpeech
import SwiftUI

/// First launch: what Mneme does, the languages the user speaks, and the model download.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    let finish: () -> Void
    @State private var page = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                welcome.tag(0)
                languages.tag(1)
                modelPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(page == 2 ? "Done" : "Skip", action: finish)
                }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(Theme.accent)
            Text("Your thoughts, kept")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "mic.fill", title: "Speak", text: "Record a thought, even with the screen locked.")
                Feature(symbol: "text.quote", title: "Read", text: "It is transcribed on this iPhone, in the languages you speak, even when you switch between them.")
                Feature(symbol: "lock.fill", title: "Private", text: "No account, no cloud, no tracking. Nothing leaves your phone unless you share it.")
            }
            .padding(.horizontal, 8)
            Spacer()
            Button("Continue") { withAnimation { page = 1 } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer().frame(height: 40)
        }
        .padding(24)
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which languages do you speak?")
                .font(.title.bold())
                .padding(.top, 40)
            Text("Mneme listens only for these, so an accent is not mistaken for another language. You can change them later in Settings.")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    ForEach(["en", "fr", "de", "ar", "es", "it", "pt", "nl", "tr", "ru", "hi", "zh"], id: \.self) { code in
                        let selected = model.languageProfile.contains(code)
                        Button {
                            Task { await model.setLanguage(code, enabled: !selected) }
                        } label: {
                            HStack {
                                Text(Formatters.languageName(code))
                                Spacer()
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            }
                            .padding(12)
                            .background(selected ? Theme.accent.opacity(0.15) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("Continue") { withAnimation { page = 2 } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Spacer().frame(height: 40)
        }
        .padding(24)
    }

    private var modelPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install the speech model")
                .font(.title.bold())
                .padding(.top, 40)
            Text("Transcription runs on this iPhone with OpenAI's Whisper. The model is downloaded once; after that Mneme works offline. You can record now and transcribe later.")
                .foregroundStyle(.secondary)
            ForEach(ModelProfile.phone, id: \.name) { profile in
                Button {
                    Task { await model.selectModel(named: profile.name) }
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: model.modelProfile.name == profile.name ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(profile.name.capitalized) · \(profile.approximateDownloadSize)")
                                .font(.headline)
                            Text(profile.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isDownloading)
            }
            if model.modelReady {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let progress = model.downloadProgress {
                ProgressView(value: min(progress, 1)) {
                    Text(progress >= 1 ? "Preparing the model for this iPhone…" : "Downloading \(Int(progress * 100)) %")
                        .font(.footnote)
                }
            }
            Spacer()
            if model.modelReady {
                Button("Start", action: finish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            } else {
                Button("Download Now") {
                    Task { await model.downloadModel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(model.isDownloading)
                Button("Later", action: finish)
                    .frame(maxWidth: .infinity)
            }
            Spacer().frame(height: 40)
        }
        .padding(24)
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
