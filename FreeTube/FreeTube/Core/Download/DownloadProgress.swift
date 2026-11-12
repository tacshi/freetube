import Foundation

/// Turns the two tracks' "segments written" counts into one 0…1 fraction for a download.
/// Called from the tracks' download tasks concurrently, hence the lock.
nonisolated final class DownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let videoTotal: Int
    private let audioTotal: Int
    private let videoShare: Double
    private let onChange: @Sendable (Double) -> Void
    private var video = 0
    private var audio = 0

    /// - Parameter videoShare: part of the bar the video track fills; audio gets the rest.
    init(videoTotal: Int, audioTotal: Int, videoShare: Double, onChange: @escaping @Sendable (Double) -> Void) {
        self.videoTotal = max(videoTotal, 1)
        self.audioTotal = max(audioTotal, 1)
        self.videoShare = videoShare
        self.onChange = onChange
    }

    func videoWritten(_ count: Int) {
        report { video = count }
    }

    func audioWritten(_ count: Int) {
        report { audio = count }
    }

    private func report(_ update: () -> Void) {
        lock.lock()
        update()
        let fraction = Double(video) / Double(videoTotal) * videoShare
            + Double(audio) / Double(audioTotal) * (1 - videoShare)
        lock.unlock()
        onChange(min(fraction, 1))
    }
}
