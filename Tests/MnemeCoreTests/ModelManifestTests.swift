import Foundation
import XCTest
@testable import MnemeCore

/// The manifest ties transcripts and evaluations to the exact model files that produced them.
final class ModelManifestTests: XCTestCase {
    private var directory: URL!
    private var model: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
        model = directory.appendingPathComponent("openai_whisper-test", isDirectory: true)
        try write("AudioEncoder.mlmodelc/weights/weight.bin", Data(repeating: 7, count: 4096))
        try write("AudioEncoder.mlmodelc/model.mil", Data("program".utf8))
        try write("TextDecoder.mlmodelc/weights/weight.bin", Data(repeating: 3, count: 2048))
        try write("config.json", Data("{}".utf8))
        // Not part of the model: Mneme's marker, Finder metadata and a download cache.
        try write(".mneme-ready", Data("loaded\n".utf8))
        try write(".DS_Store", Data([0, 1, 2]))
        try write(".cache/huggingface/download/config.json.metadata", Data("etag".utf8))
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func write(_ relative: String, _ data: Data) throws {
        let url = model.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testBuildListsModelFilesOnlyWithDigests() throws {
        let manifest = try ModelManifest.build(folder: model, variant: "test", source: "unit-test")
        XCTAssertEqual(manifest.files.map(\.path), [
            "AudioEncoder.mlmodelc/model.mil",
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/weights/weight.bin",
            "config.json",
        ])
        XCTAssertEqual(manifest.totalBytes, 4096 + 7 + 2048 + 2)
        XCTAssertEqual(manifest.fingerprint.count, 12)
        XCTAssertEqual(manifest.files.first?.sha256.count, 64)
        XCTAssertEqual(manifest.fingerprint, ModelManifest.fingerprint(of: manifest.files.reversed()), "order must not matter")
    }

    func testRoundTripAndCleanChecks() throws {
        let manifest = try ModelManifest.build(folder: model, variant: "test", source: "unit-test")
        try manifest.write(to: model)
        XCTAssertEqual(try ModelManifest.read(from: model), manifest)
        // The manifest file is hidden, so writing it does not change the model's own files.
        XCTAssertEqual(manifest.quickCheck(folder: model), [])
        XCTAssertEqual(try manifest.verify(folder: model), [])
        XCTAssertEqual(try ModelManifest.build(folder: model, variant: "test", source: "unit-test").fingerprint, manifest.fingerprint)
    }

    func testChangesAreFound() throws {
        let manifest = try ModelManifest.build(folder: model, variant: "test", source: "unit-test")

        // Same size, other content: only the full verification can see it.
        try write("config.json", Data("[]".utf8))
        XCTAssertEqual(manifest.quickCheck(folder: model), [])
        XCTAssertEqual(try manifest.verify(folder: model), ["config.json: content changed"])
        XCTAssertNotEqual(try ModelManifest.build(folder: model, variant: "test", source: "unit-test").fingerprint, manifest.fingerprint)

        try write("TextDecoder.mlmodelc/weights/weight.bin", Data(repeating: 3, count: 100))
        try write("Extra.mlmodelc/model.mil", Data("x".utf8))
        try FileManager.default.removeItem(at: model.appendingPathComponent("AudioEncoder.mlmodelc/model.mil"))
        XCTAssertEqual(manifest.quickCheck(folder: model), [
            "AudioEncoder.mlmodelc/model.mil: missing",
            "TextDecoder.mlmodelc/weights/weight.bin: 2048 bytes expected, 100 found",
            "Extra.mlmodelc/model.mil: not part of the model as installed",
        ])
    }

    func testMissingAndEmptyFolders() throws {
        XCTAssertNil(try ModelManifest.read(from: model))
        let empty = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ModelManifest.build(folder: empty, variant: "test", source: "unit-test"))
        XCTAssertThrowsError(try ModelManifest.build(folder: directory.appendingPathComponent("absent"), variant: "test", source: "unit-test"))
        let manifest = try ModelManifest.build(folder: model, variant: "test", source: "unit-test")
        XCTAssertEqual(manifest.quickCheck(folder: directory.appendingPathComponent("absent")), ["the model folder cannot be read"])
    }
}
