import Foundation
import MnemeCore

/// Audio file → prepared audio → on-device transcript → validated archive entry.
public final class IngestPipeline {
    public enum Outcome {
        case created(IngestResult)
        case duplicate(entryID: String)
        case retranscribed(entryID: String, record: TranscriptRecord, report: SanitizationReport)
    }

    public let archive: ArchiveStore
    public let engine: WhisperEngine
    public var allowDownload: Bool
    /// Called once, just before the model is loaded (loading can take minutes the first time).
    public var willLoadModel: ((ModelProfile) -> Void)?

    public init(archive: ArchiveStore, engine: WhisperEngine, allowDownload: Bool = false) {
        self.archive = archive
        self.engine = engine
        self.allowDownload = allowDownload
    }

    public func ingest(
        _ url: URL,
        title: String? = nil,
        recordedAt: Date? = nil,
        language: String? = nil,
        retranscribe: Bool = false
    ) async throws -> Outcome {
        let audio = try AudioPreparer.prepare(url)
        if let existing = try archive.asset(sha256: audio.sha256) {
            guard retranscribe else {
                return .duplicate(entryID: existing.entryID)
            }
            // Transcribe the archived original, which is byte-identical to the given file.
            let transcript = try await transcribe(archive.audioURL(for: existing), language: language)
            let added = try archive.addTranscriptVersion(assetID: existing.id, transcript: transcript)
            return .retranscribed(entryID: existing.entryID, record: added.record, report: added.report)
        }
        let transcript = try await transcribe(audio.url, language: language)
        let result = try archive.ingestVoice(audio, transcript: transcript, title: title, recordedAt: recordedAt)
        return .created(result)
    }

    /// Transcribes an archived recording, for example one saved before the model was ready, as a new version.
    @discardableResult
    public func transcribeEntry(_ entryID: String, language: String? = nil) async throws -> (record: TranscriptRecord, report: SanitizationReport) {
        guard let recording = try archive.assets(entryID: entryID).first else {
            throw ArchiveError.notFound("a recording for entry \(entryID)")
        }
        let transcript = try await transcribe(archive.audioURL(for: recording), language: language)
        return try archive.addTranscriptVersion(assetID: recording.id, transcript: transcript)
    }

    /// Transcribes with the archive's language profile and glossary.
    public func transcribe(_ url: URL, language: String?) async throws -> Transcript {
        if !engine.isLoaded {
            willLoadModel?(engine.profile)
            try await engine.load(allowDownload: allowDownload)
        }
        let profile = try archive.languageProfile()
        let glossary = try archive.glossary()
        let request = TranscriptionRequest(
            audioURL: url,
            forcedLanguage: language,
            languageProfile: profile,
            glossary: glossary
        )
        return try await engine.transcribe(request)
    }
}
