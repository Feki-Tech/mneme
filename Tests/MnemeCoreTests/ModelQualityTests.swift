import Foundation
import XCTest
@testable import MnemeCore

/// On-device monitoring: how each model has done on the archive's recordings, without any telemetry.
final class ModelQualityTests: XCTestCase {
    private var directory: URL!
    private var store: ArchiveStore!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
        store = try ArchiveStore(root: directory.appendingPathComponent("archive", isDirectory: true))
    }

    override func tearDownWithError() throws {
        store = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func transcript(model: String, fingerprint: String?, uncertain: Bool) -> Transcript {
        var second = Fixtures.segment(1, 1.5, 2.9, "Second part.")
        if uncertain {
            second.avgLogprob = -1.3
        }
        var settings = ["profile": "test"]
        settings["model_fingerprint"] = fingerprint
        return Transcript(
            language: LanguageDecision(code: "en", source: .forced),
            segments: [Fixtures.segment(0, 0, 1.4, "First part."), second],
            provenance: Provenance(engine: "whisperkit", modelID: model, settings: settings),
            processingSeconds: 1.5
        )
    }

    private func audio(_ name: String, frequency: Double) throws -> PreparedAudio {
        let url = directory.appendingPathComponent(name)
        try Fixtures.writeTone(to: url, seconds: 3, frequency: frequency)
        return try AudioPreparer.prepare(url)
    }

    func testRowsPerModelFingerprintWithCorrections() throws {
        XCTAssertEqual(try store.modelQuality(), [])

        let first = try store.ingestVoice(try audio("a.wav", frequency: 440), transcript: transcript(model: "turbo", fingerprint: "aaaaaaaaaaaa", uncertain: true))
        _ = try store.ingestVoice(try audio("b.wav", frequency: 550), transcript: transcript(model: "turbo", fingerprint: "aaaaaaaaaaaa", uncertain: false))
        _ = try store.ingestVoice(try audio("c.wav", frequency: 660), transcript: transcript(model: "turbo", fingerprint: nil, uncertain: false))

        // Two corrections of the same recording count once, for the machine transcript they corrected.
        _ = try store.correctSegment(entryID: first.entry.id, segmentIndex: 1, text: "The second part.")
        _ = try store.correctSegment(entryID: first.entry.id, segmentIndex: 0, text: "The first part.")

        let rows = try store.modelQuality()
        XCTAssertEqual(rows.map(\.fingerprint), ["aaaaaaaaaaaa", "unknown"])
        let current = try XCTUnwrap(rows.first)
        XCTAssertEqual(current.modelID, "turbo")
        XCTAssertEqual(current.transcripts, 2)
        XCTAssertEqual(current.segments, 4)
        XCTAssertEqual(current.flaggedSegments, 1)
        XCTAssertEqual(current.reviewedTranscripts, 1)
        XCTAssertEqual(current.audioSeconds, 6, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(current.realTimeFactor), 0.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(current.flaggedShare), 0.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(current.reviewedShare), 0.5, accuracy: 1e-9)

        let legacy = rows[1]
        XCTAssertEqual(legacy.transcripts, 1)
        XCTAssertEqual(legacy.reviewedTranscripts, 0)
    }
}
