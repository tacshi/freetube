import Foundation
import AVFoundation
import Combine
import Kingfisher
import OSLog
import SwiftData
import UIKit

/// CLAUDE.md §8: single source of truth for playback. Injected via SwiftUI environment.
/// Mini player and full-screen player both observe this object — neither owns its own `AVPlayer`.
///
/// Combine is used **only** here for `AVPlayer` time-observer bridging, per CLAUDE.md §2.9.
@available(iOS 17.0, *)
@MainActor
@Observable
final class PlayerStateManager {
    enum LoadState: Equatable {
        case idle
        case resolving
        case readyToPlay
        case failed(String)
    }

    // MARK: - Published state

    private(set) var currentVideo: Video?
    /// Cached artwork for the current video. Used both to populate `MPNowPlayingInfoCenter`
    /// (lock-screen + Control Center) and (in the future) any in-app UI that wants a UIImage rather
    /// than the SwiftUI `Image`. Refreshed when the current video changes.
    private(set) var currentArtwork: UIImage?
    private(set) var loadState: LoadState = .idle
    /// Also keeps the screen from dimming and auto-locking while a video plays, like the YouTube
    /// app; pausing or stopping hands the idle timer back to iOS.
    private(set) var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            UIApplication.shared.isIdleTimerDisabled = isPlaying
        }
    }
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Drives the full-screen player cover in `RootView`. `load(_:)` sets it; closing the
    /// player clears it and `dismiss()` stops playback. There is no mini player.
    var fullScreenPresented: Bool = false
    /// Current playback speed (1.0 = normal). Persisted; set from the player's ⋯ menu.
    private(set) var playbackRate: Double = 1.0

    // MARK: Recommendations
    /// YouTube's recommendations for the current video (`MoreVideoInfosResponse`), shown under
    /// the player like the YouTube app's related list. Autoplay continues with the first one
    /// that hasn't been played this session.
    private(set) var recommendations: [Video] = []
    /// A recommendations fetch for the current video is in flight.
    private(set) var isLoadingRecommendations = false
    @ObservationIgnored private var recommendationsTask: Task<[Video], Never>?

    /// One audio track offered by the current stream (`AVMediaSelectionOption`).
    struct MediaChoice: Identifiable, Hashable {
        /// Index into the media selection group's `options`.
        let id: Int
        let name: String
    }
    /// Audio tracks of the current stream; the menu offers a choice only when there are several.
    private(set) var audioChoices: [MediaChoice] = []
    private(set) var selectedAudioID: Int?
    @ObservationIgnored private var audibleGroup: AVMediaSelectionGroup?

    // MARK: Captions
    /// YouTube caption tracks for the current video (from `StreamService`; YouTube's HLS streams
    /// carry no subtitles of their own). Empty when the video has none.
    private(set) var captionTracks: [CaptionTrack] = []
    /// Selected caption track, `nil` = captions off.
    private(set) var selectedCaptionID: String?
    /// Caption line to show right now, or `nil`.
    private(set) var captionText: String?
    @ObservationIgnored private var captionCues: [CaptionCue] = []
    @ObservationIgnored private let captions: any CaptionServicing = CaptionService()
    @ObservationIgnored private var captionObserver: Any?

    // MARK: - AVPlayer

    /// `AVQueuePlayer` to unlock `advanceToNextItem()` and queue introspection for future preload.
    /// IMPORTANT: don't use `replaceCurrentItem(with:)` to load tracks — it's a no-op on
    /// `AVQueuePlayer` when the internal queue is empty (which is our usual state). Use the
    /// `removeAllItems()` + `insert(_:after:)` pattern via `swap(to:)` below.
    let player = AVQueuePlayer()

    // MARK: - Collaborators

    let queue: QueueManager
    private let preferences: UserPreferences
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "PlayerStateManager")

    /// Whether autoplay may continue into recommendations once the queue runs out. `true`
    /// whenever the user loads a video without explicitly skipping recommendations (Home /
    /// Search / recommendation taps), `false` for curated batch actions like playlist's Play
    /// all / Shuffle all, which stop at the end of the playlist.
    private var queueAcceptsRecommendations = true

    private var timeObserver: Any?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemErrorLogObservation: NSObjectProtocol?
    private var playerErrorObservation: NSKeyValueObservation?
    private var defaultRateObservation: NSKeyValueObservation?

    private let streams: any StreamServicing = StreamService()
    /// Video whose stream has already been re-resolved once after an `AVPlayerItem` failure.
    /// A signed URL can resolve fine and still fail inside AVPlayer (expired / 403); one fresh
    /// resolve fixes that, a second failure means the stream really isn't playable.
    private var streamRetriedVideoID: String?

    // MARK: Resume position
    /// Video the `AVPlayerItem` currently in the player belongs to. Position saves only happen
    /// when this matches `currentVideo`, so a time-observer tick that fires mid-switch can't
    /// write the old item's time onto the new video.
    private var itemVideoID: String?
    /// Saved position to seek to once the freshly loaded item reports `readyToPlay`.
    private var pendingResume: (videoID: String, time: TimeInterval)?
    /// Last position written for the current item; saves are throttled to every few seconds.
    private var lastSavedPosition: TimeInterval = 0
    /// Reports watch progress to the signed-in YouTube account (history + resume point on every
    /// device). Only active when signed in and `UserPreferences.syncWatchProgress` is on.
    @ObservationIgnored private let watchReporter = WatchProgressReporter()

    // MARK: Seeking
    /// Where an in-flight (or queued) seek is headed; `nil` when no seek is pending.
    private(set) var pendingSeekTarget: TimeInterval?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var queuedSeek: (time: TimeInterval, precise: Bool)?

    init(
        queue: QueueManager = QueueManager(),
        preferences: UserPreferences = UserPreferences()
    ) {
        self.queue = queue
        self.preferences = preferences
        // Keep the audio track running when the player view goes off-screen (popup minimize, app
        // backgrounded). Without this, AVPlayer pauses video tracks as soon as their pixel buffer
        // pipeline is no longer visible, which manifests as "audio cuts out the moment you collapse
        // the mini-player." Pairs with the `.playback` AVAudioSession configured at launch.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Restore the last-used playback speed. `defaultRate` is what the player's speed menu
        // writes (`setPlaybackRate`), and `AVPlayer.play()` resumes at this rate (not the
        // transient `rate`).
        // Setting it *before* installObservers keeps the KVO from firing back and re-saving the
        // same value during launch.
        player.defaultRate = Float(preferences.playbackRate)
        playbackRate = preferences.playbackRate
        installObservers()
    }

    /// Tear-down hook for tests / app lifecycle. Call before releasing the manager. We avoid `deinit`
    /// here so we don't have to reach into main-actor-isolated state from a nonisolated context.
    func tearDownObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let captionObserver { player.removeTimeObserver(captionObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        captionObserver = nil
        endObserver = nil
    }

    // MARK: - Public commands

    /// Loads a video for playback.
    ///
    /// - Parameter skipRecommendations: when `true`, autoplay doesn't continue into YouTube's
    ///   recommendations once the queue ends. Pass this from explicit
    ///   batch actions that already populated a curated queue — playlist's Play all / Shuffle
    ///   all — so playback stops after the playlist. Default is `false` so single-video taps
    ///   from Home / Search / the recommendation list get the YouTube-app-style autoplay chain.
    func load(_ video: Video, autoplay: Bool = true, skipRecommendations: Bool = false) {
        log.info("load(\(video.id, privacy: .public)) autoplay=\(autoplay, privacy: .public) skipRecs=\(skipRecommendations, privacy: .public)")
        queueAcceptsRecommendations = !skipRecommendations
        // Pause and tear down anything currently playing. Otherwise we'd keep playing audio from
        // the previous video while the new one's stream is resolving.
        if isPlaying {
            log.info("load: pausing current playback before resolving new video")
            pause()
        }
        if !player.items().isEmpty {
            log.debug("load: clearing AVQueuePlayer items (\(self.player.items().count, privacy: .public) entries)")
            player.removeAllItems()
        }
        watchReporter.end()
        itemVideoID = nil
        pendingResume = nil
        queuedSeek = nil
        pendingSeekTarget = nil
        clearMediaChoices()
        currentVideo = video
        // Keep the queue coherent. Fresh taps from search/home append the video; subsequent calls
        // from `playNext()` / `playPrevious()` find it already there and just update `currentIndex`.
        queue.setCurrent(video)
        fullScreenPresented = true
        loadState = .resolving
        // Wipe transport state from the previous video so a stray time-observer tick during the
        // transition (the periodic callback can fire AFTER currentVideo flips but BEFORE the new
        // AVPlayerItem is installed) doesn't carry the old item's elapsed/duration into a save —
        // that's what showed phantom progress bars on cells the user never played.
        elapsed = 0
        duration = 0
        recordWatchHistory(video: video)
        refreshArtwork(for: video)
        loadRecommendations(for: video)
        Task { await resolveAndPlay(video: video, autoplay: autoplay) }
    }

    /// Upserts a `WatchHistoryEntry` so the Library's "Recents" section reflects what the user
    /// played. Same-id taps just bump `watchedAt` so the row floats to the top. The actor hop keeps
    /// the SQL write off the main thread; @Query observers see the change automatically once the
    /// background context saves.
    private func recordWatchHistory(video: Video) {
        let videoID = video.id
        let title = video.title
        let channelName = video.channelName
        let thumbnailURL = video.thumbnailURL
        Task {
            await PersistenceWriter.shared.upsertWatchHistory(
                videoID: videoID,
                title: title,
                channelName: channelName,
                thumbnailURL: thumbnailURL
            )
        }
    }

    func play() {
        log.info("play()")
        player.play()
        isPlaying = true
    }

    func pause() {
        log.info("pause()")
        player.pause()
        isPlaying = false
        savePosition(force: true)
        watchReporter.flush()
    }

    func togglePlayPause() {
        log.info("togglePlayPause() (isPlaying=\(self.isPlaying, privacy: .public))")
        isPlaying ? pause() : play()
    }

    /// Seeks to `seconds`. `precise: false` lands on the nearest keyframe — fast, used for live
    /// feedback while scrubbing; the final position is then set with a precise seek.
    ///
    /// **Coalesced ("chase") seeking**, per Apple's smooth-scrubbing guidance: only one seek runs
    /// at a time; requests that arrive meanwhile replace each other, and when the running seek
    /// completes the latest one starts. Firing a seek on every drag update (~60/s) at an HLS
    /// stream — each one fetching a new segment — left playback stalled at a stale point, and
    /// because `currentTime` still reported that point, the next scrub restarted from it.
    func seek(to seconds: TimeInterval, precise: Bool = true) {
        if precise {
            log.info("seek(to: \(seconds, privacy: .public)s)")
        }
        pendingSeekTarget = seconds
        queuedSeek = (seconds, precise)
        if !seekInFlight {
            startQueuedSeek()
        }
    }

    private func startQueuedSeek() {
        guard let next = queuedSeek else {
            seekInFlight = false
            let now = player.currentTime().seconds
            if now.isFinite { elapsed = now }
            pendingSeekTarget = nil
            return
        }
        queuedSeek = nil
        seekInFlight = true
        let time = CMTime(seconds: next.time, preferredTimescale: 600)
        let tolerance: CMTime = next.precise ? .zero : .positiveInfinity
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in manager.startQueuedSeek() }
        }
    }

    /// The player's position right now — or where an in-flight seek is headed. `elapsed` only
    /// ticks every 0.5s, which is too coarse for rapid repeated double-tap seeks or the start
    /// point of a scrub, and `currentTime` lags until a seek completes.
    var livePosition: TimeInterval {
        if let pendingSeekTarget { return pendingSeekTarget }
        let now = player.currentTime().seconds
        return now.isFinite ? now : elapsed
    }

    /// Position to show in the UI: the in-flight seek target while seeking, else `elapsed`. Keeps
    /// the scrubber from snapping back to the old time while the new segment loads.
    var displayPosition: TimeInterval {
        pendingSeekTarget ?? elapsed
    }

    func seekRelative(by delta: TimeInterval) {
        log.info("seekRelative(by: \(delta, privacy: .public)s)")
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        seek(to: max(0, min(livePosition + delta, upperBound)))
    }

    func playNext() {
        log.info("playNext() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        if let next = queue.advance() {
            load(next)
            return
        }
        // Queue at end: continue with the current video's first recommendation, like the
        // YouTube app's autoplay. Skips anything already played this session (the queue keeps
        // what was played) so two videos recommending each other don't ping-pong.
        guard queueAcceptsRecommendations,
              queue.repeatMode == .off,
              let seedID = currentVideo?.id else {
            log.notice("playNext: queue at end, no autoplay (acceptsRecs=\(self.queueAcceptsRecommendations, privacy: .public), repeat=\(String(describing: self.queue.repeatMode), privacy: .public))")
            return
        }
        let task = recommendationsTask
        Task { [weak self] in
            let recommendations = await task?.value ?? []
            guard let self, self.currentVideo?.id == seedID else { return }
            let played = Set(self.queue.items.map(\.id))
            guard let next = recommendations.first(where: { !played.contains($0.id) }) else {
                self.log.notice("playNext: no unplayed recommendation after \(seedID, privacy: .public)")
                return
            }
            self.log.info("playNext: autoplaying recommendation \(next.id, privacy: .public)")
            self.load(next)
        }
    }

    func playPrevious() {
        log.info("playPrevious() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        guard let previous = queue.previous() else {
            log.notice("playPrevious: at start of queue, nothing to go back to")
            return
        }
        load(previous)
    }

    func dismiss() {
        log.info("dismiss()")
        pause()
        watchReporter.end()
        fullScreenPresented = false
        itemVideoID = nil
        pendingResume = nil
        currentVideo = nil
        loadState = .idle
        recommendationsTask?.cancel()
        recommendationsTask = nil
        recommendations = []
        isLoadingRecommendations = false
        player.removeAllItems()
        NowPlayingCenter.clear()
    }

    // MARK: - Internals

    /// Swap the player to a new item using the `AVQueuePlayer`-correct pattern. `replaceCurrentItem`
    /// is documented to be a no-op when the player's internal queue is empty (which is our usual
    /// state since the playable URL is short-lived and we never preload), so we always tear the
    /// queue down to nothing first and then insert. Also wires KVO so we hear about decode/auth
    /// failures the moment they happen (CoreMedia's `CFByteFlume err=-12939` style messages don't
    /// surface a structured `NSError` otherwise).
    private func loadItem(_ item: AVPlayerItem) {
        let url = (item.asset as? AVURLAsset)?.url.path ?? "(non-URL asset)"
        log.info("loadItem: removeAllItems + insert (asset=\(url, privacy: .public))")
        player.removeAllItems()
        player.insert(item, after: nil)
        log.debug("loadItem: queue size after insert=\(self.player.items().count, privacy: .public)")
        observe(item: item)
    }

    private func observe(item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        if let token = itemErrorLogObservation { NotificationCenter.default.removeObserver(token) }

        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .unknown:
                    self.log.info("AVPlayerItem status: unknown")
                case .readyToPlay:
                    self.log.info("AVPlayerItem status: readyToPlay (duration=\(item.duration.seconds, privacy: .public)s)")
                    self.applyPendingResume(for: item)
                    self.loadMediaChoices(for: item)
                case .failed:
                    let err = item.error as NSError?
                    self.log.error("AVPlayerItem status: FAILED domain=\(err?.domain ?? "?", privacy: .public) code=\(err?.code ?? 0, privacy: .public) info=\(String(describing: err?.userInfo), privacy: .public)")
                    self.retryStream(after: item)
                @unknown default:
                    break
                }
            }
        }

        itemErrorLogObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let entry = item?.errorLog()?.events.last else { return }
            self?.log.error("AVPlayerItem error-log: domain=\(entry.errorDomain, privacy: .public) code=\(entry.errorStatusCode, privacy: .public) comment=\(entry.errorComment ?? "", privacy: .public) URI=\(entry.uri ?? "", privacy: .public)")
        }
    }

    private func resolveAndPlay(video: Video, autoplay: Bool) async {
        log.info("resolveAndPlay: start for \(video.id, privacy: .public)")
        // **Tap → play, like the YouTube app.** Resolve an HLS URL (`StreamService`) and hand it
        // straight to `AVPlayer` — no download, nothing written to disk. If the item later fails,
        // `retryStream(after:)` re-resolves once.
        streamRetriedVideoID = nil
        async let localPlayback = PersistenceWriter.shared.savedPlayback(videoID: video.id)
        let stream: ResolvedStream
        do {
            stream = try await streams.resolveStream(videoID: video.id)
        } catch {
            guard currentVideo?.id == video.id else { return }
            log.error("resolveAndPlay: no stream for \(video.id, privacy: .public): \(String(describing: error), privacy: .public)")
            loadState = .failed(Self.failureMessage(for: error))
            return
        }
        // `load(_:)` may have moved on to another video while we were resolving; don't clobber it.
        guard currentVideo?.id == video.id else {
            log.info("resolveAndPlay: \(video.id, privacy: .public) superseded before playback, dropping")
            return
        }
        let resumeAt = Self.resumePoint(
            local: await localPlayback,
            youTube: YouTubeResumeCache.shared.entry(for: video.id),
            duration: video.duration
        )
        guard currentVideo?.id == video.id else { return }
        loadItem(makeItem(url: stream.hlsURL))
        itemVideoID = video.id
        if preferences.syncWatchProgress, case .loggedIn = AuthState.shared.status {
            watchReporter.begin(videoID: video.id, at: resumeAt ?? 0)
        }
        captionTracks = stream.captions
        autoSelectCaption()
        lastSavedPosition = resumeAt ?? 0
        if let resumeAt {
            log.info("resolveAndPlay: resuming \(video.id, privacy: .public) at \(Int(resumeAt), privacy: .public)s")
            pendingResume = (video.id, resumeAt)
        }
        loadState = .readyToPlay
        updateNowPlaying()
        if autoplay { play() }
        log.info("resolveAndPlay: finished happy-path for \(video.id, privacy: .public)")
    }

    // MARK: - Speed, subtitles, audio

    func setPlaybackRate(_ rate: Double) {
        guard rate > 0 else { return }
        player.defaultRate = Float(rate)
        if isPlaying { player.rate = Float(rate) }
        playbackRate = rate
    }

    /// Turns captions on with track `id`, or off with `nil`. Remembers the language so the next
    /// video with a matching track starts with captions on.
    func selectCaption(_ id: String?) {
        let track = id.flatMap { id in captionTracks.first { $0.id == id } }
        preferences.preferredCaptionLanguage = track?.languageCode ?? ""
        applyCaption(track)
    }

    /// CC button: off → the remembered language (or the first track); on → off.
    func toggleCaptions() {
        if selectedCaptionID != nil {
            selectCaption(nil)
        } else {
            selectCaption(preferredCaptionTrack()?.id ?? captionTracks.first?.id)
        }
    }

    private func autoSelectCaption() {
        guard !preferences.preferredCaptionLanguage.isEmpty else { return }
        applyCaption(preferredCaptionTrack())
    }

    /// Track for the remembered language: manual before auto-generated, exact code before the
    /// same base language (`de` matches `de-DE`).
    private func preferredCaptionTrack() -> CaptionTrack? {
        let preferred = preferences.preferredCaptionLanguage
        guard !preferred.isEmpty else { return nil }
        let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
        let candidates = captionTracks.filter {
            $0.languageCode == preferred || $0.languageCode.split(separator: "-").first.map(String.init) == base
        }
        return candidates.sorted { lhs, rhs in
            if lhs.isAutoGenerated != rhs.isAutoGenerated { return !lhs.isAutoGenerated }
            return lhs.languageCode == preferred && rhs.languageCode != preferred
        }.first
    }

    private func applyCaption(_ track: CaptionTrack?) {
        selectedCaptionID = track?.id
        captionCues = []
        captionText = nil
        guard let track, let videoID = currentVideo?.id else { return }
        Task { [weak self] in
            guard let self else { return }
            let cues = (try? await self.captions.fetchCues(for: track)) ?? []
            guard self.selectedCaptionID == track.id, self.currentVideo?.id == videoID else { return }
            self.captionCues = cues
            self.updateCaption(at: self.livePosition)
        }
    }

    private func clearCaptions() {
        captionTracks = []
        selectedCaptionID = nil
        captionCues = []
        captionText = nil
    }

    /// Latest-starting cue that covers `time` (YouTube's auto-generated captions overlap).
    private func updateCaption(at time: TimeInterval) {
        var text: String?
        if !captionCues.isEmpty {
            var low = 0, high = captionCues.count
            while low < high {
                let mid = (low + high) / 2
                if captionCues[mid].start <= time { low = mid + 1 } else { high = mid }
            }
            var index = low - 1
            while index >= 0, index >= low - 8 {
                let cue = captionCues[index]
                if time < cue.end {
                    text = cue.text
                    break
                }
                index -= 1
            }
        }
        if text != captionText { captionText = text }
    }

    func selectAudio(_ id: Int) {
        guard let item = player.currentItem, let group = audibleGroup,
              group.options.indices.contains(id) else { return }
        item.select(group.options[id], in: group)
        selectedAudioID = id
    }

    /// Reads the stream's audio tracks once the item is ready.
    private func loadMediaChoices(for item: AVPlayerItem) {
        Task { @MainActor [weak self] in
            let audible = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            guard let self, self.player.currentItem === item else { return }
            self.audibleGroup = audible
            self.audioChoices = Self.choices(in: audible)
            self.selectedAudioID = Self.selectedIndex(in: audible, of: item)
        }
    }

    private func clearMediaChoices() {
        audibleGroup = nil
        audioChoices = []
        selectedAudioID = nil
        clearCaptions()
    }

    private static func choices(in group: AVMediaSelectionGroup?) -> [MediaChoice] {
        guard let group else { return [] }
        return group.options.enumerated().map { MediaChoice(id: $0.offset, name: $0.element.displayName) }
    }

    private static func selectedIndex(in group: AVMediaSelectionGroup?, of item: AVPlayerItem) -> Int? {
        guard let group, let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return group.options.firstIndex(of: selected)
    }

    /// Where to start `video`: the app's own saved position or the account's YouTube resume point,
    /// whichever is newer (a local save after the feed was loaded wins; YouTube wins when the feed
    /// was loaded after the last local save, e.g. after watching on another device). `nil` = start
    /// from the beginning: no progress, under 5s in, or within 10s of the end (finished videos
    /// start over, like YouTube).
    static func resumePoint(
        local: SavedPlayback?,
        youTube: YouTubeResumeCache.Entry?,
        duration: TimeInterval?
    ) -> TimeInterval? {
        let chosen: (position: TimeInterval, duration: TimeInterval?)
        switch (local, youTube) {
        case let (local?, youTube?):
            chosen = (local.savedAt ?? .distantPast) >= youTube.observedAt
                ? (local.position, local.duration)
                : (youTube.seconds, youTube.duration)
        case let (local?, nil):
            chosen = (local.position, local.duration)
        case let (nil, youTube?):
            chosen = (youTube.seconds, youTube.duration)
        case (nil, nil):
            return nil
        }
        guard chosen.position >= 5 else { return nil }
        let total = chosen.duration ?? duration ?? 0
        if total > 0, chosen.position >= total - 10 { return nil }
        return chosen.position
    }

    /// Seeks the freshly loaded item to the saved resume point, once, when it becomes ready.
    private func applyPendingResume(for item: AVPlayerItem) {
        guard let pending = pendingResume,
              pending.videoID == currentVideo?.id,
              pending.videoID == itemVideoID,
              player.currentItem === item else { return }
        pendingResume = nil
        let target = CMTime(seconds: pending.time, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
    }

    /// Writes the current position to watch history. Throttled to every 5s of movement unless
    /// `force` (pause, switch, close). Skipped until the resume seek has landed so the initial
    /// 0s ticks of a resumed video don't overwrite the saved spot.
    private func savePosition(force: Bool) {
        guard let videoID = itemVideoID,
              videoID == currentVideo?.id,
              pendingResume == nil,
              elapsed > 0 else { return }
        guard force || abs(elapsed - lastSavedPosition) >= 5 else { return }
        lastSavedPosition = elapsed
        persistPosition(videoID: videoID, position: elapsed, duration: duration)
    }

    private func persistPosition(videoID: String, position: TimeInterval, duration: TimeInterval) {
        Task {
            await PersistenceWriter.shared.savePlaybackPosition(
                videoID: videoID,
                position: position,
                duration: duration
            )
        }
    }

    /// `AVPlayerItem` for a stream URL, capped at the user's preferred quality. HLS adapts on its
    /// own; `preferredMaximumResolution` keeps AVPlayer's variant choice under the cap.
    private func makeItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        if let cap = preferences.preferredQuality.heightCap {
            item.preferredMaximumResolution = CGSize(width: CGFloat(cap) * 16 / 9, height: CGFloat(cap))
        }
        return item
    }

    private static func failureMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? YouTubeServiceError.streamExtractionFailed.errorDescription
            ?? String(localized: "Couldn't load the video stream.")
    }

    /// Called when the current `AVPlayerItem` fails. Re-resolves a fresh stream URL once per
    /// video and swaps it in, resuming from where playback stopped; a second failure surfaces.
    private func retryStream(after failedItem: AVPlayerItem) {
        guard let video = currentVideo, player.items().contains(failedItem) else { return }
        guard streamRetriedVideoID != video.id else {
            loadState = .failed(Self.failureMessage(for: YouTubeServiceError.streamExtractionFailed))
            return
        }
        streamRetriedVideoID = video.id
        let resumeAt = failedItem.currentTime()
        log.notice("stream: item failed for \(video.id, privacy: .public), re-resolving once")
        loadState = .resolving
        Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.streams.resolveStream(videoID: video.id)
                guard self.currentVideo?.id == video.id else { return }
                let item = self.makeItem(url: stream.hlsURL)
                self.loadItem(item)
                self.itemVideoID = video.id
                if resumeAt.seconds > 1 {
                    _ = await self.player.seek(to: resumeAt)
                }
                self.loadState = .readyToPlay
                self.updateNowPlaying()
                self.play()
            } catch {
                guard self.currentVideo?.id == video.id else { return }
                self.loadState = .failed(Self.failureMessage(for: error))
            }
        }
    }

    /// Fetches `MoreVideoInfosResponse` (YouTube's `/next`, independent of the stream lookup, so
    /// it can't hold up playback) and publishes its recommended videos for the player's related
    /// list. Runs in parallel with stream resolution so the list fills while the video loads.
    /// Failures are logged and leave the list empty.
    private func loadRecommendations(for video: Video) {
        recommendationsTask?.cancel()
        recommendations = []
        isLoadingRecommendations = true
        let videoID = video.id
        let task = Task { [log] () -> [Video] in
            do {
                let info = try await VideoService().fetchMoreInfo(id: videoID)
                return info.recommended.filter { $0.id != videoID && !$0.isShort }
            } catch {
                log.notice("Recommendation fetch failed for \(videoID, privacy: .public): \(String(describing: error), privacy: .public)")
                return []
            }
        }
        recommendationsTask = task
        Task { [weak self] in
            let videos = await task.value
            guard let self, !task.isCancelled, self.currentVideo?.id == videoID else { return }
            self.recommendations = videos
            self.isLoadingRecommendations = false
            self.log.info("Loaded \(videos.count, privacy: .public) recommendations for \(videoID, privacy: .public)")
        }
    }

    private func installObservers() {
        // Fine-grained tick for captions only (`elapsed` ticks every 0.5s, too coarse for
        // caption timing). Does nothing while captions are off.
        captionObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            Task { @MainActor in
                guard !self.captionCues.isEmpty || self.captionText != nil, seconds.isFinite else { return }
                self.updateCaption(at: seconds)
            }
        }

        // Periodic time observation via Combine-friendly bridging.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let item = self.player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite { self.duration = total }
                }
                self.updateNowPlaying()
                self.savePosition(force: false)
                if self.itemVideoID == self.currentVideo?.id, self.pendingResume == nil {
                    self.watchReporter.tick(position: self.elapsed, isPlaying: self.isPlaying)
                }
            }
        }

        // Auto-advance on item end.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Mark finished so reopening the video starts from the beginning.
                if let videoID = self.itemVideoID, videoID == self.currentVideo?.id, self.duration > 0 {
                    self.persistPosition(videoID: videoID, position: self.duration, duration: self.duration)
                    self.watchReporter.tick(position: self.duration, isPlaying: false)
                    self.watchReporter.flush()
                }
                if self.preferences.autoplayNext { self.playNext() }
            }
        }

        // Persist speed changes (`setPlaybackRate`, or anything else that writes `defaultRate`)
        // so the next app launch starts at the same speed.
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            guard let newValue = change.newValue else { return }
            let rate = Double(newValue)
            // Sanity: defaultRate of 0 would mean "paused on play()", which the speed menu never
            // offers. Ignore any such bogus write.
            guard rate > 0 else { return }
            Task { @MainActor in
                self.playbackRate = rate
                if abs(rate - self.preferences.playbackRate) > 0.001 {
                    self.log.info("playbackRate changed → \(rate, privacy: .public) (persisting)")
                    self.preferences.playbackRate = rate
                }
            }
        }

        // Mirror AVPlayer's transport state into `isPlaying`, so the controls' play/pause glyph
        // stays right when playback changes from elsewhere (lock screen, headphones, PiP).
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            Task { @MainActor in
                switch status {
                case .playing:
                    if !self.isPlaying {
                        self.log.info("KVO timeControlStatus → playing (sync isPlaying=true)")
                        self.isPlaying = true
                    }
                case .paused:
                    if self.isPlaying {
                        self.log.info("KVO timeControlStatus → paused (sync isPlaying=false)")
                        self.isPlaying = false
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // Buffering / stalled. Treat as "playing" so the UI still shows the pause icon.
                    if !self.isPlaying {
                        self.isPlaying = true
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func updateNowPlaying() {
        guard let video = currentVideo else { return }
        NowPlayingCenter.update(
            title: video.title,
            artist: video.channelName,
            duration: duration,
            elapsed: elapsed,
            rate: isPlaying ? 1.0 : 0.0,
            artwork: currentArtwork
        )
    }

    /// Resolves an artwork image for the given video and stores it in `currentArtwork`. Tries two
    /// sources in order:
    ///  1. Kingfisher's in-memory cache for the video's `thumbnailURL` (synchronous → no flicker).
    ///  2. Async network/disk fetch through Kingfisher.
    /// Clears artwork immediately so the previous video's preview doesn't linger on the lock screen.
    private func refreshArtwork(for video: Video) {
        currentArtwork = nil

        if let url = video.thumbnailURL,
           let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: url.cacheKey) {
            currentArtwork = cached
            updateNowPlaying()
            return
        }

        // Async network/disk fetch.
        guard let url = video.thumbnailURL else { return }
        KingfisherManager.shared.retrieveImage(with: url) { [weak self, videoID = video.id] result in
            guard case .success(let value) = result else { return }
            Task { @MainActor in
                guard let self else { return }
                // Drop the result if the user switched videos while the fetch was inflight.
                guard self.currentVideo?.id == videoID else { return }
                self.currentArtwork = value.image
                self.updateNowPlaying()
            }
        }
    }
}
