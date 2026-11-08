import Foundation

/// Builds the decoder prompt from the personal glossary.
///
/// Whisper conditions its output on a short text prompt. Listing the names, places and terms a speaker
/// uses makes the decoder far more likely to spell them correctly, whatever the accent.
public enum PromptBuilder {
    /// WhisperKit's decoder context holds 224 tokens, shared by the prompt and the window's transcript
    /// (and it trims prompts to 111). A short prompt leaves room for fast speech in every 30-second window.
    public static let maxPromptTokens = 64
    public static let maxCharacters = 300

    /// The glossary as a comma-separated sentence. When the glossary is long, the most recently added terms are kept.
    public static func promptText(terms: [String]) -> String? {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var selected: [String] = []
        var length = 0
        for term in cleaned.reversed() {
            let added = term.count + (selected.isEmpty ? 0 : 2)
            if length + added > maxCharacters { break }
            selected.append(term)
            length += added
        }
        guard !selected.isEmpty else { return nil }
        return selected.reversed().joined(separator: ", ") + "."
    }

    /// Keeps the last `maxPromptTokens` tokens.
    public static func limit(tokens: [Int]) -> [Int] {
        tokens.count > maxPromptTokens ? Array(tokens.suffix(maxPromptTokens)) : tokens
    }
}

/// Proposes glossary terms from a user's correction: names and terms the model got wrong.
public enum GlossarySuggester {
    /// Capitalised words and words with digits that the correction introduced and the glossary does not contain.
    public static func suggestions(original: String, corrected: String, glossary: [String]) -> [String] {
        let known = Set((tokens(original) + glossary.flatMap { tokens($0) }).map { $0.lowercased() })
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens(corrected) {
            let key = token.lowercased()
            guard !known.contains(key), !seen.contains(key), isTermLike(token) else { continue }
            seen.insert(key)
            result.append(token)
        }
        return result
    }

    static func tokens(_ text: String) -> [String] {
        let joiners = CharacterSet(charactersIn: "'’-")
        let separators = CharacterSet.alphanumerics.union(joiners).inverted
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: joiners) }
            .filter { !$0.isEmpty }
    }

    static func isTermLike(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return first.isUppercase || token.contains(where: { $0.isNumber })
    }
}
