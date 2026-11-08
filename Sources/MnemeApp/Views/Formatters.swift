import Foundation
import MnemeCore

enum Formatters {
    /// "1:02:03" or "2:03".
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%ld:%02ld:%02ld", hours, minutes, secs)
        }
        return String(format: "%ld:%02ld", minutes, secs)
    }

    /// "2:03.4" for positions inside a recording.
    static func position(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let tenths = Int((seconds * 10).rounded())
        return String(format: "%ld:%02ld.%ld", tenths / 600, (tenths % 600) / 10, tenths % 10)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func languageName(_ code: String?) -> String {
        guard let code else { return "Unknown language" }
        if let name = Locale.current.localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return WhisperLanguages.name(for: code)?.capitalized ?? code
    }

    static func flagLabel(_ flag: QualityFlag) -> String {
        switch flag {
        case .lowConfidence: return "Low confidence"
        case .repetitive: return "Repetition"
        case .likelySilence: return "Possibly silence"
        case .temperatureFallback: return "Hard to decode"
        case .uncertainWords: return "Uncertain words"
        case .unreliableTiming: return "Timing estimated"
        case .userVerified: return "Verified"
        }
    }

    static func title(for entry: EntryRecord, preview: String) -> String {
        if let title = entry.title, !title.isEmpty {
            return title
        }
        if !preview.isEmpty {
            return String(preview.prefix(60))
        }
        return entry.kind == .voice ? "Voice recording" : "Note"
    }
}
