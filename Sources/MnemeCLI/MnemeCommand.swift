import ArgumentParser
import Foundation
import MnemeCore
import MnemeSpeech

@main
struct MnemeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mneme",
        abstract: "A private, on-device voice archive with accent-robust transcription.",
        discussion: """
            Audio, transcripts and models stay on this Mac. The network is used only to download a \
            speech model, and only when you ask for it (`mneme models download` or --allow-download).
            """,
        version: "0.1.0",
        subcommands: [
            IngestCommand.self,
            TranscribeCommand.self,
            ListCommand.self,
            ShowCommand.self,
            SearchCommand.self,
            CorrectCommand.self,
            NoteCommand.self,
            DeleteCommand.self,
            GlossaryCommand.self,
            LanguagesCommand.self,
            ModelsCommand.self,
            EvalCommand.self,
            PrepareEvalCommand.self,
            ExportVerifiedCommand.self,
            VerifyCommand.self,
            PathsCommand.self,
        ]
    )
}

/// Where the archive lives.
struct ArchiveOptions: ParsableArguments {
    @Option(name: .customLong("archive"), help: "Archive folder (default: ~/Library/Application Support/Mneme/Archive).")
    var archivePath: String?

    var root: URL {
        archivePath.map { URL(fileURLWithPath: Paths.expand($0), isDirectory: true) } ?? ArchiveStore.defaultRoot
    }

    func open() throws -> ArchiveStore {
        try ArchiveStore(root: root)
    }
}

/// Which speech model to use, and whether it may be downloaded.
struct ModelOptions: ParsableArguments {
    @Option(
        name: .customLong("model"),
        help: "accurate (Whisper large-v3, about 3 GB, default), fast (large-v3 turbo, 626 MB) or a WhisperKit variant."
    )
    var model: String = ModelProfile.defaultProfile.name

    @Option(name: .customLong("models-dir"), help: "Model folder (default: ~/Library/Application Support/Mneme/Models).")
    var modelsPath: String?

    @Flag(name: .customLong("allow-download"), help: "Download the model from huggingface.co if it is not prepared on this Mac.")
    var allowDownload = false

    var profile: ModelProfile {
        ModelProfile.resolve(model)
    }

    var modelsDirectory: URL {
        modelsPath.map { URL(fileURLWithPath: Paths.expand($0), isDirectory: true) } ?? ModelLocator.defaultModelsDirectory
    }

    func makeEngine() -> WhisperEngine {
        WhisperEngine(profile: profile, modelsDirectory: modelsDirectory)
    }

    /// Fails early, before any work, when the model is missing and downloading was not allowed.
    func requireModel(_ engine: WhisperEngine) throws {
        if !allowDownload && !engine.isReady {
            throw SpeechError.modelNotDownloaded(variant: profile.variant, size: profile.approximateDownloadSize)
        }
    }
}

enum Paths {
    static func expand(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }

    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: expand(path))
    }
}

enum Console {
    /// Results go to standard output.
    static func out(_ text: String = "") {
        print(text)
    }

    /// Progress and diagnostics go to standard error, so standard output stays clean for --json.
    static func status(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    static func loadingMessage(for profile: ModelProfile, allowDownload: Bool, isReady: Bool) -> String {
        if !isReady && allowDownload {
            return "Downloading and loading \(profile.variant) (\(profile.approximateDownloadSize) from huggingface.co). "
                + "The first load can take several minutes while Core ML prepares the model for this Mac."
        }
        return "Loading \(profile.variant)..."
    }
}

/// Download progress on one line of standard error.
final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private let label: String

    init(label: String) {
        self.label = label
    }

    func update(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let percent = min(100, max(0, Int((fraction * 100).rounded(.down))))
        lock.lock()
        defer { lock.unlock() }
        guard percent != lastPercent else { return }
        lastPercent = percent
        FileHandle.standardError.write(Data("\r\(label) \(percent)%".utf8))
    }

    func finish() {
        FileHandle.standardError.write(Data("\n".utf8))
    }
}

enum DateParsing {
    /// Accepts ISO 8601 with a time zone, local date-times ("2026-11-07 09:30") and dates ("2026-11-07").
    static func parse(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: value) {
                return date
            }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: value) {
                return date
            }
        }
        return nil
    }
}
