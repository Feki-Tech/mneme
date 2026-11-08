import Foundation
import XCTest
@testable import MnemeSpeech

final class ModelTests: XCTestCase {
    func testProfilesResolveByNameOrVariant() {
        XCTAssertEqual(ModelProfile.resolve("accurate"), .accurate)
        XCTAssertEqual(ModelProfile.resolve(" FAST "), .fast)
        XCTAssertEqual(ModelProfile.resolve("large-v3"), .accurate)
        let custom = ModelProfile.resolve("small")
        XCTAssertEqual(custom.variant, "small")
        XCTAssertTrue(custom.isMultilingual)
        XCTAssertFalse(ModelProfile.resolve("small.en").isMultilingual)
        XCTAssertFalse(ModelProfile.resolve("small.en_217MB").isMultilingual)
        XCTAssertEqual(ModelProfile.defaultProfile, .accurate)
    }

    func testLocatorFindsOnlyCompleteFoldersAndTracksReadiness() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mneme-models-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = ModelLocator.repositoryDirectory(base: base)

        func makeFolder(_ name: String, components: [String]) throws -> URL {
            let folder = repository.appendingPathComponent(name, isDirectory: true)
            for component in components {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(component), withIntermediateDirectories: true)
            }
            return folder
        }

        // A distilled model whose name merely ends with the variant must not be picked for large-v3.
        _ = try makeFolder("distil-whisper_distil-large-v3", components: ModelLocator.requiredComponents)
        let openAI = try makeFolder("openai_whisper-large-v3", components: ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc"])
        XCTAssertNil(ModelLocator.localModelFolder(variant: "large-v3", base: base), "Incomplete downloads are ignored")

        try FileManager.default.createDirectory(at: openAI.appendingPathComponent("TextDecoder.mlmodelc"), withIntermediateDirectories: true)
        XCTAssertEqual(ModelLocator.localModelFolder(variant: "large-v3", base: base)?.lastPathComponent, "openai_whisper-large-v3")
        XCTAssertEqual(ModelLocator.localModelFolder(variant: "distil-large-v3", base: base)?.lastPathComponent, "distil-whisper_distil-large-v3")

        XCTAssertNil(ModelLocator.readyModelFolder(variant: "large-v3", base: base))
        ModelLocator.markReady(openAI)
        XCTAssertNotNil(ModelLocator.readyModelFolder(variant: "large-v3", base: base))
        XCTAssertEqual(ModelLocator.installedFolders(base: base).map { $0.lastPathComponent }, ["distil-whisper_distil-large-v3", "openai_whisper-large-v3"])

        let engine = WhisperEngine(profile: .accurate, modelsDirectory: base)
        XCTAssertTrue(engine.isReady)
        XCTAssertFalse(engine.isLoaded)
    }

    func testLoadingWithoutDownloadPermissionNeverTouchesTheNetwork() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mneme-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = WhisperEngine(profile: .fast, modelsDirectory: base)
        do {
            try await engine.load(allowDownload: false)
            XCTFail("Loading should fail without a prepared model")
        } catch {
            XCTAssertEqual(error as? SpeechError, .modelNotDownloaded(variant: ModelProfile.fast.variant, size: ModelProfile.fast.approximateDownloadSize))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path), "Nothing is created when loading is refused")
    }

    func testMostCommonLanguageIsDeterministic() {
        XCTAssertEqual(WhisperEngine.mostCommon(["fr", "<|en|>", "en", "fr"]), "en")
        XCTAssertEqual(WhisperEngine.mostCommon(["ar", "ar", "fr"]), "ar")
        XCTAssertNil(WhisperEngine.mostCommon(["", " "]))
    }
}
