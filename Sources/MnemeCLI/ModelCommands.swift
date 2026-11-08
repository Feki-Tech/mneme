import ArgumentParser
import Foundation
import MnemeCore
import MnemeSpeech

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Speech models on this Mac.",
        subcommands: [Status.self, Download.self, Remote.self],
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
                    Console.out("  \(folder.lastPathComponent)\(ModelLocator.isReady(folder) ? "" : " (not loaded yet)")")
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
            Console.out("\(profile.variant) is ready and works offline (prepared in \(seconds) s).")
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
