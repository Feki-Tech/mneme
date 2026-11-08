import Foundation

public enum EntryKind: String, Codable, Sendable {
    case voice
    case text
    case video
}

public struct EntryRecord: Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var recordedAt: Date
    public var title: String?
    public var kind: EntryKind
    public var language: String?
}

public struct AssetRecord: Equatable, Sendable {
    public var id: String
    public var entryID: String
    public var sha256: String
    public var mediaType: String
    public var originalFilename: String?
    public var byteSize: Int64
    public var durationSeconds: Double?
    /// Path of the immutable original, relative to the archive root.
    public var blobPath: String
    public var importedAt: Date
}

public struct TranscriptRecord: Equatable, Sendable {
    public var id: String
    public var assetID: String
    public var version: Int
    public var isCurrent: Bool
    public var createdAt: Date
    public var transcript: Transcript
}

/// One version of a written note. Editing a note adds a version; earlier versions are kept.
public struct NoteRecord: Equatable, Sendable {
    public var id: String
    public var entryID: String
    public var version: Int
    public var isCurrent: Bool
    public var createdAt: Date
    public var body: String
}

public struct EntrySummary: Identifiable, Sendable {
    public var entry: EntryRecord
    public var durationSeconds: Double?
    public var transcriptVersion: Int?
    public var preview: String
    public var flaggedSegments: Int

    public var id: String { entry.id }

    /// A voice entry whose recording is archived but not transcribed yet.
    public var needsTranscription: Bool {
        entry.kind == .voice && transcriptVersion == nil
    }
}

public struct EntryDetails: Sendable {
    public var entry: EntryRecord
    public var asset: AssetRecord?
    public var transcript: TranscriptRecord?
    /// All transcript versions of the recording, oldest first.
    public var versions: [Int]
    public var audioURL: URL?
    /// The note of a written entry (the requested or current version).
    public var note: NoteRecord?
    /// All versions of the note, oldest first.
    public var noteVersions: [Int] = []
}

public struct SearchHit: Identifiable, Sendable {
    public enum Source: String, Sendable {
        /// A segment of a current transcript.
        case transcript
        /// The current version of a written note.
        case note
        /// The entry's title.
        case title
    }

    public var entryID: String
    public var kind: EntryKind
    public var title: String?
    public var recordedAt: Date
    public var source: Source
    /// Set for transcript hits.
    public var segmentIndex: Int?
    public var start: Double?
    public var end: Double?
    public var snippet: String

    public var id: String {
        "\(entryID)|\(source.rawValue)|\(segmentIndex ?? -1)"
    }
}

/// A transcript segment the decoder was unsure about, waiting for the user's review.
public struct FlaggedSegment: Identifiable, Sendable {
    public var entryID: String
    public var title: String?
    public var recordedAt: Date
    public var transcriptVersion: Int
    public var segmentIndex: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var flags: Set<QualityFlag>
    public var audioURL: URL

    public var id: String {
        "\(entryID)#\(segmentIndex)"
    }
}

public struct IngestResult: Sendable {
    public var entry: EntryRecord
    public var asset: AssetRecord
    public var transcript: TranscriptRecord
    public var sanitization: SanitizationReport
}

public struct CorrectionResult: Sendable {
    public var transcript: TranscriptRecord
    /// New names or terms in the corrected text that are not in the glossary yet.
    public var glossarySuggestions: [String]
}
