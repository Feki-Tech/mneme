import Foundation

/// JSONL evaluation manifests: one `EvalItem` per line.
public enum Manifest {
    /// Reads a manifest. Relative audio paths become absolute; every line is validated.
    public static func read(_ url: URL) throws -> [EvalItem] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ArchiveError.fileNotFound(url.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ArchiveError.invalidManifest(line: 0, reason: "the file is not UTF-8 text")
        }
        let base = url.deletingLastPathComponent()
        let decoder = JSONDecoder()
        var items: [EvalItem] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var item: EvalItem
            do {
                item = try decoder.decode(EvalItem.self, from: Data(line.utf8))
            } catch {
                throw ArchiveError.invalidManifest(line: lineNumber, reason: "not a valid item (\(error))")
            }
            guard !item.audio.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ArchiveError.invalidManifest(line: lineNumber, reason: "\"audio\" is empty")
            }
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArchiveError.invalidManifest(line: lineNumber, reason: "\"text\" (the reference) is empty")
            }
            if let start = item.start, !(start.isFinite && start >= 0) {
                throw ArchiveError.invalidManifest(line: lineNumber, reason: "\"start\" must be zero or positive")
            }
            if let end = item.end, !(end.isFinite && end > (item.start ?? 0)) {
                throw ArchiveError.invalidManifest(line: lineNumber, reason: "\"end\" must be after \"start\"")
            }
            if let language = item.language {
                guard let code = LanguagePolicy.resolve(language) else {
                    throw ArchiveError.invalidManifest(line: lineNumber, reason: "unsupported language \"\(language)\"")
                }
                item.language = code
            }
            item.audio = resolve(item.audio, base: base).path
            items.append(item)
        }
        return items
    }

    /// Writes a manifest. Audio paths inside the manifest's folder are stored relative to it.
    public static func write(_ items: [EvalItem], to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let base = folder.standardizedFileURL.path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var output = ""
        for var item in items {
            item.audio = relativePath(item.audio, base: base)
            let data = try encoder.encode(item)
            output += String(decoding: data, as: UTF8.self) + "\n"
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(output.utf8).write(to: url, options: .atomic)
    }

    static func resolve(_ path: String, base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    static func relativePath(_ path: String, base: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return standardized.hasPrefix(prefix) ? String(standardized.dropFirst(prefix.count)) : standardized
    }
}
