import Foundation

/// A named choice of Whisper model.
public struct ModelProfile: Equatable, Sendable {
    public var name: String
    /// WhisperKit model variant: the folder suffix in huggingface.co/argmaxinc/whisperkit-coreml.
    public var variant: String
    public var approximateDownloadSize: String
    public var summary: String

    public init(name: String, variant: String, approximateDownloadSize: String, summary: String) {
        self.name = name
        self.variant = variant
        self.approximateDownloadSize = approximateDownloadSize
        self.summary = summary
    }

    /// Whisper large-v3 with its full 32-layer decoder: kept for difficult recordings.
    public static let accurate = ModelProfile(
        name: "accurate",
        variant: "large-v3",
        approximateDownloadSize: "about 3 GB",
        summary: "Whisper large-v3, full 32-layer decoder. 3–5× slower than turbo; try it on recordings turbo finds hard."
    )

    /// Compressed large-v3 turbo: the same encoder with a 4-layer decoder. Measured on this project's accent set,
    /// it matched large-v3 (1.1 % WER) at 3.6× (English) to 5.1× (French) the speed on long recordings.
    public static let fast = ModelProfile(
        name: "fast",
        variant: "large-v3-v20240930_626MB",
        approximateDownloadSize: "about 626 MB",
        summary: "Whisper large-v3 turbo (4-layer decoder), compressed. Same accuracy as large-v3 on the accent test, 3–5× faster."
    )

    /// Whisper small, compressed: for iPhones with less memory. Noticeably less accurate than turbo; not part of the
    /// evaluated profiles.
    public static let compact = ModelProfile(
        name: "compact",
        variant: "small_216MB",
        approximateDownloadSize: "about 216 MB",
        summary: "Whisper small, compressed. For iPhones with less memory; less accurate than fast."
    )

    public static let builtIn: [ModelProfile] = [fast, accurate]
    /// The choices offered by the iPhone app: large-v3 (about 3 GB) needs more memory than an iPhone gives an app.
    public static let phone: [ModelProfile] = [fast, compact]
    public static let defaultProfile = fast

    /// A built-in profile by name ("accurate", "fast"), or any WhisperKit variant name ("small", "large-v3_turbo").
    public static func resolve(_ name: String) -> ModelProfile {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = (builtIn + [compact]).first(where: { $0.name == key.lowercased() || $0.variant == key }) {
            return match
        }
        return ModelProfile(
            name: key,
            variant: key,
            approximateDownloadSize: "size unknown",
            summary: "Custom WhisperKit model variant."
        )
    }

    /// English-only variants (".en") cannot identify or transcribe other languages.
    public var isMultilingual: Bool {
        !variant.lowercased().contains(".en")
    }
}
