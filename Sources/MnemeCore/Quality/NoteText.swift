import Foundation
import NaturalLanguage

/// Validation and normalisation of written notes. Unlike transcript text, line breaks and tabs are kept.
public enum NoteText {
    public static let maxCharacters = 1_000_000

    /// LF line endings, no control characters other than line breaks and tabs, NFC, no leading or trailing blank space.
    public static func clean(_ text: String) -> String {
        let unixLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in unixLines.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || scalar.properties.generalCategory != .control {
                scalars.append(scalar)
            }
        }
        return String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    /// The cleaned body, or an error when it is empty or too long.
    public static func validated(_ text: String) throws -> String {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else {
            throw ArchiveError.invalidArgument("The note is empty.")
        }
        guard cleaned.count <= maxCharacters else {
            throw ArchiveError.invalidArgument("Notes are limited to \(maxCharacters) characters.")
        }
        return cleaned
    }

    /// The note's language as a Whisper code, when Apple's on-device recogniser is confident enough.
    public static func detectLanguage(_ text: String, minimumConfidence: Double = 0.6) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.value >= minimumConfidence else {
            return nil
        }
        return LanguagePolicy.resolve(best.key.rawValue)
    }
}
