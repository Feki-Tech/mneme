import Foundation

/// The promotion gate for changes to the speech pipeline (a new model, a WhisperKit update, a decoder change).
///
/// It follows the champion/challenger contract of Feki-Tech's other projects (ai-gym-coach's classifier gate,
/// edgesense's `promote.py`): a candidate run must clear absolute bars and, when it measured the same data as the
/// baseline, must not regress beyond a tolerance. Nothing is promoted automatically: the gate refuses, a person
/// decides. `mneme eval --gate` exits 0 when the candidate passes, 1 when it is refused and 2 on errors.
public struct EvalGate: Sendable {
    /// Highest acceptable overall word error rate.
    public var maximumWER: Double
    /// Largest acceptable increase of the overall word error rate over the baseline (absolute: 0.01 is one point).
    public var tolerance: Double
    /// Groups (accents, regions, languages) are small, so a single word flips their rate by several points: a group
    /// regresses only when it gains more than one error and more than this share of its reference words.
    public var groupTolerance: Double

    public init(maximumWER: Double = 0.10, tolerance: Double = 0.01, groupTolerance: Double = 0.04) {
        self.maximumWER = maximumWER
        self.tolerance = tolerance
        self.groupTolerance = groupTolerance
    }

    public struct Outcome: Equatable, Sendable {
        public var passed: Bool
        /// False when there was no baseline or it measured other data: only the absolute bars applied.
        public var compared: Bool
        /// Notes about the comparison, then the failures ("FAIL …") or a final "PASS …" line.
        public var lines: [String]

        public func markdown(title: String) -> String {
            var output = ["## \(title): \(passed ? "passed" : "refused")", ""]
            output += lines.map { "- \($0)" }
            return output.joined(separator: "\n") + "\n"
        }
    }

    public func evaluate(_ candidate: EvalRunReport, against baseline: EvalRunReport?) -> Outcome {
        var notes: [String] = []
        var failures: [String] = []
        let overall = candidate.summary.overall

        if overall.failed > 0 {
            failures.append("\(overall.failed) of \(overall.items) items could not be transcribed")
        }
        if let wer = overall.wer {
            if wer > maximumWER {
                failures.append("overall WER \(Self.percent(wer)) is above the bar of \(Self.percent(maximumWER))")
            }
        } else {
            failures.append("no words were measured")
        }

        var compared = false
        if let baseline {
            notes += Self.differences(candidate, baseline)
            if baseline.dataset.fingerprint != candidate.dataset.fingerprint {
                notes.append("note: other data (dataset \(baseline.dataset.fingerprint) in the baseline, "
                    + "\(candidate.dataset.fingerprint) now): no relative comparison, absolute bars only")
            } else {
                compared = true
                failures += regressions(candidate.summary, baseline.summary)
            }
        } else {
            notes.append("note: no baseline: absolute bars only")
        }

        if failures.isEmpty {
            var line = "PASS overall WER \(Self.percent(overall.wer))"
            if compared, let reference = baseline?.summary.overall.wer {
                line += " (baseline \(Self.percent(reference)))"
            }
            notes.append(line)
        } else {
            notes += failures.map { "FAIL \($0)" }
        }
        return Outcome(passed: failures.isEmpty, compared: compared, lines: notes)
    }

    func regressions(_ candidate: EvalSummary, _ baseline: EvalSummary) -> [String] {
        var failures: [String] = []
        if let current = candidate.overall.wer, let reference = baseline.overall.wer, current > reference + tolerance {
            failures.append("overall WER regressed from \(Self.percent(reference)) to \(Self.percent(current)) "
                + "(tolerance \(Self.points(tolerance)))")
        }
        if candidate.overall.languageMismatches > baseline.overall.languageMismatches {
            failures.append("items decoded in the wrong language or sequence of languages: "
                + "\(baseline.overall.languageMismatches) in the baseline, \(candidate.overall.languageMismatches) now")
        }
        let kinds: [(String, [GroupSummary], [GroupSummary])] = [
            ("accent", baseline.byAccent, candidate.byAccent),
            ("region", baseline.byRegion, candidate.byRegion),
            ("language", baseline.byLanguage, candidate.byLanguage),
        ]
        for (kind, before, after) in kinds {
            let current = Dictionary(after.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            for group in before {
                guard let now = current[group.name] else {
                    failures.append("\(kind) \"\(group.name)\" is missing from the run")
                    continue
                }
                if let failure = groupRegression(kind: kind, before: group, after: now) {
                    failures.append(failure)
                }
            }
        }
        return failures
    }

    /// Languages written without spaces are compared on characters: for them a "word" is a whole sentence.
    func groupRegression(kind: String, before: GroupSummary, after: GroupSummary) -> String? {
        let characters = Self.writtenWithoutSpaces(before.name)
        let reference = characters ? before.characters : before.words
        let current = characters ? after.characters : after.words
        let allowed = max(1, Int((groupTolerance * Double(reference.referenceLength)).rounded(.up)))
        let added = current.errors - reference.errors
        guard added > allowed else { return nil }
        let metric = characters ? "CER" : "WER"
        return "\(kind) \"\(before.name)\": \(metric) \(Self.percent(reference.rate)) to \(Self.percent(current.rate)) "
            + "(\(added) more errors, \(allowed) allowed)"
    }

    static func differences(_ candidate: EvalRunReport, _ baseline: EvalRunReport) -> [String] {
        var notes: [String] = []
        if candidate.model != baseline.model {
            notes.append("note: model differs: \(describe(baseline.model)) in the baseline, \(describe(candidate.model)) now")
        }
        if candidate.decoding != baseline.decoding {
            notes.append("note: decoding settings differ: \(describe(baseline.decoding)) in the baseline, "
                + "\(describe(candidate.decoding)) now")
        }
        if candidate.mnemeVersion != baseline.mnemeVersion {
            notes.append("note: Mneme \(baseline.mnemeVersion) made the baseline, \(candidate.mnemeVersion) this run")
        }
        if candidate.platform.os != baseline.platform.os || candidate.platform.machine != baseline.platform.machine {
            notes.append("note: other machine: \(describe(baseline.platform)) in the baseline, \(describe(candidate.platform)) now "
                + "(speed is not comparable)")
        }
        return notes
    }

    /// Chinese, Japanese, Thai, Lao, Khmer, Burmese, Cantonese and Tibetan, by language code or locale ("zh_CN").
    static func writtenWithoutSpaces(_ group: String) -> Bool {
        let lowered = group.lowercased()
        return ["zh", "ja", "th", "lo", "km", "my", "yue", "bo"].contains { code in
            lowered == code || lowered.hasPrefix(code + "_") || lowered.hasPrefix(code + "-")
        }
    }

    static func describe(_ model: EvalRunReport.Model) -> String {
        "\(model.profile) (\(model.variant), fingerprint \(model.fingerprint ?? "unknown"))"
    }

    static func describe(_ decoding: EvalRunReport.Decoding) -> String {
        let profile = decoding.languageProfile.isEmpty ? "no profile" : decoding.languageProfile.joined(separator: ",")
        return "\(decoding.languageMode)/\(decoding.languageStrategy), \(profile), \(decoding.glossaryTerms) glossary terms"
    }

    static func describe(_ platform: PlatformInfo) -> String {
        [platform.os, platform.machine].compactMap { $0 }.joined(separator: " ")
    }

    static func percent(_ value: Double?) -> String {
        EvalReporter.percent(value)
    }

    static func points(_ value: Double) -> String {
        String(format: "%.1f points", value * 100)
    }
}
