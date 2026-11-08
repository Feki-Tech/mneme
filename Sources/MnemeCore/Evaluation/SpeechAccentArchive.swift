import Foundation

/// Builds an evaluation manifest from the Speech Accent Archive (George Mason University),
/// as distributed on Kaggle: `speakers_all.csv`, `reading-passage.txt` and MP3 recordings
/// of 2,000+ speakers from 200+ language backgrounds reading the same English paragraph.
public enum SpeechAccentArchive {
    public static func manifest(
        datasetDirectory: URL,
        maxPerAccent: Int? = nil,
        passage: String? = nil
    ) throws -> [EvalItem] {
        let fileManager = FileManager.default
        let csvURL = datasetDirectory.appendingPathComponent("speakers_all.csv")
        guard fileManager.fileExists(atPath: csvURL.path) else {
            throw ArchiveError.fileNotFound(csvURL.path)
        }
        let passageText: String
        if let passage {
            passageText = passage
        } else {
            let passageURL = datasetDirectory.appendingPathComponent("reading-passage.txt")
            guard fileManager.fileExists(atPath: passageURL.path) else {
                throw ArchiveError.fileNotFound(passageURL.path)
            }
            passageText = try readText(passageURL)
        }
        let reference = passageText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !reference.isEmpty else {
            throw ArchiveError.invalidArgument("The reading passage is empty.")
        }

        let audioIndex = indexAudio(in: datasetDirectory)
        let csvText = try readText(csvURL)
        let records = CSV.records(csvText).sorted { lhs, rhs in
            (lhs["filename"] ?? "").localizedStandardCompare(rhs["filename"] ?? "") == .orderedAscending
        }

        var perAccent: [String: Int] = [:]
        var items: [EvalItem] = []
        for record in records {
            let filename = (record["filename"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filename.isEmpty else { continue }
            if (record["file_missing?"] ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "true" { continue }
            guard let audio = audioIndex[filename.lowercased()] else { continue }
            let accent = nonEmpty(record["native_language"])?.lowercased() ?? "unknown"
            if let maxPerAccent, perAccent[accent, default: 0] >= maxPerAccent { continue }
            perAccent[accent, default: 0] += 1
            items.append(EvalItem(
                id: filename,
                audio: audio.path,
                text: reference,
                language: "en",
                accent: accent,
                region: nonEmpty(record["country"])?.lowercased(),
                speaker: nonEmpty(record["speakerid"])
            ))
        }
        return items
    }

    /// Audio files anywhere under the dataset folder, keyed by lowercase name without extension.
    static func indexAudio(in directory: URL) -> [String: URL] {
        var index: [String: URL] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return index }
        for case let url as URL in enumerator {
            let fileExtension = url.pathExtension.lowercased()
            guard fileExtension == "mp3" || fileExtension == "wav" else { continue }
            let key = url.deletingPathExtension().lastPathComponent.lowercased()
            if index[key] == nil {
                index[key] = url
            }
        }
        return index
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw ArchiveError.invalidArgument("\(url.lastPathComponent) is not readable text.")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
