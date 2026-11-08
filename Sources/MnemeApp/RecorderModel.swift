import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        "The microphone could not be started. Check the input device in System Settings > Sound."
    }
}

/// Records from the default microphone with a live level meter.
///
/// The working file is uncompressed PCM in CAF (48 kHz, 16-bit, mono): if the app or the Mac stops during a
/// recording, everything written so far stays readable and is archived at the next launch. Finished
/// recordings are encoded to AAC for the archive (see `AudioEncoder`).
@MainActor
final class RecorderModel: ObservableObject {
    enum Permission {
        case undetermined
        case granted
        case denied
    }

    @Published private(set) var permission: Permission
    @Published private(set) var isRecording = false
    /// Input level from 0 to 1.
    @Published private(set) var level: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    /// The file being written, which recovery must leave alone.
    var activeFileName: String? {
        fileURL?.lastPathComponent
    }

    init() {
        permission = RecorderModel.currentPermission()
    }

    static func currentPermission() -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .undetermined
        default:
            return .denied
        }
    }

    func requestPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permission = granted ? .granted : .denied
    }

    /// Starts recording into `folder`, which is created privately (0700) if needed.
    func start(in folder: URL) throws {
        guard !isRecording else { return }
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = folder.appendingPathComponent("recording-\(RecorderModel.stamp()).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.isMeteringEnabled = true
        guard newRecorder.record() else {
            throw RecorderError.couldNotStart
        }
        recorder = newRecorder
        fileURL = url
        isRecording = true
        elapsed = 0
        level = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    /// Stops and returns the finished file.
    func stop() -> URL? {
        guard let recorder, isRecording else { return nil }
        recorder.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        level = 0
        self.recorder = nil
        let url = fileURL
        fileURL = nil
        return url
    }

    /// Stops and deletes the recording.
    func discard() {
        if let url = stop() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        level = max(0, min(1, (decibels + 50) / 50))
        elapsed = recorder.currentTime
    }

    /// "20261108-101530-a1b2c3d4": sortable, and unique even for two recordings started in the same second.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(formatter.string(from: Date()))-\(suffix)"
    }
}
