import Foundation

/// Normalisation applied to both reference and hypothesis before computing error rates,
/// so that casing, punctuation and annotation style do not count as recognition errors.
public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        // Compatibility decomposition + composition folds full-width forms and ligatures.
        var value = text.precomposedStringWithCompatibilityMapping.lowercased()
        // Annotations such as [noise], (laughs) and <unk> are not speech.
        value = value.replacingOccurrences(of: "\\[[^\\]]*\\]|\\([^)]*\\)|<[^>]*>", with: " ", options: .regularExpression)
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x27, 0x2019:
                // Apostrophes join contractions and elisions: "don't" → "dont", "l'homme" → "lhomme".
                continue
            default:
                break
            }
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol, .control:
                scalars.append(" ")
            default:
                // Letters, digits and combining marks (vowel signs, harakat, tone marks) are kept.
                scalars.append(scalar)
            }
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
