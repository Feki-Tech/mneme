import AVFoundation
import Foundation
import MnemeSpeech
import XCTest
@testable import MnemeAppSupport
@testable import MnemeCore

/// A recording shared from one device and imported on another keeps its date, title and audio.
final class TransferTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mneme-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func writeTone(to url: URL, seconds: Double) throws {
        let sampleRate = 16_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * sampleRate)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            channel[index] = Float(0.2 * sin(2 * Double.pi * 440 * Double(index) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    func testExportedRecordingImportsWithItsDateAndTitle() async throws {
        let phone = ArchiveWorker(
            archiveRoot: directory.appendingPathComponent("phone/Archive", isDirectory: true),
            modelsDirectory: directory.appendingPathComponent("phone/Models", isDirectory: true),
            profile: .defaultProfile
        )
        let tone = directory.appendingPathComponent("recording.wav")
        try writeTone(to: tone, seconds: 2)
        let recorded = try await phone.importRecording(url: tone, title: "Idea for the book")
        let files = try await phone.exportFiles(entryID: recorded.id, to: directory.appendingPathComponent("out", isDirectory: true))
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[1].pathExtension, "md")
        XCTAssertTrue(files[0].lastPathComponent.hasSuffix(" Idea for the book.\(files[0].pathExtension)"), files[0].lastPathComponent)
        let markdown = try String(contentsOf: files[1], encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("# Idea for the book\n"), markdown)
        XCTAssertTrue(markdown.contains("_Not transcribed yet._"), markdown)

        let mac = ArchiveWorker(
            archiveRoot: directory.appendingPathComponent("mac/Archive", isDirectory: true),
            modelsDirectory: directory.appendingPathComponent("mac/Models", isDirectory: true),
            profile: .defaultProfile
        )
        let imported = try await mac.importRecording(url: files[0], title: nil)
        XCTAssertEqual(imported.title, "Idea for the book")
        XCTAssertEqual(imported.recordedAt.timeIntervalSince1970, recorded.recordedAt.timeIntervalSince1970, accuracy: 1)
        let pending = try await mac.untranscribed()
        XCTAssertEqual(pending, [imported.id])
    }

    func testExportAllCollectsEveryEntry() async throws {
        let worker = ArchiveWorker(
            archiveRoot: directory.appendingPathComponent("Archive", isDirectory: true),
            modelsDirectory: directory.appendingPathComponent("Models", isDirectory: true),
            profile: .defaultProfile
        )
        _ = try await worker.addNote(title: "Shopping", body: "Bread, olives, coffee.")
        _ = try await worker.addNote(title: "Shopping", body: "Tea.")
        let folder = try await worker.exportAll(to: directory.appendingPathComponent("out", isDirectory: true))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names.count, 2, "\(names)")
        XCTAssertTrue(names.allSatisfy { $0.hasSuffix("Shopping.md") || $0.hasSuffix("Shopping (2).md") }, "\(names)")
    }

    func testPhoneOffersTheSmallModels() {
        XCTAssertEqual(ModelProfile.phone.map(\.name), ["fast", "compact"])
        XCTAssertEqual(ModelProfile.resolve("compact").variant, ModelProfile.compact.variant)
    }
}
