import Foundation

/// Where WhisperKit models live on this Mac, and whether a model is complete and prepared.
///
/// WhisperKit downloads into `<base>/models/argmaxinc/whisperkit-coreml/<folder>`, where the folder
/// is usually `openai_whisper-<variant>`. After the first successful load (which also caches the
/// tokenizer), Mneme writes a marker file so later runs can load the model fully offline.
public enum ModelLocator {
    public static let repository = "argmaxinc/whisperkit-coreml"
    public static let readyMarker = ".mneme-ready"
    static let requiredComponents = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]

    public static var defaultModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Mneme/Models", isDirectory: true)
    }

    public static func repositoryDirectory(base: URL) -> URL {
        base.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repository, isDirectory: true)
    }

    /// The folder of a fully downloaded variant, preferring OpenAI's checkpoints over other folders with the same suffix.
    public static func localModelFolder(variant: String, base: URL) -> URL? {
        let repositoryURL = repositoryDirectory(base: base)
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: repositoryURL.path)) ?? [])
        let suffixed = names.filter { $0.hasSuffix("_\(variant)") }.sorted()
        let candidates = ["openai_whisper-\(variant)", variant] + suffixed
        for name in candidates where names.contains(name) {
            let folder = repositoryURL.appendingPathComponent(name, isDirectory: true)
            if isComplete(folder) {
                return folder
            }
        }
        return nil
    }

    /// A downloaded variant that has been loaded successfully at least once.
    public static func readyModelFolder(variant: String, base: URL) -> URL? {
        guard let folder = localModelFolder(variant: variant, base: base), isReady(folder) else { return nil }
        return folder
    }

    public static func isComplete(_ folder: URL) -> Bool {
        requiredComponents.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    public static func isReady(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(readyMarker).path)
    }

    public static func markReady(_ folder: URL) {
        let marker = folder.appendingPathComponent(readyMarker)
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? Data("loaded\n".utf8).write(to: marker)
        }
    }

    /// Complete model folders in the models directory.
    public static func installedFolders(base: URL) -> [URL] {
        let repositoryURL = repositoryDirectory(base: base)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: repositoryURL.path)) ?? []
        return names.sorted()
            .map { repositoryURL.appendingPathComponent($0, isDirectory: true) }
            .filter { isComplete($0) }
    }
}
