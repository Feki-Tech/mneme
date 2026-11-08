import Foundation
import MnemeCore

enum Format {
    /// "1:02:03" or "2:03".
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(minutes):\(twoDigits(secs))"
    }

    /// "02:03.4" for positions inside a recording.
    static func position(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--.-" }
        let tenths = Int((seconds * 10).rounded())
        let minutes = tenths / 600
        let secs = (tenths % 600) / 10
        return "\(twoDigits(minutes)):\(twoDigits(secs)).\(tenths % 10)"
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// The random tail of a UUIDv7, which is what distinguishes entries created close together.
    static func shortID(_ id: String) -> String {
        String(id.suffix(8))
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func flags(_ flags: Set<QualityFlag>) -> String {
        flags.isEmpty ? "" : "[" + flags.sorted().map(\.rawValue).joined(separator: ", ") + "]"
    }

    static func language(_ decision: LanguageDecision) -> String {
        var text = "\(decision.code) (\(decision.source.rawValue)"
        if let probability = decision.probability {
            text += String(format: ", p=%.2f", probability)
        }
        if let top = decision.modelTopCode, top != decision.code {
            text += ", model's first guess: \(top)"
        }
        return text + ")"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

struct EntryOutput: Encodable {
    var id: String
    var shortID: String
    var title: String?
    var kind: String
    var recordedAt: String
    var language: String?
    var durationSeconds: Double?
    var transcriptVersion: Int?
    var flaggedSegments: Int
    var preview: String

    init(_ summary: EntrySummary) {
        id = summary.entry.id
        shortID = Format.shortID(summary.entry.id)
        title = summary.entry.title
        kind = summary.entry.kind.rawValue
        recordedAt = Timestamps.string(summary.entry.recordedAt)
        language = summary.entry.language
        durationSeconds = summary.durationSeconds
        transcriptVersion = summary.transcriptVersion
        flaggedSegments = summary.flaggedSegments
        preview = summary.preview
    }
}

struct IngestOutput: Encodable {
    var file: String
    var outcome: String
    var entryID: String
    var transcriptVersion: Int?
    var language: String?
    var languageSource: String?
    var segments: Int?
    var flaggedSegments: Int?
    var sanitization: SanitizationReport?
    var text: String?
}

struct ShowOutput: Encodable {
    var id: String
    var title: String?
    var kind: String
    var recordedAt: String
    var createdAt: String
    var audioPath: String?
    var sha256: String?
    var durationSeconds: Double?
    var versions: [Int]
    var transcriptVersion: Int?
    var transcriptIsCurrent: Bool?
    var transcript: Transcript?
    var note: String?
    var noteVersion: Int?
    var noteVersions: [Int]?
}

struct SearchOutput: Encodable {
    var entryID: String
    var kind: String
    var source: String
    var title: String?
    var recordedAt: String
    var segment: Int?
    var start: Double?
    var end: Double?
    var snippet: String

    init(_ hit: SearchHit) {
        entryID = hit.entryID
        kind = hit.kind.rawValue
        source = hit.source.rawValue
        title = hit.title
        recordedAt = Timestamps.string(hit.recordedAt)
        segment = hit.segmentIndex
        start = hit.start
        end = hit.end
        snippet = hit.snippet
    }
}
