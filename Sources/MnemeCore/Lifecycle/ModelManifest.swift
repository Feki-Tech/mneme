import CryptoKit
import Foundation

/// The files of an installed speech model, with their sizes and SHA-256 digests.
///
/// WhisperKit downloads a model by name from the default branch of huggingface.co/argmaxinc/whisperkit-coreml, so
/// the same variant name could deliver different files over time. The manifest records what this Mac actually has:
/// it is written once, next to the model, the first time the model is used; names and sizes are checked every time
/// the model loads; and its fingerprint is stamped on every transcript and every evaluation report, so a number can
/// always be traced to the exact model files that produced it.
public struct ModelManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        /// Path relative to the model folder.
        public var path: String
        public var size: Int64
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public static let currentSchema = 1
    /// A hidden file, so that it is not one of the files it describes.
    public static let fileName = ".mneme-manifest.json"

    public var schemaVersion: Int
    public var variant: String
    /// Where the files came from, for example "huggingface.co/argmaxinc/whisperkit-coreml".
    public var source: String
    public var createdAt: String
    public var totalBytes: Int64
    /// The first 12 hexadecimal digits of a SHA-256 over every file's path, size and digest.
    public var fingerprint: String
    /// Sorted by path.
    public var files: [File]

    public init(variant: String, source: String, createdAt: Date = Date(), files: [File]) {
        let sorted = files.sorted { $0.path < $1.path }
        self.schemaVersion = Self.currentSchema
        self.variant = variant
        self.source = source
        self.createdAt = Timestamps.string(createdAt)
        self.totalBytes = sorted.reduce(0) { $0 + $1.size }
        self.fingerprint = Self.fingerprint(of: sorted)
        self.files = sorted
    }

    public static func fingerprint(of files: [File]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data("\(file.path)\t\(file.size)\t\(file.sha256)\n".utf8))
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// Hashes every regular file in `folder`. Hidden files and folders (Mneme's markers, this manifest, download
    /// caches, Finder metadata) are not part of the model and are left out.
    public static func build(folder: URL, variant: String, source: String) throws -> ModelManifest {
        let listed = try listFiles(in: folder)
        guard !listed.isEmpty else {
            throw ArchiveError.fileNotFound(folder.appendingPathComponent("<model files>").path)
        }
        let files = try listed.map { entry in
            File(path: entry.path, size: entry.size, sha256: try FileHasher.sha256(of: folder.appendingPathComponent(entry.path)))
        }
        return ModelManifest(variant: variant, source: source, files: files)
    }

    /// The manifest stored in `folder`, or nil when none has been written yet.
    public static func read(from folder: URL) throws -> ModelManifest? {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
    }

    public func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Differences in file names and sizes, found without reading any file: fast enough for every model load.
    public func quickCheck(folder: URL) -> [String] {
        guard let current = try? Self.listFiles(in: folder) else {
            return ["the model folder cannot be read"]
        }
        return Self.differences(
            expected: files.map { ($0.path, $0.size) },
            actual: current.map { ($0.path, $0.size) }
        )
    }

    /// Recomputes the digest of every file; empty when the folder holds exactly the files of the manifest.
    public func verify(folder: URL) throws -> [String] {
        let problems = quickCheck(folder: folder)
        guard problems.isEmpty else { return problems }
        var changed: [String] = []
        for file in files {
            let digest = try FileHasher.sha256(of: folder.appendingPathComponent(file.path))
            if digest != file.sha256 {
                changed.append("\(file.path): content changed")
            }
        }
        return changed
    }

    static func differences(expected: [(String, Int64)], actual: [(String, Int64)]) -> [String] {
        let expectedSizes = Dictionary(expected, uniquingKeysWith: { first, _ in first })
        let actualSizes = Dictionary(actual, uniquingKeysWith: { first, _ in first })
        var problems: [String] = []
        for (path, size) in expected.sorted(by: { $0.0 < $1.0 }) {
            guard let found = actualSizes[path] else {
                problems.append("\(path): missing")
                continue
            }
            if found != size {
                problems.append("\(path): \(size) bytes expected, \(found) found")
            }
        }
        for (path, _) in actual.sorted(by: { $0.0 < $1.0 }) where expectedSizes[path] == nil {
            problems.append("\(path): not part of the model as installed")
        }
        return problems
    }

    /// Regular files below `folder` as paths relative to it, with their sizes; hidden entries are skipped.
    static func listFiles(in folder: URL) throws -> [(path: String, size: Int64)] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(atPath: folder.path) else {
            throw ArchiveError.fileNotFound(folder.path)
        }
        var result: [(path: String, size: Int64)] = []
        while let relative = enumerator.nextObject() as? String {
            let attributes = enumerator.fileAttributes ?? [:]
            let type = attributes[.type] as? FileAttributeType
            if (relative as NSString).lastPathComponent.hasPrefix(".") {
                if type == .typeDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard type == .typeRegular else { continue }
            result.append((path: relative, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0))
        }
        return result.sorted { $0.path < $1.path }
    }
}
