import Foundation

/// An audio file that has been checked, measured and hashed, ready to be archived.
public struct PreparedAudio: Equatable, Sendable {
    public var url: URL
    public var sha256: String
    public var byteSize: Int64
    public var durationSeconds: Double
    public var mediaType: String
    /// Canonical extension used for the stored original.
    public var fileExtension: String
    public var originalFilename: String
    /// The file's creation date, used as the recording date when none is given.
    public var fileDate: Date?

    public init(
        url: URL,
        sha256: String,
        byteSize: Int64,
        durationSeconds: Double,
        mediaType: String,
        fileExtension: String,
        originalFilename: String,
        fileDate: Date?
    ) {
        self.url = url
        self.sha256 = sha256
        self.byteSize = byteSize
        self.durationSeconds = durationSeconds
        self.mediaType = mediaType
        self.fileExtension = fileExtension
        self.originalFilename = originalFilename
        self.fileDate = fileDate
    }
}

public enum AudioPreparer {
    /// Supported extensions and their media types.
    public static let supportedExtensions: [String: String] = [
        "wav": "audio/wav",
        "wave": "audio/wav",
        "m4a": "audio/mp4",
        "mp3": "audio/mpeg",
        "aif": "audio/aiff",
        "aiff": "audio/aiff",
        "caf": "audio/x-caf",
        "flac": "audio/flac",
    ]

    /// Checks that the file exists, is a supported, decodable audio file, and computes its checksum and duration.
    public static func prepare(_ url: URL) throws -> PreparedAudio {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: resolved.path) else {
            throw ArchiveError.fileNotFound(url.path)
        }
        let rawExtension = resolved.pathExtension.lowercased()
        guard let mediaType = supportedExtensions[rawExtension] else {
            throw ArchiveError.unsupportedAudioFormat(rawExtension.isEmpty ? "(none)" : rawExtension)
        }
        let attributes = try fileManager.attributesOfItem(atPath: resolved.path)
        let byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteSize > 0 else {
            throw ArchiveError.emptyFile(url.path)
        }
        let duration = try AudioFileInfo.duration(of: resolved)
        let sha256 = try FileHasher.sha256(of: resolved)
        let fileDate = (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date)
        let canonicalExtension: String
        switch rawExtension {
        case "wave": canonicalExtension = "wav"
        case "aif": canonicalExtension = "aiff"
        default: canonicalExtension = rawExtension
        }
        return PreparedAudio(
            url: resolved,
            sha256: sha256,
            byteSize: byteSize,
            durationSeconds: duration,
            mediaType: mediaType,
            fileExtension: canonicalExtension,
            originalFilename: url.lastPathComponent,
            fileDate: fileDate
        )
    }
}
