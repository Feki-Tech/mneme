import AVFoundation
import Foundation

/// Plays archived originals, whole or one segment at a time.
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var stopTime: TimeInterval?

    /// Plays `url` from `start` (or where it was paused) and pauses at `end` when given.
    func play(url: URL, from start: TimeInterval? = nil, until end: TimeInterval? = nil) {
        if self.url != url || player == nil {
            stop()
            guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
            newPlayer.prepareToPlay()
            player = newPlayer
            self.url = url
            duration = newPlayer.duration
        }
        guard let player else { return }
        if let start {
            player.currentTime = max(0, min(start, player.duration))
        }
        stopTime = end
        player.play()
        isPlaying = true
        currentTime = player.currentTime
        startTimer()
    }

    func togglePlayback(url: URL) {
        if plays(url) {
            pause()
        } else {
            play(url: url)
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTime = nil
        stopTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        url = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTime = nil
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
    }

    func plays(_ candidate: URL) -> Bool {
        isPlaying && url == candidate
    }

    /// True while the playhead of `candidate` is inside `start..<end`.
    func isWithin(_ candidate: URL?, start: TimeInterval, end: TimeInterval) -> Bool {
        guard let candidate, url == candidate, player != nil else { return false }
        return currentTime >= start && currentTime < max(end, start + 0.05)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if let stopTime, player.currentTime >= stopTime {
            pause()
        } else if !player.isPlaying {
            isPlaying = false
            stopTimer()
        }
    }
}
