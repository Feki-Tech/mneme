import AVFoundation
import Foundation
import XCTest
@testable import MnemeCore

/// The app records PCM into a CAF working file and archives an AAC encoding of it.
final class AudioEncoderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The settings the recorder uses for its working file.
    private let workingFileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    private func toneBuffer(seconds: Double, sampleRate: Double = 48_000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            channel[index] = Float(0.3 * sin(2 * Double.pi * 330 * Double(index) / sampleRate))
        }
        return buffer
    }

    func testEncodingKeepsTheDurationAndShrinksTheFile() throws {
        let source = directory.appendingPathComponent("tone.wav")
        try Fixtures.writeTone(to: source, seconds: 2.5, frequency: 330, sampleRate: 48_000)
        let encoded = directory.appendingPathComponent("tone.m4a")

        let duration = try AudioEncoder.encodeAAC(from: source, to: encoded)
        XCTAssertEqual(duration, 2.5, accuracy: 0.1)
        XCTAssertEqual(try AudioFileInfo.duration(of: encoded), 2.5, accuracy: 0.1)
        let sourceSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)
        let encodedSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: encoded.path)[.size] as? NSNumber)
        XCTAssertLessThan(encodedSize.intValue, sourceSize.intValue / 4)
        XCTAssertEqual(try AudioPreparer.prepare(encoded).mediaType, "audio/mp4")
    }

    func testWorkingFileIsReadableWhileStillBeingWritten() throws {
        let working = directory.appendingPathComponent("recording.caf")
        let snapshot = directory.appendingPathComponent("after-crash.caf")
        let second = try toneBuffer(seconds: 1)
        do {
            let writer = try AVAudioFile(
                forWriting: working,
                settings: workingFileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            for _ in 0..<3 {
                try writer.write(from: second)
            }
            // What is on disk while the recorder is still running, as after a crash or power loss.
            try FileManager.default.copyItem(at: working, to: snapshot)
            withExtendedLifetime(writer) {}
        }
        let recovered = try AudioFileInfo.duration(of: snapshot)
        XCTAssertGreaterThanOrEqual(recovered, 2.0, "A partial working file must keep what was recorded")
        XCTAssertLessThanOrEqual(recovered, 3.0 + 0.01)

        let encoded = directory.appendingPathComponent("recovered.m4a")
        XCTAssertEqual(try AudioEncoder.encodeAAC(from: snapshot, to: encoded), recovered, accuracy: 0.1)
    }

    func testAnEmptyRecordingIsRejectedWithoutLeavingAFile() throws {
        let working = directory.appendingPathComponent("empty.caf")
        do {
            let writer = try AVAudioFile(
                forWriting: working,
                settings: workingFileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            withExtendedLifetime(writer) {}
        }
        let encoded = directory.appendingPathComponent("empty.m4a")
        XCTAssertThrowsError(try AudioEncoder.encodeAAC(from: working, to: encoded)) { error in
            guard case ArchiveError.unreadableAudio = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: encoded.path))
    }

    func testAnInterruptedImportIsFoundByItsFileName() throws {
        let store = try ArchiveStore(root: directory.appendingPathComponent("archive", isDirectory: true))
        let source = directory.appendingPathComponent("recording-20261108-101530-a1b2c3d4.wav")
        try Fixtures.writeTone(to: source, seconds: 2, frequency: 520, sampleRate: 48_000)
        let encoded = source.deletingPathExtension().appendingPathExtension("m4a")
        try AudioEncoder.encodeAAC(from: source, to: encoded)
        let archived = try store.ingestAudio(try AudioPreparer.prepare(encoded))

        XCTAssertEqual(try store.asset(originalFilename: encoded.lastPathComponent)?.entryID, archived.entry.id)
        XCTAssertNil(try store.asset(originalFilename: "recording-20261108-101531-00000000.m4a"))
        XCTAssertEqual(try AudioFileInfo.duration(of: store.audioURL(for: archived.asset)), 2, accuracy: 0.1)
    }
}
