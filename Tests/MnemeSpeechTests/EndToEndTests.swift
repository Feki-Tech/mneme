import Foundation
import XCTest
import MnemeCore
@testable import MnemeSpeech

/// Runs a real Whisper model on speech synthesised with macOS `say`.
/// Opt-in, because the first run downloads a model:
///
///     MNEME_MODEL_TESTS=1 swift test --filter EndToEndTests
///
/// MNEME_TEST_MODEL selects the variant (default: tiny, about 75 MB).
final class EndToEndTests: XCTestCase {
    func testSpeechIsTranscribedValidatedAndArchived() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MNEME_MODEL_TESTS"] == "1" else {
            throw XCTSkip("Set MNEME_MODEL_TESTS=1 to run model tests (the first run downloads a model).")
        }
        let variant = environment["MNEME_TEST_MODEL"] ?? "tiny"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mneme-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sentence = "Please bring three blue notebooks to the library on Friday morning."
        let audio = directory.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, sentence]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        let engine = WhisperEngine(profile: ModelProfile.resolve(variant), modelsDirectory: ModelLocator.defaultModelsDirectory)
        try await engine.load(allowDownload: true)
        XCTAssertTrue(engine.isReady)

        let transcript = try await engine.transcribe(TranscriptionRequest(audioURL: audio, forcedLanguage: "en"))
        let errorRate = ErrorRate.wordErrors(reference: sentence, hypothesis: transcript.text).rate ?? 1
        XCTAssertLessThan(errorRate, 0.35, "Hypothesis: \(transcript.text)")
        XCTAssertEqual(transcript.language.source, .forced)

        let store = try ArchiveStore(root: directory.appendingPathComponent("archive", isDirectory: true))
        let pipeline = IngestPipeline(archive: store, engine: engine)
        let outcome = try await pipeline.ingest(audio, title: "say test")
        guard case .created(let result) = outcome else {
            return XCTFail("Expected a new entry, got \(outcome)")
        }
        XCTAssertEqual(result.transcript.transcript.language.code, "en")
        XCTAssertFalse(try store.search("notebooks").isEmpty)
        XCTAssertTrue(try store.integrityReport().isHealthy)

        // Identification restricted to the speaker's languages.
        try store.setLanguageProfile(["fr", "en"])
        let detected = try await pipeline.transcribe(audio, language: nil)
        XCTAssertEqual(detected.language.code, "en")
        XCTAssertNotEqual(detected.language.source, .fallback)

        // A glossary prompt must never cost speech (WhisperKit's first-token early stop used to empty windows).
        try store.addGlossaryTerms(["Amira", "Friday", "notebooks"])
        let prompted = try await pipeline.transcribe(audio, language: "en")
        XCTAssertEqual(prompted.provenance.settings["glossary_terms"], "3")
        XCTAssertNotEqual(prompted.provenance.settings["prompt_tokens"], "0")
        XCTAssertEqual(prompted.provenance.settings["word_timestamps"], "false")
        let speechSeconds = try AudioFileInfo.duration(of: audio)
        XCTAssertTrue(prompted.segments.allSatisfy { $0.start < speechSeconds }, "Prompted segments must stay inside the recording")
        let promptedErrorRate = ErrorRate.wordErrors(reference: sentence, hypothesis: prompted.text).rate ?? 1
        XCTAssertLessThan(promptedErrorRate, 0.35, "Hypothesis with glossary: \(prompted.text)")

        // Ingesting the same file again is recognised as a duplicate.
        let again = try await pipeline.ingest(audio)
        guard case .duplicate(let entryID) = again else {
            return XCTFail("Expected a duplicate, got \(again)")
        }
        XCTAssertEqual(entryID, result.entry.id)
    }
}
