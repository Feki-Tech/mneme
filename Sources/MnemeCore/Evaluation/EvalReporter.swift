import Foundation

/// Aggregated error rates for a group of evaluation items (micro-averaged: total errors / total reference length).
public struct GroupSummary: Codable, Equatable, Sendable {
    public var name: String
    public var items: Int
    public var failed: Int
    public var words: EditCounts
    public var characters: EditCounts
    public var wer: Double?
    public var cer: Double?
    /// Items transcribed in a language other than the reference language.
    public var languageMismatches: Int
}

public struct EvalSummary: Codable, Equatable, Sendable {
    public var overall: GroupSummary
    /// Worst group first.
    public var byAccent: [GroupSummary]
    public var byRegion: [GroupSummary]
    public var byLanguage: [GroupSummary]
    /// Processing time divided by audio duration; below 1 is faster than real time.
    public var realTimeFactor: Double?
}

public enum EvalReporter {
    public static func summarize(_ results: [EvalResult]) -> EvalSummary {
        let audio = results.compactMap { $0.audioSeconds }.reduce(0, +)
        let processing = results.compactMap { $0.processingSeconds }.reduce(0, +)
        return EvalSummary(
            overall: group(name: "all", results),
            byAccent: groups(results) { $0.item.accent },
            byRegion: groups(results) { $0.item.region },
            byLanguage: groups(results) { $0.item.language },
            realTimeFactor: audio > 0 && processing > 0 ? processing / audio : nil
        )
    }

    static func groups(_ results: [EvalResult], key: (EvalResult) -> String?) -> [GroupSummary] {
        guard results.contains(where: { key($0) != nil }) else { return [] }
        var grouped: [String: [EvalResult]] = [:]
        for result in results {
            grouped[key(result) ?? "unknown", default: []].append(result)
        }
        return grouped.map { group(name: $0.key, $0.value) }.sorted(by: worstFirst)
    }

    static func group(name: String, _ results: [EvalResult]) -> GroupSummary {
        let succeeded = results.filter { $0.error == nil }
        let words = succeeded.reduce(EditCounts.zero) { $0 + $1.words }
        let characters = succeeded.reduce(EditCounts.zero) { $0 + $1.characters }
        return GroupSummary(
            name: name,
            items: results.count,
            failed: results.count - succeeded.count,
            words: words,
            characters: characters,
            wer: words.rate,
            cer: characters.rate,
            languageMismatches: succeeded.filter { $0.languageMismatch }.count
        )
    }

    static func worstFirst(_ lhs: GroupSummary, _ rhs: GroupSummary) -> Bool {
        switch (lhs.wer, rhs.wer) {
        case let (left?, right?) where left != right:
            return left > right
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        default:
            return lhs.name < rhs.name
        }
    }

    /// A Markdown report: settings, overall figures, then accents, regions and languages worst first.
    public static func markdown(_ summary: EvalSummary, title: String = "Accent evaluation", settings: [(String, String)] = []) -> String {
        var lines: [String] = ["# \(title)", ""]
        if !settings.isEmpty {
            lines.append("| Setting | Value |")
            lines.append("|---|---|")
            for (key, value) in settings {
                lines.append("| \(key) | \(escape(value)) |")
            }
            lines.append("")
        }
        let overall = summary.overall
        lines.append("## Overall")
        lines.append("")
        lines.append("| Items | Failed | WER | CER | Language errors | Real-time factor |")
        lines.append("|---:|---:|---:|---:|---:|---:|")
        let speed = summary.realTimeFactor.map { String(format: "%.2f", $0) } ?? "–"
        lines.append("| \(overall.items) | \(overall.failed) | \(percent(overall.wer)) | \(percent(overall.cer)) | \(overall.languageMismatches) | \(speed) |")
        lines.append("")
        for (heading, groups) in [("By accent", summary.byAccent), ("By region", summary.byRegion), ("By language", summary.byLanguage)]
        where !groups.isEmpty {
            lines.append("## \(heading) (worst first)")
            lines.append("")
            lines.append("| Group | Items | WER | CER | Language errors | Failed |")
            lines.append("|---|---:|---:|---:|---:|---:|")
            for group in groups {
                lines.append("| \(escape(group.name)) | \(group.items) | \(percent(group.wer)) | \(percent(group.cer)) | \(group.languageMismatches) | \(group.failed) |")
            }
            lines.append("")
        }
        lines.append("WER and CER are micro-averaged after normalisation (case, punctuation and annotations removed). ")
        lines.append("For languages written without spaces, read CER rather than WER.")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f%%", value * 100)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
