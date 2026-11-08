import Foundation

/// Content-addressed store for original recordings: `blobs/<first two hex chars>/<sha256>.<ext>`.
/// Originals are written once, verified against their checksum and made read-only.
public struct BlobStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func relativePath(sha256: String, fileExtension: String) -> String {
        let suffix = fileExtension.isEmpty ? "bin" : fileExtension.lowercased()
        return "blobs/\(sha256.prefix(2))/\(sha256).\(suffix)"
    }

    public func url(forRelativePath relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Copies the file into the store. Returns `created == false` when an identical blob already exists.
    public func store(source: URL, sha256: String, fileExtension: String) throws -> (relativePath: String, created: Bool) {
        let fileManager = FileManager.default
        let relative = relativePath(sha256: sha256, fileExtension: fileExtension)
        let destination = url(forRelativePath: relative)

        if fileManager.fileExists(atPath: destination.path) {
            guard try FileHasher.sha256(of: destination) == sha256 else {
                throw ArchiveError.blobCorrupted(relative)
            }
            return (relative, false)
        }

        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Copy to a temporary name first, verify, then rename: a crash never leaves a partial blob behind.
        let temporary = directory.appendingPathComponent(".\(sha256).\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        let copied = try FileHasher.sha256(of: temporary)
        guard copied == sha256 else {
            throw ArchiveError.blobCopyMismatch(expected: sha256, actual: copied)
        }
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: temporary.path)
        try fileManager.moveItem(at: temporary, to: destination)
        return (relative, true)
    }

    /// Removes a blob that a failed write created; never used for blobs referenced by the archive.
    public func remove(relativePath: String) {
        let fileURL = url(forRelativePath: relativePath)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
