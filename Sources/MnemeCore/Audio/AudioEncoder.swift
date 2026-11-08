import AVFoundation
import Foundation

/// Encodes finished recordings for the archive.
///
/// The app records uncompressed PCM into a CAF working file, which stays readable up to the last written
/// buffer if the app or the Mac stops mid-recording. When recording ends, the working file is encoded to
/// AAC (the archived original) and checked before anything is deleted.
public enum AudioEncoder {
    /// AAC bit rate for archived recordings: transparent for speech at a fraction of the PCM size.
    public static let archiveBitRate = 128_000

    /// Encodes `source` to AAC in an MPEG-4 container (`destination` should end in .m4a), then reads the result
    /// back and checks its duration against the source. Returns the encoded duration in seconds.
    @discardableResult
    public static func encodeAAC(from source: URL, to destination: URL, bitRate: Int = archiveBitRate) throws -> Double {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw ArchiveError.unreadableAudio(source.path, reason: error.localizedDescription)
        }
        let sampleRate = input.processingFormat.sampleRate
        guard sampleRate > 0, input.length > 0 else {
            throw ArchiveError.unreadableAudio(source.path, reason: "the file contains no audio frames")
        }
        let expected = Double(input.length) / sampleRate
        try? FileManager.default.removeItem(at: destination)
        do {
            try write(input, to: destination, bitRate: bitRate)
            let encoded = try AudioFileInfo.duration(of: destination)
            // AAC works in packets of 1024 frames; anything beyond a few packets means frames were lost.
            guard abs(encoded - expected) <= 0.1 else {
                throw ArchiveError.unreadableAudio(
                    destination.path,
                    reason: String(format: "the encoded file lasts %.3f s instead of %.3f s", encoded, expected)
                )
            }
            return encoded
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if error is ArchiveError {
                throw error
            }
            throw ArchiveError.unreadableAudio(source.path, reason: "encoding failed: \(error.localizedDescription)")
        }
    }

    /// Kept in its own function so the output file is closed (released) before it is read back.
    private static func write(_ input: AVAudioFile, to destination: URL, bitRate: Int) throws {
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let chunk: AVAudioFrameCount = 1 << 15
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw ArchiveError.unreadableAudio(input.url.path, reason: "could not allocate an audio buffer")
        }
        input.framePosition = 0
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 {
                break
            }
            try output.write(from: buffer)
        }
    }
}
