import Foundation
import XCTest
@testable import MnemeCore

final class MetricsTests: XCTestCase {
    func testNormalizerRemovesCasePunctuationAndAnnotations() {
        XCTAssertEqual(TextNormalizer.normalize("Hello, World! [noise] (laughs) <unk>"), "hello world")
        XCTAssertEqual(TextNormalizer.normalize("Don't stop—now."), "dont stop now")
        XCTAssertEqual(TextNormalizer.normalize("Ｆｕｌｌ　ｗｉｄｔｈ"), "full width")
        XCTAssertEqual(TextNormalizer.normalize("  "), "")
    }

    func testNormalizerKeepsCombiningMarks() {
        let hindi = "नमस्ते दुनिया"
        XCTAssertEqual(Array(TextNormalizer.normalize(hindi).unicodeScalars), Array(hindi.unicodeScalars))
        let arabic = "مَرْحَبًا بِكُمْ"
        XCTAssertEqual(Array(TextNormalizer.normalize(arabic).unicodeScalars), Array(arabic.unicodeScalars))
    }

    func testWordErrorRate() {
        let counts = ErrorRate.wordErrors(reference: "The cat sat on the mat.", hypothesis: "the cat sat on mat today")
        XCTAssertEqual(counts.referenceLength, 6)
        XCTAssertEqual(counts.errors, 2)
        XCTAssertEqual(counts.rate ?? 0, 2.0 / 6.0, accuracy: 1e-12)
    }

    func testErrorBreakdown() {
        XCTAssertEqual(
            ErrorRate.wordErrors(reference: "a b c d", hypothesis: "a x c d e"),
            EditCounts(substitutions: 1, deletions: 0, insertions: 1, referenceLength: 4)
        )
        XCTAssertEqual(
            ErrorRate.wordErrors(reference: "a b c", hypothesis: "a c"),
            EditCounts(substitutions: 0, deletions: 1, insertions: 0, referenceLength: 3)
        )
        XCTAssertEqual(ErrorRate.wordErrors(reference: "Hello, world.", hypothesis: "hello world").errors, 0)
    }

    func testEmptyInputs() {
        XCTAssertEqual(ErrorRate.wordErrors(reference: "", hypothesis: "a b"), EditCounts(insertions: 2, referenceLength: 0))
        XCTAssertNil(ErrorRate.wordErrors(reference: "", hypothesis: "a b").rate)
        XCTAssertEqual(ErrorRate.wordErrors(reference: "a b", hypothesis: "").rate, 1)
        XCTAssertEqual(ErrorRate.wordErrors(reference: "", hypothesis: ""), .zero)
    }

    func testCharacterErrorRate() {
        let counts = ErrorRate.characterErrors(reference: "kitten", hypothesis: "sitting")
        XCTAssertEqual(counts.errors, 3)
        XCTAssertEqual(counts.referenceLength, 6)
        XCTAssertEqual(ErrorRate.characterErrors(reference: "你好世界", hypothesis: "你好，世界。").errors, 0)
    }

    func testEditCountsAddUp() {
        let total = EditCounts(substitutions: 1, deletions: 2, insertions: 3, referenceLength: 10)
            + EditCounts(substitutions: 1, deletions: 0, insertions: 0, referenceLength: 5)
        XCTAssertEqual(total, EditCounts(substitutions: 2, deletions: 2, insertions: 3, referenceLength: 15))
        XCTAssertEqual(total.rate ?? 0, 7.0 / 15.0, accuracy: 1e-12)
    }
}
