/// Builds full-text search expressions that cannot inject FTS5 operators.
enum FTSQuery {
    /// Every word is quoted, and the last word matches as a prefix: `call ste` → `"call" "ste"*`.
    static func make(_ input: String) -> String? {
        let words = input
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).replacingOccurrences(of: "\"", with: "") }
            .filter { word in word.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !words.isEmpty else { return nil }
        var parts = words.map { "\"\($0)\"" }
        parts[parts.count - 1] += "*"
        return parts.joined(separator: " ")
    }
}
