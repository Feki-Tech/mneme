import Foundation
import XCTest
@testable import MnemeCore

final class LanguagePolicyTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(LanguagePolicy.normalize("<|en|>"), "en")
        XCTAssertEqual(LanguagePolicy.normalize("pt-BR"), "pt")
        XCTAssertEqual(LanguagePolicy.normalize("zh_Hans"), "zh")
        XCTAssertEqual(LanguagePolicy.normalize(" FR "), "fr")
    }

    func testWhisperLanguageTable() {
        XCTAssertEqual(WhisperLanguages.names.count, 100)
        XCTAssertEqual(Set(WhisperLanguages.names.values).count, 100, "Language names must be unique")
        for code in WhisperLanguages.aliases.values {
            XCTAssertNotNil(WhisperLanguages.names[code], "Alias target \(code) is not a Whisper language")
        }
        for code in WhisperLanguages.alternativeNames.values {
            XCTAssertNotNil(WhisperLanguages.names[code], "Name target \(code) is not a Whisper language")
        }
    }

    func testResolveCodesNamesAndAliases() {
        XCTAssertEqual(LanguagePolicy.resolve("French"), "fr")
        XCTAssertEqual(LanguagePolicy.resolve("fra"), "fr")
        XCTAssertEqual(LanguagePolicy.resolve("en-GB"), "en")
        XCTAssertEqual(LanguagePolicy.resolve("<|ar|>"), "ar")
        XCTAssertEqual(LanguagePolicy.resolve("Haitian Creole"), "ht")
        XCTAssertEqual(LanguagePolicy.resolve("Cantonese"), "yue")
        XCTAssertEqual(LanguagePolicy.resolve("jv"), "jw")
        XCTAssertEqual(LanguagePolicy.resolve("nb"), "no")
        XCTAssertEqual(LanguagePolicy.resolve("Farsi"), "fa")
        XCTAssertNil(LanguagePolicy.resolve("xx"))
        XCTAssertNil(LanguagePolicy.resolve(""))
    }

    func testValidatedListKeepsOrderAndRemovesDuplicates() throws {
        XCTAssertEqual(try LanguagePolicy.validatedList(["ar", "French", "fr-CA", "en"]), ["ar", "fr", "en"])
        XCTAssertThrowsError(try LanguagePolicy.validatedList(["en", "nope"]))
        XCTAssertEqual(LanguagePolicy.parseList("en, fr;ar  de"), ["en", "fr", "ar", "de"])
    }

    func testForcedLanguageWins() {
        let decision = LanguagePolicy.decide(forced: "fr", probabilities: ["en": 0.9, "fr": 0.1], allowed: ["en"])
        XCTAssertEqual(decision, LanguageDecision(code: "fr", probability: nil, source: .forced))
    }

    func testSingleLanguageProfileSkipsDetection() {
        XCTAssertEqual(
            LanguagePolicy.decide(forced: nil, probabilities: nil, allowed: ["ar"]),
            LanguageDecision(code: "ar", source: .profile)
        )
    }

    func testProfileOverridesAMisidentifiedAccent() throws {
        // English with a strong accent, identified as Hindi by the model; the speaker uses English and French.
        let decision = try XCTUnwrap(LanguagePolicy.decide(
            forced: nil,
            probabilities: ["<|hi|>": 0.55, "<|en|>": 0.30, "<|fr|>": 0.05, "<|ur|>": 0.10],
            allowed: ["en", "fr"]
        ))
        XCTAssertEqual(decision.code, "en")
        XCTAssertEqual(decision.source, .constrained)
        XCTAssertEqual(decision.modelTopCode, "hi")
        XCTAssertEqual(decision.probability ?? 0, 0.30 / 0.35, accuracy: 1e-9)
    }

    func testDetectedWhenTheModelAgreesWithTheProfile() throws {
        let decision = try XCTUnwrap(LanguagePolicy.decide(forced: nil, probabilities: ["fr": 0.8, "en": 0.2], allowed: ["en", "fr"]))
        XCTAssertEqual(decision.code, "fr")
        XCTAssertEqual(decision.source, .detected)
        XCTAssertEqual(decision.probability ?? 0, 0.8, accuracy: 1e-9)
    }

    func testUnconstrainedDetection() throws {
        let decision = try XCTUnwrap(LanguagePolicy.decide(forced: nil, probabilities: ["de": 0.7, "nl": 0.3], allowed: []))
        XCTAssertEqual(decision.code, "de")
        XCTAssertEqual(decision.source, .detected)
        XCTAssertEqual(decision.probability ?? 0, 0.7, accuracy: 1e-9)
    }

    func testLogProbabilitiesAreAccepted() throws {
        let decision = try XCTUnwrap(LanguagePolicy.decide(forced: nil, probabilities: ["en": log(0.2), "fr": log(0.8)], allowed: []))
        XCTAssertEqual(decision.code, "fr")
        XCTAssertEqual(decision.probability ?? 0, 0.8, accuracy: 1e-9)
    }

    func testTiesAreBrokenDeterministically() {
        XCTAssertEqual(LanguagePolicy.decide(forced: nil, probabilities: ["en": 0.5, "fr": 0.5], allowed: ["fr", "en"])?.code, "fr")
        XCTAssertEqual(LanguagePolicy.decide(forced: nil, probabilities: ["fr": 0.5, "en": 0.5], allowed: [])?.code, "en")
    }

    func testFallbacksWithoutUsableScores() {
        XCTAssertNil(LanguagePolicy.decide(forced: nil, probabilities: nil, allowed: []))
        XCTAssertEqual(
            LanguagePolicy.decide(forced: nil, probabilities: nil, allowed: ["en", "fr"]),
            LanguageDecision(code: "en", source: .fallback)
        )
        XCTAssertEqual(
            LanguagePolicy.decide(forced: nil, probabilities: ["de": 1.0], allowed: ["en", "fr"]),
            LanguageDecision(code: "en", probability: nil, source: .fallback, modelTopCode: "de")
        )
        XCTAssertNil(LanguagePolicy.decide(forced: nil, probabilities: ["en": .nan], allowed: []))
    }
}
