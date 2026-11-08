import ArgumentParser
import Foundation
import MnemeCore
import MnemeSpeech

/// `LanguageStrategy` as a command-line value.
enum LanguageStrategyOption: String, CaseIterable, ExpressibleByArgument {
    case recording
    case window
    case sentence

    var strategy: LanguageStrategy {
        switch self {
        case .recording: return .recording
        case .window: return .window
        case .sentence: return .sentence
        }
    }
}

enum EvalLanguageMode: String, CaseIterable, ExpressibleByArgument {
    case reference
    case detect

    var evaluatorMode: AccentEvaluator.LanguageMode {
        switch self {
        case .reference: return .reference
        case .detect: return .detect
        }
    }
}

struct EvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Measure word and character error rates per accent on a JSONL manifest.",
        discussion: """
            Each manifest line is a JSON object: {"audio": "...", "text": "reference", "language": "en", \
            "accent": "...", "region": "...", "speaker": "...", "start": 1.5, "end": 7.25}. Only audio and \
            text are required. Build manifests with `mneme prepare-eval`, `mneme export-verified`, \
            Scripts/make-say-samples.sh or Scripts/export_hf_accent_dataset.py.
            """
    )

    @Argument(help: "Manifest (JSONL).", completion: .file(extensions: ["jsonl"]))
    var manifest: String

    @Option(
        name: .customLong("language-mode"),
        help: "reference: decode in the reference language (accent robustness alone). detect: identify the language first (also measures accents mistaken for another language)."
    )
    var languageMode: EvalLanguageMode = .reference

    @Flag(name: .customLong("use-profile"), help: "In detect mode, restrict identification to the archive's language profile.")
    var useProfile = false

    @Flag(name: .customLong("use-glossary"), help: "Pass the archive's glossary to the decoder.")
    var useGlossary = false

    @Option(
        name: .customLong("language-strategy"),
        help: "In detect mode with two or more profile languages: recording (one language per recording), window (per 30-second window) or sentence (per sentence, for speakers who switch languages)."
    )
    var languageStrategy: LanguageStrategyOption = .window

    @Option(help: "Evaluate only the first N items.")
    var limit: Int?

    @Option(name: .customLong("out"), help: "Output folder (default: ./mneme-eval/<date>-<model>).")
    var outPath: String?

    @OptionGroup var model: ModelOptions
    @OptionGroup var archive: ArchiveOptions

    func run() async throws {
        var items = try Manifest.read(Paths.url(manifest))
        if let limit {
            items = Array(items.prefix(max(0, limit)))
        }
        guard !items.isEmpty else {
            throw ValidationError("The manifest has no items.")
        }
        let engine = model.makeEngine()
        try model.requireModel(engine)
        Console.status(Console.loadingMessage(for: model.profile, allowDownload: model.allowDownload, isReady: engine.isReady))
        try await engine.load(allowDownload: model.allowDownload)

        var profile: [String] = []
        var glossary: [String] = []
        if useProfile || useGlossary {
            let store = try archive.open()
            if useProfile { profile = try store.languageProfile() }
            if useGlossary { glossary = try store.glossary() }
        }
        let evaluator = AccentEvaluator(
            engine: engine,
            languageMode: languageMode.evaluatorMode,
            languageProfile: profile,
            glossary: glossary,
            languageStrategy: languageStrategy.strategy
        )

        let outputFolder = outPath.map { Paths.url($0) } ?? Self.defaultOutputFolder(variant: model.profile.variant)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let resultsURL = outputFolder.appendingPathComponent("results.jsonl")
        FileManager.default.createFile(atPath: resultsURL.path, contents: nil)
        let resultsHandle = try FileHandle(forWritingTo: resultsURL)
        defer { try? resultsHandle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var results: [EvalResult] = []
        for (offset, item) in items.enumerated() {
            let result = await evaluator.evaluate(item)
            results.append(result)
            // Written as it goes, so an interrupted run keeps its results.
            let line = try encoder.encode(result)
            try resultsHandle.write(contentsOf: line + Data("\n".utf8))
            Console.status(Self.progressLine(result, position: offset + 1, total: items.count))
        }

        let summary = EvalReporter.summarize(results)
        let settings: [(String, String)] = [
            ("Model", "\(model.profile.name) (\(model.profile.variant))"),
            ("Language mode", languageMode.rawValue),
            ("Language strategy", languageStrategy.rawValue),
            ("Language profile", profile.isEmpty ? "none" : profile.joined(separator: ", ")),
            ("Glossary terms", String(glossary.count)),
            ("Manifest", Paths.url(manifest).lastPathComponent),
            ("Date", Timestamps.string(Timestamps.now())),
        ]
        let report = EvalReporter.markdown(summary, settings: settings)
        let summaryEncoder = JSONEncoder()
        summaryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try summaryEncoder.encode(summary).write(to: outputFolder.appendingPathComponent("summary.json"), options: .atomic)
        try Data(report.utf8).write(to: outputFolder.appendingPathComponent("report.md"), options: .atomic)
        Console.out(report)
        Console.out("Results written to \(outputFolder.path)")
    }

    static func progressLine(_ result: EvalResult, position: Int, total: Int) -> String {
        let prefix = "[\(position)/\(total)] \(result.item.label)"
        if let error = result.error {
            return "\(prefix)  FAILED: \(error)"
        }
        var line = "\(prefix)  WER \(EvalReporter.percent(result.words.rate))  CER \(EvalReporter.percent(result.characters.rate))"
        if let accent = result.item.accent {
            line += "  accent: \(accent)"
        }
        if result.languageMismatch, let detected = result.detectedLanguage {
            line += "  LANGUAGE: \(detected) instead of \(result.item.language ?? "?")"
        }
        return line
    }

    static func defaultOutputFolder(variant: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: Date()))-\(variant.replacingOccurrences(of: "/", with: "_"))"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("mneme-eval", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}

struct PrepareEvalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare-eval",
        abstract: "Build evaluation manifests from public accent datasets.",
        subcommands: [SpeechAccentArchiveCommand.self]
    )
}

struct SpeechAccentArchiveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speech-accent-archive",
        abstract: "Speech Accent Archive (Kaggle: rtatman/speech-accent-archive): 2,000+ speakers, 200+ first languages, one English paragraph.",
        discussion: "Download and unzip the Kaggle dataset first. The folder must contain speakers_all.csv, reading-passage.txt and the recordings."
    )

    @Argument(help: "Folder of the unzipped dataset.", completion: .directory)
    var dataset: String

    @Option(name: .customLong("max-per-accent"), help: "Limit speakers per first language (keeps runs short and balanced).")
    var maxPerAccent: Int?

    @Option(name: .customLong("out"), help: "Manifest to write.")
    var outPath: String = "eval/speech-accent-archive.jsonl"

    func run() throws {
        let items = try SpeechAccentArchive.manifest(datasetDirectory: Paths.url(dataset), maxPerAccent: maxPerAccent)
        let output = Paths.url(outPath)
        try Manifest.write(items, to: output)
        let accents = Set(items.compactMap { $0.accent }).count
        Console.out("Wrote \(items.count) items covering \(accents) first languages to \(output.path)")
        Console.out("Next: mneme eval \(outPath)")
    }
}

struct ExportVerifiedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-verified",
        abstract: "Export the segments you corrected or verified as an evaluation manifest: your personal accent dataset.",
        discussion: """
            Without --clips the manifest points into the archive (absolute paths with start and end times) and \
            stays on this Mac. With --clips each segment is copied into a WAV file next to the manifest, \
            making a self-contained dataset folder.
            """
    )

    @Option(name: .customLong("out"), help: "Manifest to write.")
    var outPath: String = "eval/verified/manifest.jsonl"

    @Flag(name: .customLong("clips"), help: "Copy each segment into its own WAV file.")
    var clips = false

    @OptionGroup var archive: ArchiveOptions

    func run() throws {
        var items = try archive.open().verifiedSegments()
        let output = Paths.url(outPath)
        if clips {
            let folder = output.deletingLastPathComponent().appendingPathComponent("clips", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in items.indices {
                let item = items[index]
                let name = (item.id ?? "segment-\(index)")
                    .replacingOccurrences(of: "#", with: "_")
                    .replacingOccurrences(of: "/", with: "_")
                let clip = folder.appendingPathComponent("\(name).wav")
                let source = URL(fileURLWithPath: item.audio)
                let total = try AudioFileInfo.duration(of: source)
                try AudioFileInfo.extractSegment(from: source, start: item.start ?? 0, end: item.end ?? total, to: clip)
                items[index].audio = clip.path
                items[index].start = nil
                items[index].end = nil
            }
        }
        try Manifest.write(items, to: output)
        Console.out("Wrote \(items.count) verified segments to \(output.path)")
        if items.isEmpty {
            Console.out("Correct segments with `mneme correct` to build the dataset.")
        }
    }
}
