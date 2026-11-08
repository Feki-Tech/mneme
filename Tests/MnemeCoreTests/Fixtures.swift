import AVFoundation
import Foundation
import XCTest
@testable import MnemeCore

enum Fixtures {
    struct FixtureError: Error {}

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mneme-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a sine tone. Different frequencies or lengths give different files and checksums.
    static func writeTone(to url: URL, seconds: Double = 3, frequency: Double = 440, sampleRate: Double = 16_000) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw FixtureError()
        }
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else {
            throw FixtureError()
        }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
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

    /// A clean transcript whose segments carry evenly spaced word timings inside each segment.
    static func transcript(
        language: String = "en",
        segments: [(Double, Double, String)],
        withWords: Bool = true
    ) -> Transcript {
        var built: [TranscribedSegment] = []
        for (index, item) in segments.enumerated() {
            built.append(TranscribedSegment(
                index: index,
                start: item.0,
                end: item.1,
                text: item.2,
                avgLogprob: -0.2,
                compressionRatio: 1.4,
                noSpeechProb: 0.01,
                temperature: 0,
                words: withWords ? words(text: item.2, start: item.0, end: item.1) : []
            ))
        }
        return Transcript(
            language: LanguageDecision(code: language, probability: 0.9, source: .detected, modelTopCode: language),
            segments: built,
            provenance: Provenance(engine: "test-engine", modelID: "test-model", settings: ["profile": "test"]),
            processingSeconds: 0.5
        )
    }

    static func words(text: String, start: Double, end: Double) -> [TranscribedWord] {
        let parts = text.split(separator: " ").map(String.init)
        guard !parts.isEmpty, end > start else { return [] }
        let step = (end - start) / Double(parts.count)
        return parts.enumerated().map { offset, word in
            TranscribedWord(
                text: word,
                start: start + Double(offset) * step,
                // The last word ends exactly at the segment end, so rounding never pushes it outside.
                end: offset == parts.count - 1 ? end : start + Double(offset + 1) * step,
                probability: 0.9
            )
        }
    }

    static func segment(_ index: Int, _ start: Double, _ end: Double, _ text: String) -> TranscribedSegment {
        TranscribedSegment(index: index, start: start, end: end, text: text, avgLogprob: -0.2, compressionRatio: 1.2, noSpeechProb: 0.01, temperature: 0)
    }

    static func transcript(with segments: [TranscribedSegment], language: String = "en") -> Transcript {
        Transcript(
            language: LanguageDecision(code: language, source: .forced),
            segments: segments,
            provenance: Provenance(engine: "test-engine", modelID: "test-model")
        )
    }
}
