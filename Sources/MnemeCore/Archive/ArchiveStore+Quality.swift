import Foundation

/// How one speech model has done on the recordings in this archive.
///
/// Mneme sends no telemetry, so this is the monitoring that remains: computed on this Mac, from the archive, when
/// asked. The strongest signal is the user's own work: transcripts they had to correct or confirm. A model update
/// that makes recognition worse shows up as more uncertain passages and more corrections per recording, grouped by
/// the fingerprint of the model files (see `ModelManifest`).
public struct ModelQuality: Codable, Equatable, Sendable {
    public var modelID: String
    /// Fingerprint of the model files; "unknown" for transcripts made before Mneme recorded fingerprints.
    public var fingerprint: String
    public var transcripts: Int
    public var audioSeconds: Double
    /// Processing time divided by audio time, over transcripts where both are known; below 1 is faster than real time.
    public var realTimeFactor: Double?
    public var segments: Int
    /// Passages flagged as uncertain when they were transcribed.
    public var flaggedSegments: Int
    /// Machine transcripts in which the user later corrected or confirmed a passage.
    public var reviewedTranscripts: Int
    public var firstUsed: String
    public var lastUsed: String

    public var flaggedShare: Double? {
        segments > 0 ? Double(flaggedSegments) / Double(segments) : nil
    }

    public var reviewedShare: Double? {
        transcripts > 0 ? Double(reviewedTranscripts) / Double(transcripts) : nil
    }
}

extension ArchiveStore {
    /// One row per model and model fingerprint, in the order they were first used. User corrections are not machine
    /// transcripts; each corrected recording counts once, for the machine transcript the user corrected.
    public func modelQuality() throws -> [ModelQuality] {
        try database.query("""
            SELECT t.model_id,
                   COALESCE(json_extract(t.settings_json, '$.model_fingerprint'), 'unknown') AS fingerprint,
                   COUNT(*),
                   COALESCE(SUM(a.duration_s), 0),
                   SUM(CASE WHEN t.processing_s IS NOT NULL AND a.duration_s IS NOT NULL THEN t.processing_s END),
                   SUM(CASE WHEN t.processing_s IS NOT NULL AND a.duration_s IS NOT NULL THEN a.duration_s END),
                   COALESCE(SUM((SELECT COUNT(*) FROM segment s WHERE s.transcript_id = t.id)), 0),
                   COALESCE(SUM(t.flagged_segments), 0),
                   COALESCE(SUM(EXISTS (
                       SELECT 1 FROM transcript c
                       WHERE c.asset_id = t.asset_id
                         AND c.engine = ?
                         AND CAST(json_extract(c.settings_json, '$.based_on_version') AS INTEGER) = t.version
                   )), 0),
                   MIN(t.created_at),
                   MAX(t.created_at)
            FROM transcript t
            JOIN asset a ON a.id = t.asset_id
            WHERE t.engine != ?
            GROUP BY t.model_id, fingerprint
            ORDER BY MIN(t.rowid)
            """, [.text(ArchiveStore.correctionEngine), .text(ArchiveStore.correctionEngine)]) { (row: Row) -> ModelQuality in
            var speed: Double?
            if let processing = row.optionalDouble(4), let timedAudio = row.optionalDouble(5), timedAudio > 0 {
                speed = processing / timedAudio
            }
            return ModelQuality(
                modelID: row.string(0),
                fingerprint: row.string(1),
                transcripts: row.int(2),
                audioSeconds: row.double(3),
                realTimeFactor: speed,
                segments: row.int(6),
                flaggedSegments: row.int(7),
                reviewedTranscripts: row.int(8),
                firstUsed: row.string(9),
                lastUsed: row.string(10)
            )
        }
    }
}
