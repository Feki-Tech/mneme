import MnemeAppSupport
import MnemeCore
import MnemeSpeech
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var shareItems: ShareItems?
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                Section {
                    NavigationLink {
                        LanguageSettings()
                    } label: {
                        LabeledContent("Languages", value: model.languageProfile.isEmpty ? "Any" : model.languageProfile.map { $0.uppercased() }.joined(separator: ", "))
                    }
                    NavigationLink {
                        GlossarySettings()
                    } label: {
                        LabeledContent("Glossary", value: "\(model.glossary.count) terms")
                    }
                } header: {
                    Text("Recognition")
                } footer: {
                    Text("Languages you speak and names you use make transcripts more accurate for your voice and accent.")
                }
                transferSection
                Section {
                    Toggle("Include in iPhone Backups", isOn: Binding(
                        get: { model.includeArchiveInBackups },
                        set: { model.includeArchiveInBackups = $0 }
                    ))
                    Button("Verify Archive") {
                        Task { await model.verifyArchive() }
                    }
                } header: {
                    Text("Archive")
                } footer: {
                    Text("With backups on, your recordings and notes are part of the iPhone's iCloud or computer backup, so a lost phone does not mean lost recordings. Speech models are never backed up; they can be downloaded again.")
                }
                Section("Privacy") {
                    Label("Recordings are transcribed on this iPhone.", systemImage: "iphone")
                    Label("No account, no server, no tracking.", systemImage: "person.crop.circle.badge.xmark")
                    Label("The network is used only to download a model when you ask.", systemImage: "arrow.down.circle")
                }
                .font(.subheadline)
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    Link("Source code and documentation", destination: URL(string: "https://github.com/Feki-Tech/mneme")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $shareItems) { items in
                ActivityView(items: items.urls)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var modelSection: some View {
        Section {
            Picker("Model", selection: Binding(
                get: { model.modelProfile.name },
                set: { name in Task { await model.selectModel(named: name) } }
            )) {
                ForEach(ModelProfile.phone, id: \.name) { profile in
                    Text("\(profile.name.capitalized) · \(profile.approximateDownloadSize)").tag(profile.name)
                }
            }
            .disabled(model.isDownloading)
            Text(model.modelProfile.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            LabeledContent("Status") {
                if model.modelReady {
                    Label(model.modelLoaded ? "Ready" : "Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Not installed")
                }
            }
            if !model.modelReady {
                if let progress = model.downloadProgress {
                    ProgressView(value: min(progress, 1)) {
                        Text(progress >= 1 ? "Preparing the model for this iPhone…" : "Downloading \(Int(progress * 100)) %")
                            .font(.footnote)
                    }
                }
                Button {
                    Task { await model.downloadModel() }
                } label: {
                    Label("Download \(model.modelProfile.approximateDownloadSize)", systemImage: "arrow.down.circle")
                }
                .disabled(model.isDownloading)
            }
        } header: {
            Text("Speech Model")
        } footer: {
            if !model.modelReady {
                Text("Downloaded once from huggingface.co/argmaxinc/whisperkit-coreml. Use Wi-Fi and keep Mneme open until it finishes; preparing the model for this iPhone can take a few minutes the first time.")
            }
        }
    }

    private var transferSection: some View {
        Section {
            Button {
                exporting = true
                Task {
                    if let folder = await model.exportAll() {
                        shareItems = ShareItems(urls: [folder])
                    }
                    exporting = false
                }
            } label: {
                HStack {
                    Label("Export Everything…", systemImage: "square.and.arrow.up.on.square")
                    if exporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(exporting || model.entries.isEmpty)
            Button {
                dismiss()
                Task {
                    // The file picker opens once this sheet has gone.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    model.isImportingFiles = true
                }
            } label: {
                Label("Import Recordings…", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Move to Your Mac")
        } footer: {
            Text("Recordings are exported with their date and title in the file name, plus a Markdown copy of the transcript. AirDrop them to your Mac and choose File > Import Recordings in Mneme for Mac; they keep their date and title.")
        }
    }
}

struct LanguageSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var other = ""

    private let common = ["en", "fr", "de", "ar", "es", "it", "pt", "nl", "tr", "ru", "hi", "ur", "fa", "zh", "ja", "ko"]

    var body: some View {
        Form {
            Section {
                ForEach(common, id: \.self) { code in
                    Toggle(Formatters.languageName(code), isOn: Binding(
                        get: { model.languageProfile.contains(code) },
                        set: { enabled in Task { await model.setLanguage(code, enabled: enabled) } }
                    ))
                }
            } footer: {
                Text("The language of each recording is identified only among the languages you speak, so an accent is not mistaken for another language. With a single language, identification is skipped.")
            }
            Section {
                Toggle("I switch languages within a recording", isOn: Binding(
                    get: { model.mixedLanguages },
                    set: { enabled in Task { await model.setMixedLanguages(enabled) } }
                ))
            } footer: {
                Text(model.mixedLanguages
                    ? "Each sentence gets its own language, so a recording that moves from French to English is transcribed in both."
                    : "One language for the whole recording: a little faster, but a sentence in another language may come out translated or be left out.")
            }
            Section("Other languages") {
                HStack {
                    TextField("Codes or names, e.g. sw, Swahili", text: $other)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add") {
                        let added = LanguagePolicy.parseList(other)
                        other = ""
                        Task { await model.setLanguages(model.languageProfile + added) }
                    }
                    .disabled(other.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !model.languageProfile.isEmpty {
                    Text(model.languageProfile.map { Formatters.languageName($0) }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                    Button("Clear All", role: .destructive) {
                        Task { await model.setLanguages([]) }
                    }
                }
            }
        }
        .navigationTitle("Languages")
    }
}

struct GlossarySettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var newTerm = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("New term", text: $newTerm)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Names, places and terms you use. They are given to the recogniser as a hint, so it spells them your way.")
            }
            Section("Terms (\(model.glossary.count))") {
                if model.glossary.isEmpty {
                    Text("No terms yet. Corrections suggest new ones.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.glossary, id: \.self) { term in
                    Text(term)
                }
                .onDelete { offsets in
                    let terms = offsets.map { model.glossary[$0] }
                    Task {
                        for term in terms {
                            await model.removeGlossaryTerm(term)
                        }
                    }
                }
            }
        }
        .navigationTitle("Glossary")
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        newTerm = ""
        Task { await model.addGlossaryTerms([term]) }
    }
}
