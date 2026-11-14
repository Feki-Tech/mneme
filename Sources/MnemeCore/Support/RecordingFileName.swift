import Foundation

/// File names that carry a recording's date and title, so a recording keeps both when it moves between devices
/// (AirDrop, Files and e-mail reset file dates).
///
/// Mneme writes "20261114-050812 Morning walk.m4a" when it exports a recording, and its working files are named
/// "recording-20261114-050812-a1b2c3d4.caf". Both are read back by `parse(_:)`. Dates are local time.
public enum RecordingFileName {
    /// "20261114-050812 Morning walk.m4a"; without a title, "20261114-050812.m4a". Characters that are not allowed
    /// in file names on macOS, iOS or Windows are replaced.
    public static func make(date: Date, title: String?, fileExtension: String, timeZone: TimeZone = .current) -> String {
        var name = stampFormatter(timeZone).string(from: date)
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let safe = title.map { "/\\:*?\"<>|\n\r\t".contains($0) ? "-" : $0 }
            name += " " + String(String(safe).prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return name + "." + fileExtension
    }

    /// The date and title in a file name written by Mneme, or nil fields when the name does not follow the pattern.
    public static func parse(_ fileName: String, timeZone: TimeZone = .current) -> (date: Date?, title: String?) {
        let stem = (fileName as NSString).deletingPathExtension
        let pattern = #"^(?:recording-|mneme-)?(\d{8}-\d{6})(?:-[0-9a-f]{8})?(?:[ _-]+(.+))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let stampRange = Range(match.range(at: 1), in: stem) else {
            return (nil, nil)
        }
        let date = stampFormatter(timeZone).date(from: String(stem[stampRange]))
        var title: String?
        if let titleRange = Range(match.range(at: 2), in: stem) {
            let trimmed = stem[titleRange].trimmingCharacters(in: .whitespaces)
            title = trimmed.isEmpty ? nil : trimmed
        }
        return (date, title)
    }

    private static func stampFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}

/// A readable Markdown copy of an entry: title, date, language, then the transcript with timestamps (and a language
/// tag per passage when the recording switches languages), or the note's text.
public enum MarkdownExport {
    public static func document(for details: EntryDetails, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        let fallback = details.entry.kind == .voice ? "Voice recording" : "Note"
        let title = details.entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines.append("# \(title.isEmpty ? fallback : title)")
        lines.append("")
        var meta = ["Recorded \(formatter.string(from: details.entry.recordedAt))"]
        if let duration = details.asset?.durationSeconds {
            meta.append(String(format: "%.0f s", duration))
        }
        if let record = details.transcript {
            meta.append("language: \(record.transcript.language.code)")
            meta.append("transcript version \(record.version)")
        }
        lines.append("_" + meta.joined(separator: " · ") + "_")
        lines.append("")
        if let note = details.note {
            lines.append(note.body)
        } else if let transcript = details.transcript?.transcript {
            let mixed = transcript.language.source == .mixed
            for segment in transcript.segments {
                let minutes = Int(segment.start) / 60
                let seconds = Int(segment.start) % 60
                var line = String(format: "**%d:%02d**", minutes, seconds)
                if mixed {
                    line += " [\(segment.language ?? transcript.language.code)]"
                }
                line += " " + segment.text
                if segment.needsReview {
                    line += " _(unsure)_"
                }
                lines.append(line)
                lines.append("")
            }
        } else {
            lines.append("_Not transcribed yet._")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
