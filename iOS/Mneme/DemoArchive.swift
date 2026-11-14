import AVFoundation
import Foundation
import MnemeCore

/// A temporary archive with sample entries, opened with the `-demo` launch argument for screenshots and UI review.
/// The user's archive is never touched, and nothing here is used in normal launches.
enum DemoArchive {
    struct Location {
        let archiveRoot: URL
        let modelsDirectory: URL
    }

    static func create() throws -> Location {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MnemeDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let location = Location(
            archiveRoot: base.appendingPathComponent("Archive", isDirectory: true),
            modelsDirectory: base.appendingPathComponent("Models", isDirectory: true)
        )
        let store = try ArchiveStore(root: location.archiveRoot)
        _ = try store.setLanguageProfile(["fr", "en", "ar"])
        try store.setMixedLanguages(true)
        _ = try store.addGlossaryTerms(["Mneme", "Sidi Bou Said", "Lisbon"])

        let now = Date()
        let day: TimeInterval = 86_400
        let scratch = base.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        try addVoice(
            to: store, scratch: scratch, name: "walk",
            title: "Morning walk: ideas for the book",
            recordedAt: now.addingTimeInterval(-2 * 3600),
            language: LanguageDecision(code: "fr", probability: 0.94, source: .mixed),
            segments: [
                segment(0, 0, 6.2, "Ce matin je repensais au premier chapitre, celui sur la maison de ma grand-mère à Sidi Bou Said.", "fr"),
                segment(1, 6.2, 12.8, "The opening should start with the smell of jasmine and the blue door, not with dates.", "en"),
                segment(2, 12.8, 18.4, "وبعد ذلك ننتقل إلى الميناء والقوارب الصغيرة", "ar"),
                segment(3, 18.4, 25.0, "Et il faut que je demande à ma mère le nom exact du café près du port.", "fr", flags: [.lowConfidence]),
                segment(4, 25.0, 31.5, "Note to self: record her telling the story herself next weekend.", "en"),
            ]
        )
        try addVoice(
            to: store, scratch: scratch, name: "standup",
            title: "Sensor rollout, next steps",
            recordedAt: now.addingTimeInterval(-day - 3 * 3600),
            language: LanguageDecision(code: "en", probability: 0.98, source: .profile),
            segments: [
                segment(0, 0, 7.5, "Three gateways are still on the old firmware, so the rollout waits until Thursday."),
                segment(1, 7.5, 14.0, "Ask the team to compare battery drain with the new reporting interval.", flags: [.uncertainWords]),
                segment(2, 14.0, 20.0, "If the numbers hold, we switch the remaining sites in one go."),
            ]
        )
        try addVoice(
            to: store, scratch: scratch, name: "trip",
            title: "Lisbon trip",
            recordedAt: now.addingTimeInterval(-9 * day),
            language: LanguageDecision(code: "en", probability: 0.97, source: .profile),
            segments: [
                segment(0, 0, 6.0, "Things to remember from Lisbon: the tram up to the castle in the early morning."),
                segment(1, 6.0, 12.0, "The little bakery near the river that opened at seven, and the view from the miradouro."),
            ]
        )
        _ = try store.addNote(
            title: "Gift ideas",
            body: "For Amel: the ceramics workshop in Nabeul.\nFor Dad: a good radio for the kitchen.\nFor me: finally print the photos from Lisbon.",
            recordedAt: now.addingTimeInterval(-5 * 3600)
        )
        _ = try store.addNote(
            title: "Questions for the doctor appointment",
            body: "Ask about the follow-up date and whether the results can be sent by mail.",
            recordedAt: now.addingTimeInterval(-3 * day)
        )
        // Archived but not transcribed yet: shows how a recording waits for the model.
        let pending = scratch.appendingPathComponent("pending.wav")
        try writeTone(to: pending, seconds: 12)
        _ = try store.ingestAudio(try AudioPreparer.prepare(pending), title: "Voice memo from the car", recordedAt: now.addingTimeInterval(-20 * 60))
        return location
    }

    private static func addVoice(
        to store: ArchiveStore,
        scratch: URL,
        name: String,
        title: String,
        recordedAt: Date,
        language: LanguageDecision,
        segments: [TranscribedSegment]
    ) throws {
        let url = scratch.appendingPathComponent("\(name).wav")
        try writeTone(to: url, seconds: (segments.last?.end ?? 5) + 1)
        let transcript = Transcript(
            language: language,
            segments: segments,
            provenance: Provenance(engine: "demo", modelID: "demo-sample"),
            processingSeconds: 4
        )
        try store.ingestVoice(try AudioPreparer.prepare(url), transcript: transcript, title: title, recordedAt: recordedAt)
    }

    private static func segment(
        _ index: Int, _ start: Double, _ end: Double, _ text: String, _ language: String? = nil,
        flags: Set<QualityFlag> = []
    ) -> TranscribedSegment {
        TranscribedSegment(
            index: index, start: start, end: end, text: text,
            avgLogprob: flags.isEmpty ? -0.2 : -1.1, compressionRatio: 1.3, noSpeechProb: 0.02, temperature: 0,
            flags: flags, language: language
        )
    }

    /// A quiet, distinct tone per file (the archive refuses byte-identical recordings).
    private static func writeTone(to url: URL, seconds: Double) throws {
        let sampleRate = 16_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * sampleRate)),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = buffer.frameCapacity
        let pitch = 220 + Double(abs(url.lastPathComponent.hashValue % 200))
        for index in 0..<Int(buffer.frameLength) {
            let time = Double(index) / sampleRate
            let envelope = 0.5 + 0.5 * sin(2 * Double.pi * 0.25 * time)
            channel[index] = Float(0.05 * envelope * sin(2 * Double.pi * pitch * time))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
