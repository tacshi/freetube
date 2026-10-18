import Foundation

/// One watch session's reporting to the signed-in YouTube account (see `WatchProgressService`).
///
/// - A **playback** ping once playback starts — records the view in the account's history.
/// - **Watchtime** pings for each stretch actually played (`st`…`et`) with the current position
///   (`cmt`): every `interval` seconds of playback, and immediately on pause, seek, switching
///   videos and closing — so YouTube's resume point lands where the user stopped.
///
/// All pings carry one random client playback nonce (`cpn`) per session, as YouTube's players do.
@available(iOS 17.0, *)
@MainActor
final class WatchProgressReporter {
    private let service: any WatchProgressServicing
    private var videoID: String?
    private var tracking: WatchTracking?
    private var cpn = ""
    private var segmentStart: TimeInterval = 0
    private var lastPosition: TimeInterval = 0
    private var sentPlaybackPing = false

    private static let interval: TimeInterval = 10
    private static let cpnAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    init(service: any WatchProgressServicing = WatchProgressService()) {
        self.service = service
    }

    /// Starts reporting for `videoID`, playback beginning at `position`. Tracking URLs load in
    /// the background; anything played before they arrive is folded into the first watchtime ping.
    func begin(videoID: String, at position: TimeInterval) {
        end()
        self.videoID = videoID
        cpn = String((0..<16).map { _ in Self.cpnAlphabet.randomElement() ?? "a" })
        segmentStart = position
        lastPosition = position
        sentPlaybackPing = false
        Task { [weak self, service] in
            let tracking = try? await service.tracking(videoID: videoID)
            guard let self, self.videoID == videoID else { return }
            self.tracking = tracking
        }
    }

    /// Feed from the player's time observer.
    func tick(position: TimeInterval, isPlaying: Bool) {
        guard videoID != nil else { return }
        if let tracking, isPlaying, !sentPlaybackPing {
            sentPlaybackPing = true
            send(tracking.playbackURL, ["cmt": Self.format(position)])
        }
        // A jump (seek, double-tap, scrub) ends the current stretch; a new one starts here.
        if position < lastPosition - 1 || position > lastPosition + 3 {
            flushSegment(endingAt: lastPosition)
            segmentStart = position
        }
        lastPosition = position
        if isPlaying, position - segmentStart >= Self.interval {
            flushSegment(endingAt: position)
            segmentStart = position
        }
    }

    /// Report the stretch played so far (pause, end of video).
    func flush() {
        flushSegment(endingAt: lastPosition)
        segmentStart = lastPosition
    }

    /// Flush and stop reporting (switching videos, closing the player).
    func end() {
        guard videoID != nil else { return }
        flush()
        videoID = nil
        tracking = nil
    }

    private func flushSegment(endingAt end: TimeInterval) {
        guard let tracking, end > segmentStart + 0.5 else { return }
        send(tracking.watchtimeURL, [
            "st": Self.format(segmentStart),
            "et": Self.format(end),
            "cmt": Self.format(end)
        ])
    }

    private func send(_ url: URL, _ parameters: [String: String]) {
        var all = parameters
        all["ver"] = "2"
        all["cpn"] = cpn
        all["el"] = "detailpage"
        Task { [service] in
            await service.ping(url, parameters: all)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", max(0, seconds))
    }
}
