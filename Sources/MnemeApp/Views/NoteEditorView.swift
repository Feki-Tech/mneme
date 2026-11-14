import MnemeAppSupport
import AppKit
import MnemeCore
import SwiftUI

/// Writing and editing notes. Each save of a changed note adds a version; earlier versions are kept.
struct NoteEditorView: View {
    @EnvironmentObject private var model: AppModel
    let entryID: String?
    let version: Int?

    @State private var title: String
    @State private var text: String
    @State private var savedTitle: String
    @State private var savedText: String
    @State private var isSaving = false

    init(entryID: String?, initialTitle: String = "", initialBody: String = "", version: Int? = nil) {
        self.entryID = entryID
        self.version = version
        _title = State(initialValue: initialTitle)
        _text = State(initialValue: initialBody)
        _savedTitle = State(initialValue: initialTitle)
        _savedText = State(initialValue: initialBody)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
            HStack {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isSaving ? "Saving…" : "Save") {
                    save()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .navigationTitle(entryID == nil ? "New Note" : (title.isEmpty ? "Note" : title))
        .onDisappear(perform: saveOnLeaving)
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    if let entryID {
                        model.pendingDeletion = entryID
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(entryID == nil)
                .help("Delete this note")
            }
        }
    }

    private var hasChanges: Bool {
        title != savedTitle || text != savedText
    }

    private var canSave: Bool {
        !isSaving && hasChanges && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var status: String {
        if hasChanges {
            return "Unsaved changes"
        }
        if let version {
            return version > 1 ? "Version \(version) · earlier versions are kept" : "Saved"
        }
        return "Notes stay on this Mac"
    }

    /// Leaving the editor keeps what was typed, without taking the user back to the note.
    private func saveOnLeaving() {
        guard canSave else { return }
        let id = entryID
        let currentTitle = title
        let currentText = text
        Task {
            _ = await model.saveNote(entryID: id, title: currentTitle, body: currentText, navigate: false)
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let currentTitle = title
        let currentText = text
        Task {
            if await model.saveNote(entryID: entryID, title: currentTitle, body: currentText) {
                savedTitle = currentTitle
                savedText = currentText
            }
            isSaving = false
        }
    }
}
