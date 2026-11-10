import ArgumentParser
import Foundation
import MnemeCore
import MnemeSpeech

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Speech models on this Mac.",
        subcommands: [Status.self, Download.self, Verify.self, Quality.self, Remote.self],
        defaultSubcommand: Status.self
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Show model profiles and what is installed.")

        @Option(name: .customLong("models-dir"), help: "Model folder.")
        var modelsPath: String?

        func run() throws {
            let base = modelsPath.map { URL(fileURLWithPath: Paths.expand($0), isDirectory: true) } ?? ModelLocator.defaultModelsDirectory
            Console.out("Models folder: \(base.path)")
            Console.out("")
            for profile in ModelProfile.builtIn {
                let state: String
                if ModelLocator.readyModelFolder(variant: profile.variant, base: base) != nil {
                    state = "ready (works offline)"
                } else if ModelLocator.localModelFolder(variant: profile.variant, base: base) != nil {
                    state = "downloaded, not loaded yet: run `mneme models download \(profile.name)` to finish"
                } else {
                    state = "not downloaded (\(profile.approximateDownloadSize))"
                }
                let marker = profile == ModelProfile.defaultProfile ? " (default)" : ""
                Console.out("\(Format.pad(profile.name + marker, 20)) \(profile.variant)")
                Console.out("\(Format.pad("", 20)) \(profile.summary)")
                Console.out("\(Format.pad("", 20)) \(state)")
            }
            let folders = ModelLocator.installedFolders(base: base)
            if !folders.isEmpty {
                Console.out("")
                Console.out("Installed model folders:")
                for folder in folders {
                    var line = "  \(folder.lastPathComponent)\(ModelLocator.isReady(folder) ? "" : " (not loaded yet)")"
                    if let manifest = try? ModelManifest.read(from: folder) {
                        line += "  fingerprint \(manifest.fingerprint)"
                    }
                    Console.out(line)
                }
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download",
            abstract: "Download a model from huggingface.co/argmaxinc/whisperkit-coreml and prepare it for offline use."
        )

        @Argument(help: "accurate, fast, or a WhisperKit variant name.")
        var model: String = ModelProfile.defaultProfile.name

        @Option(name: .customLong("models-dir"), help: "Model folder.")
        var modelsPath: String?

        func run() async throws {
            let profile = ModelProfile.resolve(model)
            let base = modelsPath.map { URL(fileURLWithPath: Paths.expand($0), isDirectory: true) } ?? ModelLocator.defaultModelsDirectory
            if ModelLocator.localModelFolder(variant: profile.variant, base: base) == nil {
                Console.status("Downloading \(profile.variant) (\(profile.approximateDownloadSize)) from huggingface.co/\(ModelLocator.repository)")
                Console.status("into \(base.path)")
                let printer = ProgressPrinter(label: "Downloading")
                try await WhisperEngine.download(profile: profile, modelsDirectory: base) { fraction in
                    printer.update(fraction)
                }
                printer.finish()
            } else {
                Console.status("\(profile.variant) is already downloaded.")
            }
            // Loading once caches the tokenizer and lets Core ML compile the model for this Mac;
            // afterwards the model loads without the network.
            Console.status("Preparing \(profile.variant) for this Mac. The first load can take several minutes...")
            let engine = WhisperEngine(profile: profile, modelsDirectory: base)
            let started = Date()
            try await engine.load(allowDownload: true)
            let seconds = Int(Date().timeIntervalSince(started).rounded())
            Console.out("\(profile.variant) is ready and works offline (prepared in \(seconds) s, fingerprint \(engine.modelFingerprint ?? "unknown")).")
            for problem in engine.modelIntegrityProblems {
                Console.status("warning: \(problem)")
            }
        }
    }

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Check downloaded models against their manifests (SHA-256 of every file).",
            discussion: """
                A model's manifest is written the first time the model is used; its fingerprint is recorded with \
                every transcript and evaluation. Models installed before Mneme kept manifests get one now. \
                Exits with status 1 when a model's files changed.
                """
        )

        @Argument(help: "accurate, fast, or a WhisperKit variant name (default: every installed model).")
        var model: String?

        @Option(name: .customLong("models-dir"), help: "Model folder.")
        var modelsPath: String?

        func run() throws {
            let base = modelsPath.map { URL(fileURLWithPath: Paths.expand($0), isDirectory: true) } ?? ModelLocator.defaultModelsDirectory
            var folders: [URL] = []
            if let model {
                let profile = ModelProfile.resolve(model)
                guard let folder = ModelLocator.localModelFolder(variant: profile.variant, base: base) else {
                    throw ValidationError("\(profile.variant) is not downloaded. Run `mneme models download \(profile.name)` first.")
                }
                folders = [folder]
            } else {
                folders = ModelLocator.installedFolders(base: base)
            }
            guard !folders.isEmpty else {
                Console.out("No models are installed in \(base.path).")
                return
            }
            var changed = false
            for folder in folders {
                let name = folder.lastPathComponent
                if let manifest = try ModelManifest.read(from: folder) {
                    let problems = try manifest.verify(folder: folder)
                    if problems.isEmpty {
                        Console.out("OK        \(name)  fingerprint \(manifest.fingerprint)  \(manifest.files.count) files, \(Self.size(manifest.totalBytes))")
                    } else {
                        changed = true
                        Console.out("CHANGED   \(name)  (manifest fingerprint \(manifest.fingerprint), recorded \(manifest.createdAt))")
                        for problem in problems.prefix(20) {
                            Console.out("          \(problem)")
                        }
                        Console.out("          Download the model again to restore it.")
                    }
                } else {
                    let manifest = try ModelLocator.ensureManifest(folder: folder, variant: ModelLocator.variant(forFolder: folder))
                    Console.out("RECORDED  \(name)  fingerprint \(manifest.fingerprint)  \(manifest.files.count) files, \(Self.size(manifest.totalBytes))")
                }
            }
            if changed {
                throw ExitCode(1)
            }
        }

        static func size(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    struct Quality: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "quality",
            abstract: "How each model has done on your recordings: speed, uncertain passages and your corrections.",
            discussion: """
                Computed on this Mac from the archive; nothing is sent anywhere. Rows are grouped by model and by \
                the fingerprint of its files, so a changed model shows up as a new row. Transcripts made before \
                Mneme recorded fingerprints are grouped as "unknown".
                """
        )

        @Flag(name: .customLong("json"), help: "Machine-readable output.")
        var json = false

        @OptionGroup var archive: ArchiveOptions

        func run() throws {
            let rows = try archive.open().modelQuality()
            if json {
                try Console.json(rows)
                return
            }
            guard !rows.isEmpty else {
                Console.out("No transcribed recordings yet.")
                return
            }
            Console.out("\(Format.pad("Model", 42)) \(Format.pad("Fingerprint", 13)) \(Format.pad("Recordings", 11)) \(Format.pad("Audio", 9)) \(Format.pad("Speed", 7)) \(Format.pad("Uncertain", 10)) Reviewed")
            for row in rows {
                let speed = row.realTimeFactor.map { String(format: "%.2f", $0) } ?? "–"
                Console.out([
                    Format.pad(row.modelID, 42),
                    Format.pad(row.fingerprint, 13),
                    Format.pad(String(row.transcripts), 11),
                    Format.pad(Format.duration(row.audioSeconds), 9),
                    Format.pad(speed, 7),
                    Format.pad(EvalReporter.percent(row.flaggedShare), 10),
                    EvalReporter.percent(row.reviewedShare),
                ].joined(separator: " "))
            }
            Console.out("")
            Console.out("Speed: processing time / audio time (below 1 is faster than real time). Uncertain: share of passages")
            Console.out("flagged when transcribed. Reviewed: share of recordings in which you corrected or confirmed a passage.")
        }
    }

    struct Remote: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remote",
            abstract: "List the model variants published by Argmax (uses the network)."
        )

        func run() async throws {
            let variants = try await WhisperEngine.availableRemoteModels()
            Console.out(variants.sorted().joined(separator: "\n"))
        }
    }
}
