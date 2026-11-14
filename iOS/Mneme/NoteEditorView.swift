import MnemeAppSupport
import MnemeCore
import SwiftUI
import UIKit

/// A written note. Every saved edit becomes a new version; leaving the editor saves.
struct NoteEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entryID: String?
    var version: Int?

    @State private var title: String
    @State private var text: String
    @State private var savedTitle: String
    @State private var savedText: String
    @State private var shareItems: ShareItems?
    @State private var confirmDelete = false
    @FocusState private var bodyFocused: Bool

    init(entryID: String?, initialTitle: String, initialBody: String, version: Int? = nil) {
        self.entryID = entryID
        self.version = version
        _title = State(initialValue: initialTitle)
        _text = State(initialValue: initialBody)
        _savedTitle = State(initialValue: initialTitle)
        _savedText = State(initialValue: initialBody)
    }

    private var hasChanges: Bool {
        title != savedTitle || text != savedText
    }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $title)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .submitLabel(.next)
                .onSubmit { bodyFocused = true }
            if let version, version > 1 {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }
            TextEditor(text: $text)
                .focused($bodyFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write what you want to keep…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .navigationTitle(entryID == nil ? "New Note" : "Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if entryID == nil {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if entryID == nil {
                    Button("Save") {
                        Task {
                            if await model.saveNote(entryID: nil, title: title, body: text) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isEmpty)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let entryID {
                    if hasChanges {
                        Button("Save") {
                            Task { await save(navigate: false) }
                            bodyFocused = false
                        }
                        .disabled(isEmpty)
                    }
                    Menu {
                        Button {
                            Task {
                                await save(navigate: false)
                                let files = await model.exportFiles(entryID: entryID)
                                if !files.isEmpty { shareItems = ShareItems(urls: files) }
                            }
                        } label: {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Label("Copy Text", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            if entryID == nil { bodyFocused = true }
        }
        .onDisappear {
            if entryID != nil {
                Task { await save(navigate: false) }
            }
        }
        .sheet(item: $shareItems) { items in
            ActivityView(items: items.urls)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Delete this note permanently?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let entryID {
                    savedTitle = title
                    savedText = text
                    Task { await model.delete(entryID: entryID) }
                }
            }
        } message: {
            Text("Every version of the note is removed from this iPhone. This cannot be undone.")
        }
    }

    private func save(navigate: Bool) async {
        guard let entryID, hasChanges, !isEmpty else { return }
        let newTitle = title
        let newText = text
        if await model.saveNote(entryID: entryID, title: newTitle, body: newText, navigate: navigate) {
            savedTitle = newTitle
            savedText = newText
        }
    }
}
