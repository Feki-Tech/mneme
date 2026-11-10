import CryptoKit
import Foundation

/// A complete record of one evaluation run: what was measured, with which model files and decoding settings, on
/// which data, by which version of Mneme, on which machine. `mneme eval` writes it as report.json; the reports
/// committed in Evaluation/baselines/ are what `mneme eval --gate` compares new runs against.
///
/// Every field that can change a number is recorded, so a comparison between two reports either holds or says
/// why it does not (another model, other data, other settings).
public struct EvalRunReport: Codable, Equatable, Sendable {
    public struct Model: Codable, Equatable, Sendable {
        /// Profile name, for example "fast".
        public var profile: String
        /// WhisperKit variant, for example "large-v3-v20240930_626MB".
        public var variant: String
        /// `ModelManifest` fingerprint of the model files; nil when they could not be identified.
        public var fingerprint: String?

        public init(profile: String, variant: String, fingerprint: String?) {
            self.profile = profile
            self.variant = variant
            self.fingerprint = fingerprint
        }
    }

    public struct Decoding: Codable, Equatable, Sendable {
        /// "reference" (decode in the reference language) or "detect" (identify the language first).
        public var languageMode: String
        public var languageStrategy: String
        public var languageProfile: [String]
        public var glossaryTerms: Int

        public init(languageMode: String, languageStrategy: String, languageProfile: [String], glossaryTerms: Int) {
            self.languageMode = languageMode
            self.languageStrategy = languageStrategy
            self.languageProfile = languageProfile
            self.glossaryTerms = glossaryTerms
        }
    }

    public struct Dataset: Codable, Equatable, Sendable {
        public var name: String
        public var items: Int
        /// See `EvalDataset.fingerprint(_:)`: two runs measured the same data only when their fingerprints match.
        public var fingerprint: String

        public init(name: String, items: Int, fingerprint: String) {
            self.name = name
            self.items = items
            self.fingerprint = fingerprint
        }
    }

    public static let currentSchema = 1

    public var schemaVersion: Int
    public var mnemeVersion: String
    public var started: String
    public var durationSeconds: Double
    public var model: Model
    public var decoding: Decoding
    public var dataset: Dataset
    public var platform: PlatformInfo
    public var summary: EvalSummary

    public init(
        mnemeVersion: String = MnemeVersion.current,
        started: Date,
        durationSeconds: Double,
        model: Model,
        decoding: Decoding,
        dataset: Dataset,
        platform: PlatformInfo = .current,
        summary: EvalSummary
    ) {
        self.schemaVersion = Self.currentSchema
        self.mnemeVersion = mnemeVersion
        self.started = Timestamps.string(started)
        self.durationSeconds = durationSeconds
        self.model = model
        self.decoding = decoding
        self.dataset = dataset
        self.platform = platform
        self.summary = summary
    }

    public static func read(from url: URL) throws -> EvalRunReport {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ArchiveError.fileNotFound(url.path)
        }
        return try JSONDecoder().decode(EvalRunReport.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum EvalDataset {
    /// The first 12 hexadecimal digits of a SHA-256 over every item: its id, reference text, language (or sequence of
    /// languages), accent, region, time slice and the SHA-256 of its audio file. Audio paths are left out, so the same
    /// files give the same fingerprint on another Mac; the order of the items does not matter.
    public static func fingerprint(_ items: [EvalItem]) -> String {
        let lines = items.map { item -> String in
            let audio = (try? FileHasher.sha256(of: URL(fileURLWithPath: item.audio))) ?? "missing"
            var fields = [
                item.id ?? "",
                item.text,
                item.language ?? "",
                item.accent ?? "",
                item.region ?? "",
                item.start.map { String($0) } ?? "",
                item.end.map { String($0) } ?? "",
                audio,
            ]
            if let languages = item.languages {
                fields.append(languages.joined(separator: "+"))
            }
            return fields.joined(separator: "\t")
        }.sorted()
        var hasher = SHA256()
        for line in lines {
            hasher.update(data: Data((line + "\n").utf8))
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// A short name for a manifest: its folder for ".../say/manifest.jsonl", otherwise the file name.
    public static func name(forManifest url: URL) -> String {
        let file = url.deletingPathExtension().lastPathComponent
        if file == "manifest" {
            let folder = url.deletingLastPathComponent().lastPathComponent
            return folder.isEmpty ? file : folder
        }
        return file
    }
}
