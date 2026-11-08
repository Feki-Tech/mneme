import ArgumentParser
import Foundation
import MnemeCore
import MnemeSpeech

/// Transcribes a file without archiving it, showing the raw decoder output next to the validated result.
struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe a file without archiving it (a dry run), with the raw decoder output for diagnosis."
    )

    @Argument(help: "Audio file.", completion: .file())
    var file: String

    @Option(help: "Language spoken (default: identified, within --profile when given).")
    var language: String?

    @Option(name: .customLong("profile"), help: "Language profile for identification, for example: en,fr,ar.")
    var profileList: String?

    @Option(name: .customLong("term"), help: "Glossary term for the decoder prompt (repeatable).")
    var terms: [String] = []

    @Flag(help: "Also print the raw segments, before validation.")
    var raw = false

    @Flag(name: .customLong("no-words"), help: "Skip word timings (segment timings only).")
    var noWords = false

    @Flag(help: "Print as JSON.")
    var json = false

    @OptionGroup var model: ModelOptions

    func validate() throws {
        if let language, LanguagePolicy.resolve(language) == nil {
            throw ValidationError("Unsupported language “\(language)”.")
        }
    }

    func run() async throws {
        let url = Paths.url(file)
        let audio = try AudioPreparer.prepare(url)
        let profile = try LanguagePolicy.validatedList(LanguagePolicy.parseList(profileList ?? ""))
        let engine = model.makeEngine()
        try model.requireModel(engine)
        Console.status(Console.loadingMessage(for: model.profile, allowDownload: model.allowDownload, isReady: engine.isReady))
        try await engine.load(allowDownload: model.allowDownload)

        let rawTranscript = try await engine.transcribe(TranscriptionRequest(
            audioURL: url,
            forcedLanguage: language.flatMap { LanguagePolicy.resolve($0) },
            languageProfile: profile,
            glossary: terms,
            wordTimestamps: !noWords
        ))
        let sanitized = try TranscriptSanitizer().sanitize(rawTranscript, duration: audio.durationSeconds)

        if json {
            try Console.json(TranscribeOutput(
                file: url.lastPathComponent,
                durationSeconds: audio.durationSeconds,
                raw: raw ? rawTranscript : nil,
                transcript: sanitized.transcript,
                sanitization: sanitized.report
            ))
            return
        }
        Console.out("File      \(url.lastPathComponent) (\(String(format: "%.2f", audio.durationSeconds)) s)")
        Console.out("Language  \(Format.language(sanitized.transcript.language))")
        let settings = rawTranscript.provenance.settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        Console.out("Settings  \(settings.joined(separator: " "))")
        if let seconds = rawTranscript.processingSeconds {
            Console.out(String(format: "Processed in %.2f s", seconds))
        }
        if raw {
            Console.out("")
            Console.out("Raw segments (\(rawTranscript.segments.count)):")
            for segment in rawTranscript.segments {
                let logprob = segment.avgLogprob.map { String(format: "%.2f", $0) } ?? "–"
                let temperature = segment.temperature.map { String(format: "%.1f", $0) } ?? "–"
                let words = segment.words
                let span = words.isEmpty ? "" : String(format: " words %.2f–%.2f", words[0].start, words[words.count - 1].end)
                Console.out(String(format: "  %.2f–%.2f", segment.start, segment.end)
                    + "  logprob \(logprob)  T \(temperature)  \(words.count) words\(span)  \(segment.text.debugDescription)")
            }
        }
        Console.out("")
        Console.out("Validation: \(sanitized.report.summary)")
        for segment in sanitized.transcript.segments {
            let marks = Format.flags(segment.flags)
            Console.out("#\(segment.index)  \(Format.position(segment.start))–\(Format.position(segment.end))  \(segment.text)\(marks.isEmpty ? "" : "  " + marks)")
        }
        if sanitized.transcript.segments.isEmpty {
            Console.out("(no speech in the validated transcript)")
        }
    }
}

struct TranscribeOutput: Encodable {
    var file: String
    var durationSeconds: Double
    var raw: Transcript?
    var transcript: Transcript
    var sanitization: SanitizationReport
}
