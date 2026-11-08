import AVFoundation
import Foundation

public enum AudioFileInfo {
    /// Duration in seconds, read from the file's audio frames.
    public static func duration(of url: URL) throws -> Double {
        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            guard sampleRate > 0, file.length > 0 else {
                throw ArchiveError.unreadableAudio(url.path, reason: "the file contains no audio frames")
            }
            return Double(file.length) / sampleRate
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.unreadableAudio(url.path, reason: error.localizedDescription)
        }
    }

    /// Copies seconds `start..<end` of `source` into a new 32-bit float PCM file (use a .wav or .caf destination).
    public static func extractSegment(from source: URL, start: Double, end: Double, to destination: URL) throws {
        guard start.isFinite, end.isFinite, end > start else {
            throw ArchiveError.invalidArgument("The audio range \(start)–\(end) s of \(source.lastPathComponent) is empty.")
        }
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw ArchiveError.unreadableAudio(source.path, reason: error.localizedDescription)
        }
        let format = input.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = input.length
        let firstFrame = min(totalFrames, max(0, AVAudioFramePosition((start * sampleRate).rounded(.down))))
        let lastFrame = min(totalFrames, max(firstFrame, AVAudioFramePosition((end * sampleRate).rounded(.up))))
        guard lastFrame > firstFrame else {
            throw ArchiveError.invalidArgument("The audio range \(start)–\(end) s of \(source.lastPathComponent) is empty.")
        }
        let output = try AVAudioFile(
            forWriting: destination,
            settings: pcmFileSettings(sampleRate: sampleRate, channels: format.channelCount),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw ArchiveError.unreadableAudio(source.path, reason: "could not allocate an audio buffer")
        }
        input.framePosition = firstFrame
        var remaining = AVAudioFrameCount(lastFrame - firstFrame)
        while remaining > 0 {
            try input.read(into: buffer, frameCount: min(chunk, remaining))
            let read = buffer.frameLength
            if read == 0 { break }
            try output.write(from: buffer)
            remaining -= min(remaining, read)
        }
    }

    /// Settings for an uncompressed 32-bit float PCM file.
    public static func pcmFileSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}
