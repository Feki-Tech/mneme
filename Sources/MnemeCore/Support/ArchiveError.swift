import Foundation

/// Errors raised while preparing, validating or storing archive data.
public enum ArchiveError: Error, Equatable, Sendable {
    case fileNotFound(String)
    case emptyFile(String)
    case unsupportedAudioFormat(String)
    case unreadableAudio(String, reason: String)
    case invalidTranscript(String)
    case invalidLanguageCode(String)
    case invalidManifest(line: Int, reason: String)
    case duplicateRecording(entryID: String)
    case blobCorrupted(String)
    case blobCopyMismatch(expected: String, actual: String)
    case verificationFailed(String)
    case notFound(String)
    case ambiguousIdentifier(String)
    case invalidArgument(String)
    case schemaTooNew(found: Int, supported: Int)
}

extension ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "No readable file at \(path)."
        case .emptyFile(let path):
            return "The file at \(path) is empty."
        case .unsupportedAudioFormat(let fileExtension):
            return "Unsupported audio format “\(fileExtension)”. Use wav, m4a, mp3, aiff, caf or flac."
        case .unreadableAudio(let path, let reason):
            return "Could not read audio from \(path): \(reason)"
        case .invalidTranscript(let reason):
            return "The transcript failed validation and nothing was written: \(reason)"
        case .invalidLanguageCode(let code):
            return "“\(code)” is not a valid language code. Use ISO 639 codes such as en, fr or de."
        case .invalidManifest(let line, let reason):
            return "Manifest line \(line): \(reason)"
        case .duplicateRecording(let entryID):
            return "This recording is already archived as entry \(entryID)."
        case .blobCorrupted(let path):
            return "The stored audio file \(path) no longer matches its checksum."
        case .blobCopyMismatch(let expected, let actual):
            return "The copied audio does not match the original (expected SHA-256 \(expected), got \(actual))."
        case .verificationFailed(let reason):
            return "Read-back verification failed: \(reason)"
        case .notFound(let what):
            return "Not found: \(what)."
        case .ambiguousIdentifier(let identifier):
            return "“\(identifier)” matches more than one entry; use more characters."
        case .invalidArgument(let reason):
            return reason
        case .schemaTooNew(let found, let supported):
            return "The archive uses schema version \(found), but this build supports up to \(supported). Update Mneme."
        }
    }
}
