import Foundation

/// How a recording is divided for language identification when the speaker uses several languages.
///
/// Whisper conditions every window on one language token. When the speaker switches language and the window
/// carries the wrong token, Whisper tends to translate the speech into that language instead of transcribing
/// it, so the unit that gets its own language decides which switches are followed.
public enum LanguageStrategy: String, CaseIterable, Codable, Sendable {
    /// One language for the whole recording, identified on its first 30 seconds (the original behaviour).
    case recording
    /// One language per window of up to 30 seconds.
    case window
    /// One language per stretch of speech between pauses, about one sentence: follows switches from one
    /// sentence to the next, at the cost of more windows to decode.
    case sentence
}
