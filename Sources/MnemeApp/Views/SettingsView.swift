import AppKit
import MnemeCore
import MnemeSpeech
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LanguagesSettings()
                .tabItem { Label("Languages", systemImage: "globe") }
            GlossarySettings()
                .tabItem { Label("Glossary", systemImage: "text.book.closed") }
            ModelSettings()
                .tabItem { Label("Speech Model", systemImage: "cpu") }
            ArchiveSettings()
                .tabItem { Label("Archive", systemImage: "archivebox") }
        }
        .frame(width: 580, height: 440)
    }
}

struct LanguagesSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var other = ""

    private let common = ["en", "fr", "de", "ar", "es", "it", "pt", "nl", "tr", "ru", "hi", "ur", "fa", "zh", "ja", "ko"]

    var body: some View {
        Form {
            Section {
                Text("The language of each recording is identified only among the languages you speak, so an accent is not mistaken for another language. With a single language, identification is skipped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(common, id: \.self) { code in
                        Toggle(Formatters.languageName(code), isOn: binding(for: code))
                    }
                }
            }
            Section {
                Toggle("I switch languages within a recording", isOn: mixedBinding)
                Text(model.mixedLanguages
                    ? "Each sentence gets its own language, so a recording that moves from French to English is transcribed in both."
                    : "One language for the whole recording: a little faster, but a sentence in another language may come out translated or be left out.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } footer: {
                if model.languageProfile.count < 2 {
                    Text("Applies when two or more languages are selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Other languages") {
                HStack {
                    TextField("Codes or names", text: $other, prompt: Text("sw, tl, Swahili"))
                    Button("Add") {
                        let added = LanguagePolicy.parseList(other)
                        other = ""
                        Task {
                            await model.setLanguages(model.languageProfile + added)
                        }
                    }
                    .disabled(other.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Your languages, in order") {
                if model.languageProfile.isEmpty {
                    Text("None: any of Whisper's 100 languages can be identified.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.languageProfile.map { Formatters.languageName($0) }.joined(separator: ", "))
                    Button("Clear") {
                        Task {
                            await model.setLanguages([])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var mixedBinding: Binding<Bool> {
        Binding(get: { model.mixedLanguages }, set: { enabled in
            Task {
                await model.setMixedLanguages(enabled)
            }
        })
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(get: { model.languageProfile.contains(code) }, set: { enabled in
            Task {
                await model.setLanguage(code, enabled: enabled)
            }
        })
    }
}

struct GlossarySettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var newTerm = ""

    var body: some View {
        Form {
            Section {
                Text("Names, places and terms you use. They are given to the recogniser as a hint, so it spells them your way.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("New term", text: $newTerm)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Terms (\(model.glossary.count))") {
                if model.glossary.isEmpty {
                    Text("No terms yet. Corrections suggest new ones.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.glossary, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            Task {
                                await model.removeGlossaryTerm(term)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        newTerm = ""
        Task {
            await model.addGlossaryTerms([term])
        }
    }
}

struct ModelSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: profileName) {
                    ForEach(ModelProfile.builtIn, id: \.name) { profile in
                        Text("\(profile.name.capitalized) · \(profile.variant)").tag(profile.name)
                    }
                }
                Text(model.modelProfile.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: model.modelReady ? "Installed, works offline" : "Not installed")
            }
            if !model.modelReady {
                Section("Install") {
                    Text("Installing downloads \(model.modelProfile.approximateDownloadSize) from huggingface.co/argmaxinc/whisperkit-coreml. This is the only time Mneme uses the network; your recordings never leave this Mac.")
                        .font(.callout)
                    if let progress = model.downloadProgress {
                        ProgressView(value: min(progress, 1)) {
                            Text(progress >= 1 ? "Preparing the model for this Mac…" : "Downloading…")
                        }
                    }
                    Button("Download and Install") {
                        Task {
                            await model.downloadModel()
                        }
                    }
                    .disabled(model.isDownloading)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var profileName: Binding<String> {
        Binding(get: { model.modelProfile.name }, set: { name in
            Task {
                await model.selectModel(named: name)
            }
        })
    }
}

struct ArchiveSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Archive", value: model.archiveRoot.path)
                LabeledContent("Models", value: model.modelsDirectory.path)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.archiveRoot])
                }
            }
            Section("Integrity") {
                Text("Checks the database, the search index and the checksum of every original recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Verify Archive") {
                    Task {
                        await model.verifyArchive()
                    }
                }
            }
            Section("Privacy") {
                Text("Everything is stored in your user Library with access limited to your account. Deleted entries are overwritten in the database and their recordings removed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
