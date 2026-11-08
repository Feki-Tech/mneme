import Foundation

/// Language codes, and the speaker's language profile as a constraint on language identification.
///
/// Accented speech is often misidentified as another language (a strong Tunisian accent in French
/// detected as Arabic, Indian English detected as Hindi), and the whole recording is then decoded in
/// the wrong language. Restricting identification to the languages the speaker actually uses removes
/// that failure mode while keeping automatic detection between those languages.
public enum LanguagePolicy {
    /// Lowercase primary subtag without Whisper's token brackets: "<|en|>" → "en", "pt-BR" → "pt".
    public static func normalize(_ code: String) -> String {
        var value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<|") { value.removeFirst(2) }
        if value.hasSuffix("|>") { value.removeLast(2) }
        let primary = value.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return primary.lowercased()
    }

    /// Resolves a code or language name to the code Whisper uses, or nil when Whisper does not support it.
    /// Accepts "fr", "fr-CA", "fra", "French", "<|fr|>".
    public static func resolve(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("<|") { value.removeFirst(2) }
        if value.hasSuffix("|>") { value.removeLast(2) }
        guard !value.isEmpty else { return nil }
        if let code = codeByName[value] { return code }
        let primary = value.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? value
        if WhisperLanguages.names[primary] != nil { return primary }
        return WhisperLanguages.aliases[primary]
    }

    /// Same as `resolve`; named for call sites that validate stored or external values.
    public static func validatedCode(_ code: String) -> String? {
        resolve(code)
    }

    /// Splits "en, fr ar" into ["en", "fr", "ar"].
    public static func parseList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Resolves every item, removing duplicates and keeping the order (the first language is the default).
    public static func validatedList(_ items: [String]) throws -> [String] {
        var result: [String] = []
        for item in items {
            guard let code = resolve(item) else {
                throw ArchiveError.invalidLanguageCode(item)
            }
            if !result.contains(code) {
                result.append(code)
            }
        }
        return result
    }

    /// Chooses the transcription language.
    ///
    /// - Parameters:
    ///   - forced: an explicit language (command-line flag or evaluation manifest); it always wins.
    ///   - probabilities: the model's language-identification scores, as probabilities or log-probabilities;
    ///     nil when identification did not run.
    ///   - allowed: the speaker's language profile in priority order; empty means unconstrained.
    /// - Returns: the decision, or nil when the decoder should identify the language itself.
    public static func decide(forced: String?, probabilities: [String: Double]?, allowed: [String]) -> LanguageDecision? {
        if let forced {
            return LanguageDecision(code: normalize(forced), probability: nil, source: .forced)
        }
        let profile = allowed.map(normalize).filter { !$0.isEmpty }
        if profile.count == 1 {
            return LanguageDecision(code: profile[0], probability: nil, source: .profile)
        }
        let scores = normalizedScores(probabilities ?? [:])
        let ranked = scores.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        guard let top = ranked.first else {
            guard let first = profile.first else { return nil }
            return LanguageDecision(code: first, probability: nil, source: .fallback)
        }
        guard !profile.isEmpty else {
            return LanguageDecision(code: top.key, probability: top.value, source: .detected, modelTopCode: top.key)
        }
        let candidates = profile.map { (code: $0, score: scores[$0] ?? 0) }
        let total = candidates.reduce(0.0) { $0 + $1.score }
        guard total > 0 else {
            return LanguageDecision(code: profile[0], probability: nil, source: .fallback, modelTopCode: top.key)
        }
        // Highest score wins; ties go to the language listed first in the profile.
        var best = candidates[0]
        for candidate in candidates.dropFirst() where candidate.score > best.score {
            best = candidate
        }
        return LanguageDecision(
            code: best.code,
            probability: best.score / total,
            source: best.code == top.key ? .detected : .constrained,
            modelTopCode: top.key
        )
    }

    /// Converts raw scores to probabilities that sum to 1. Negative values mean log-probabilities.
    static func normalizedScores(_ raw: [String: Double]) -> [String: Double] {
        let logarithmic = raw.values.contains { $0 < 0 }
        var merged: [String: Double] = [:]
        for (key, value) in raw {
            guard value.isFinite || (logarithmic && value == -.infinity) else { continue }
            let code = normalize(key)
            guard !code.isEmpty else { continue }
            let probability = logarithmic ? exp(value) : max(0, value)
            merged[code] = max(merged[code] ?? 0, probability)
        }
        let total = merged.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return merged.mapValues { $0 / total }
    }

    private static let codeByName: [String: String] = {
        var table: [String: String] = [:]
        for (code, name) in WhisperLanguages.names {
            table[name] = code
        }
        for (name, code) in WhisperLanguages.alternativeNames {
            table[name] = code
        }
        return table
    }()
}
