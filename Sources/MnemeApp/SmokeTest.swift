import MnemeAppSupport
import AppKit
import AVFoundation
import Foundation
import MnemeCore
import SwiftUI

/// `Mneme --smoke-test [--screenshots <folder>]`: exercises the archive and renders every screen offscreen,
/// then exits. With `--screenshots`, sample entries are added and each screen is saved as a PNG.
/// Everything happens in a temporary archive; the user's data is never touched.
enum SmokeTest {
    @MainActor
    static func run(arguments: [String] = CommandLine.arguments) -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mneme-app-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let archiveRoot = root.appendingPathComponent("Archive", isDirectory: true)
            try probeArchive(at: archiveRoot)
            print("archive: notes, search, versions and deletion work")

            _ = NSApplication.shared
            let model = AppModel(archiveRoot: archiveRoot, modelsDirectory: root.appendingPathComponent("Models", isDirectory: true))
            let screens: [(String, AnyView)] = [
                ("main window", AnyView(ContentView())),
                ("recorder", AnyView(RecorderView())),
                ("review", AnyView(ReviewView())),
                ("new note", AnyView(NoteEditorView(entryID: nil))),
                ("settings", AnyView(SettingsView())),
            ]
            for (name, screen) in screens {
                let host = NSHostingView(rootView: screen
                    .environmentObject(model)
                    .environmentObject(model.recorder)
                    .environmentObject(model.player))
                host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
                host.layoutSubtreeIfNeeded()
                print("rendered \(name)")
            }

            if let index = arguments.firstIndex(of: "--screenshots"), arguments.indices.contains(index + 1) {
                let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                try captureScreens(model: model, archiveRoot: archiveRoot, scratch: root, to: folder)
            }
            print("SMOKE TEST: PASS")
            return true
        } catch {
            print("SMOKE TEST: FAIL \(error)")
            return false
        }
    }

    private struct ProbeFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func probeArchive(at root: URL) throws {
        let store = try ArchiveStore(root: root)
        let note = try store.addNote(title: "Smoke test", body: "Bonjour, ceci est une note pour tester la recherche.")
        guard try store.search("recherche").contains(where: { $0.entryID == note.entry.id }) else {
            throw ProbeFailure(description: "the note was not found by search")
        }
        let second = try store.updateNote(entryID: note.entry.id, title: "Smoke test", body: "Second version.")
        guard second.version == 2 else {
            throw ProbeFailure(description: "editing the note did not add a version")
        }
        try store.deleteEntry(id: note.entry.id)
        guard try store.recentEntries().isEmpty else {
            throw ProbeFailure(description: "the deleted note is still listed")
        }
    }

    // MARK: - Screenshots

    @MainActor private static var started = false

    @MainActor
    private static func captureScreens(model: AppModel, archiveRoot: URL, scratch: URL, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sample = try addSampleEntries(archiveRoot: archiveRoot, scratch: scratch)
        NSApp.setActivationPolicy(.accessory)

        started = false
        Task { @MainActor in
            await model.start()
            SmokeTest.started = true
        }
        spin(until: { SmokeTest.started }, timeout: 15)
        guard started else {
            throw ProbeFailure(description: "the app model did not start")
        }

        let window = offscreenWindow(size: NSSize(width: 1200, height: 760))
        window.contentView = NSHostingView(rootView: ContentView()
            .environmentObject(model)
            .environmentObject(model.recorder)
            .environmentObject(model.player))
        window.orderFrontRegardless()
        defer { window.close() }

        let routes: [(String, AppModel.Route)] = [
            ("1-home", .home),
            ("2-recording-entry", .entry(sample.voiceID)),
            ("3-review", .review),
            ("4-note", .entry(sample.noteID)),
            ("5-recorder", .recorder),
            ("6-untranscribed-entry", .entry(sample.untranscribedID)),
        ]
        for (name, route) in routes {
            model.route = route
            spin(until: { false }, timeout: 1.2)
            try save(window, to: folder.appendingPathComponent("\(name).png"))
        }

        // The sidebar column is drawn as a material that offscreen captures leave out: capture it on its own.
        let sidebar = offscreenWindow(size: NSSize(width: 320, height: 760))
        sidebar.contentView = NSHostingView(rootView: SidebarView()
            .environmentObject(model)
            .environmentObject(model.recorder)
            .environmentObject(model.player))
        sidebar.orderFrontRegardless()
        defer { sidebar.close() }
        model.route = .entry(sample.voiceID)
        spin(until: { false }, timeout: 0.8)
        try save(sidebar, to: folder.appendingPathComponent("0-sidebar.png"))

        let settings = offscreenWindow(size: NSSize(width: 580, height: 440))
        settings.contentView = NSHostingView(rootView: SettingsView().environmentObject(model))
        settings.orderFrontRegardless()
        defer { settings.close() }
        spin(until: { false }, timeout: 0.8)
        try save(settings, to: folder.appendingPathComponent("7-settings.png"))
        print("screenshots: \(folder.path)")
    }

    /// A note, a transcribed recording with one uncertain passage, and a recording waiting for transcription.
    private static func addSampleEntries(archiveRoot: URL, scratch: URL) throws -> (voiceID: String, noteID: String, untranscribedID: String) {
        let store = try ArchiveStore(root: archiveRoot)
        _ = try store.setLanguageProfile(["en", "fr", "ar"])
        try store.addGlossaryTerms(["Sfax", "Ben Salah"])

        let firstAudio = scratch.appendingPathComponent("walk.wav")
        try writeTone(to: firstAudio, seconds: 8, frequency: 220)
        var uncertain = TranscribedSegment(index: 1, start: 2.6, end: 5.1, text: "I want to call doctor Ben Sala about the results.")
        uncertain.avgLogprob = -1.3
        let transcript = Transcript(
            language: LanguageDecision(code: "en", probability: 0.93, source: .constrained, modelTopCode: "en"),
            segments: [
                TranscribedSegment(index: 0, start: 0, end: 2.6, text: "This morning I walked along the harbour in Sfax.", avgLogprob: -0.2),
                uncertain,
                TranscribedSegment(index: 2, start: 5.1, end: 7.8, text: "Then I will write the first chapter before lunch.", avgLogprob: -0.25),
            ],
            provenance: Provenance(engine: "sample", modelID: "sample")
        )
        let voice = try store.ingestVoice(try AudioPreparer.prepare(firstAudio), transcript: transcript, title: "Morning walk")

        let note = try store.addNote(
            title: "Idées pour le livre",
            body: "Commencer par la mer, le matin, avant que la ville ne se réveille.\n\nChaque chapitre suit une langue : l'arabe de la maison, le français de l'école, l'anglais du travail."
        )

        let secondAudio = scratch.appendingPathComponent("later.wav")
        try writeTone(to: secondAudio, seconds: 4, frequency: 330)
        let waiting = try store.ingestAudio(try AudioPreparer.prepare(secondAudio))
        return (voice.entry.id, note.entry.id, waiting.entry.id)
    }

    private static func writeTone(to url: URL, seconds: Double, frequency: Double) throws {
        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * sampleRate)),
              let channel = buffer.floatChannelData?[0] else {
            throw ProbeFailure(description: "could not create sample audio")
        }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            channel[index] = Float(0.2 * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFileInfo.pcmFileSettings(sampleRate: sampleRate, channels: 1),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// Never moved onto a screen: borderless, and exempt from AppKit's on-screen constraint.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    @MainActor
    private static func offscreenWindow(size: NSSize) -> NSWindow {
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Screenshots use the light appearance whatever the system setting, so they are comparable.
        window.appearance = NSAppearance(named: .aqua)
        return window
    }

    /// Runs the main run loop so SwiftUI can lay out, start tasks and apply loaded data.
    @MainActor
    private static func spin(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    private static func save(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else {
            throw ProbeFailure(description: "the window has no content")
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let content = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ProbeFailure(description: "could not allocate a bitmap for \(url.lastPathComponent)")
        }
        view.cacheDisplay(in: view.bounds, to: content)
        // Materials (the sidebar, bars) are not drawn by an offscreen capture and leave transparent pixels:
        // put the capture on the window background colour.
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: content.pixelsWide,
            pixelsHigh: content.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: canvas) else {
            throw ProbeFailure(description: "could not allocate a canvas for \(url.lastPathComponent)")
        }
        let rect = NSRect(x: 0, y: 0, width: content.pixelsWide, height: content.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (window.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
        }
        _ = content.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = canvas.representation(using: .png, properties: [:]) else {
            throw ProbeFailure(description: "could not encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }
}
