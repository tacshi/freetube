import SwiftUI
import SwiftData
import UIKit
import OSLog
import Kingfisher

/// The player, presented by `RootView` as a full-screen cover as soon as a video is tapped (there
/// is no mini player). Renders the surface, transport controls, metadata, the toggleable
/// comments / queue panel, and its own Close button; closing stops playback.
@available(iOS 17.0, *)
struct FullScreenPlayer: View {
    @Environment(PlayerStateManager.self) private var player
    @Environment(\.modelContext) private var modelContext
    /// Reactive list of all favorited videos so menu rendering doesn't have to fetch Core Data on
    /// every redraw (per-row SQL on the main queue otherwise).
    @Query private var favorites: [FavoriteVideo]

    /// What's shown in the lower panel. Default is `.queue` so the user can see what's coming up
    /// without an extra tap; they can switch to `.comments` via the toggle on the right of the
    /// transport row.
    @State private var panel: Panel = .queue
    /// Async-loaded description / details for the currently-playing video. Fetched on demand when
    /// the user taps "More" under the channel row.
    @State private var details: VideoInfo?
    /// Are we currently fetching `details`? Drives the spinner in the description area.
    @State private var isLoadingDetails = false
    /// True when the user has expanded the description block — shows full text instead of a
    /// truncated preview, and tries to load extended details (tags etc.) if not yet loaded.
    @State private var isDetailsExpanded = false
    /// Currently-pushed channel (nil = panel mode). When non-nil, the lower section swaps the
    /// metadata + comments/queue panel for a NavigationStack rooted at `ChannelScreen`. Keeping
    /// the NavigationStack **conditionally mounted** is what makes the panel-mode background
    /// match the transport row: SwiftUI's NavigationStack container paints opaque under its
    /// content, so any thinMaterial inside it stacks on top of an opaque layer and reads darker
    /// than the rest of the popup. With the stack absent in panel mode, the outer VStack's
    /// thinMaterial paints through cleanly.
    @State private var pushedChannel: ChannelPresentation?
    /// Path for deeper pushes inside the channel flow (e.g. ChannelScreen → ChannelTabScreen).
    /// Only meaningful while `pushedChannel != nil`.
    @State private var channelPath = NavigationPath()
    /// Non-nil when the user picked "Add to playlist" — drives the `AddToPlaylistSheet`
    /// presentation. We capture the whole `Video` (not just the id) so the sheet can show its
    /// title at the top of the picker.
    @State private var addToPlaylistVideo: Video?
    /// How far the iPadOS window controls reach into the player's top edge (0 when there are
    /// none). The video column is pushed down by this much so the traffic lights don't cover the
    /// player's top bar (in full-screen mode the top bar itself is padded instead). See
    /// `WindowControlsInsetReader`.
    @State private var windowControlsInset: CGFloat = 0
    /// Copy URL is showing its "Copied" confirmation.
    @State private var showsCopied = false
    /// PiP for the video layer; shared by `VideoSurface` (attaches) and the controls (toggle).
    @State private var pictureInPicture = PictureInPictureModel()
    /// Full-screen mode: the video fills the player window and everything else hides.
    @State private var isVideoFullScreen = false

    /// Hashable wrapper so `.navigationDestination(for:)` can match the channel id and push
    /// `ChannelScreen` onto `channelPath`.
    struct ChannelPresentation: Identifiable, Hashable {
        let id: String
    }

    enum Panel { case comments, queue }

    var body: some View {
        // Single dark-blur material under EVERYTHING — status bar inset, video chrome, transport,
        // comments, queue. Removing per-section backgrounds and using one full-screen material lets
        // the popup read as one continuous translucent surface instead of three stacked tones.
        //
        // **Why the outer `GeometryReader`:** we want the video to fill its column edge to edge
        // regardless of how wide vs tall the popup is. `.aspectRatio(16/9, .fit)` clamps the
        // video to whichever dimension is tighter — on iPhone portrait that's always width
        // (the screen is much taller than 16:9), but on Mac (Designed-for-iPad) and iPad
        // landscape the window is wider than 16:9 so `.fit` height-clamps and the video sits
        // letterboxed inside black side bars. Reading the available size via `GeometryReader`
        // and sizing the ZStack to `width × width*9/16` explicitly removes the clamp.
        //
        // The same proxy picks the arrangement: video stacked above the panel (full width) in
        // portrait-shaped windows, video column beside the panel in wide landscape ones — see
        // `usesSideBySideLayout(for:)`.
        GeometryReader { proxy in
            let sideBySide = Self.usesSideBySideLayout(for: proxy.size)
            let videoSize = videoSize(in: proxy.size, sideBySide: sideBySide)
            // `AnyLayout` rather than an `if`/`else` so rotating between the stacked and
            // side-by-side arrangements keeps view identity: the video layer (and its PiP
            // controller) isn't torn down mid-playback, and the comments / queue panel keeps its
            // scroll position.
            let layout = sideBySide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))

            layout {
                VStack(spacing: 0) {
                    videoSurface(size: videoSize)

                    if !isVideoFullScreen {
                        transportRow(showsPanelToggle: !sideBySide)
                            .padding(.vertical, 10)

                        // Side by side, the space under the video holds the video's info and
                        // comments (like YouTube's iPad layout); the right column is Up next.
                        if sideBySide, let video = player.currentVideo {
                            Divider()
                            infoAndComments(video)
                        }
                    }
                }
                .padding(.top, isVideoFullScreen ? 0 : windowControlsInset)
                .frame(width: videoSize.width)

                if !isVideoFullScreen {
                    // Horizontal rule under the transport row when stacked; vertical rule
                    // between the two columns when side by side.
                    Divider()

                    lowerSection(sideBySide: sideBySide)
                }
            }
            // Measured on the whole player (whose frame doesn't move with the padding above),
            // so applying the inset can't feed back into the measurement.
            .background {
                WindowControlsInsetReader { windowControlsInset = $0 }
            }
        // One continuous material under EVERYTHING, including the top safe-area inset (status bar).
        // VStack content still respects safe area; only the material extends behind the inset.
        .background {
            if isVideoFullScreen {
                Color.black.ignoresSafeArea()
            } else {
                Rectangle()
                    .fill(.thinMaterial)
                    .ignoresSafeArea()
            }
        }
        // Light-content (white) status bar glyphs against the dark material; hidden while the
        // video is full screen.
        .preferredColorScheme(.dark)
        .statusBarHidden(isVideoFullScreen)
        .persistentSystemOverlays(isVideoFullScreen ? .hidden : .automatic)
        // Reset description state, (best-effort) prefetch the snippet, AND pop any pushed
        // channel screen whenever the user picks a new video — otherwise tapping the next video
        // in the queue would leave a stale channel push on screen. Lives here (not on the lower
        // section) so hiding the panels in full-screen mode doesn't re-trigger it.
        .onChange(of: player.currentVideo?.id, initial: true) { _, _ in
            details = nil
            isDetailsExpanded = false
            pushedChannel = nil
            channelPath = NavigationPath()
            if let video = player.currentVideo {
                prefetchDescriptionIfAvailable(for: video)
            }
        }
        // "Add to playlist" sheet, presented when the menu sets `addToPlaylistVideo`. The sheet
        // owns its own playlist fetch + "Create new playlist" form — we just hand it the video.
        .sheet(item: $addToPlaylistVideo) { video in
            AddToPlaylistSheet(videoID: video.id, videoTitle: video.title)
        }

        // Make the VStack fill the GeometryReader's bounds. Without this, the VStack only
        // claims the natural content height (video + transport + divider + panel intrinsic
        // height) and the `.background { thinMaterial }` doesn't extend below that. On
        // smaller-than-content windows (Mac shrunk) this is invisible; on larger ones
        // (Mac maximized) you'd see an unfilled gap below the panel.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Layout pieces

    /// Video layer with the player's own controls on top (`PlayerControlsOverlay`). 16:9 in the
    /// normal layouts; in full-screen mode it fills the player and the picture letterboxes.
    private func videoSurface(size: CGSize) -> some View {
        ZStack {
            Color.black
            VideoSurface(player: player.player, pictureInPicture: pictureInPicture)
            PlaybackStatusOverlay(state: player.loadState)
            PlayerControlsOverlay(
                isFullScreen: $isVideoFullScreen,
                pictureInPicture: pictureInPicture,
                topInset: isVideoFullScreen ? windowControlsInset : 0,
                onClose: closePlayer
            )
        }
        .frame(width: size.width, height: size.height)
    }

    private func videoSize(in container: CGSize, sideBySide: Bool) -> CGSize {
        if isVideoFullScreen { return container }
        let width = sideBySide
            ? Self.sideBySideVideoWidth(for: CGSize(width: container.width,
                                                    height: container.height - windowControlsInset))
            : container.width
        return CGSize(width: width, height: width * 9 / 16)
    }

    /// Dismisses the player cover; `RootView`'s `onDismiss` stops playback.
    private func closePlayer() {
        @Bindable var p = player
        p.fullScreenPresented = false
    }

    /// Stacked: metadata + comments / queue panel. Side by side: Up next only (info and comments
    /// live under the video). Either way, the pushed channel stack replaces it when a channel
    /// is open.
    @ViewBuilder
    private func lowerSection(sideBySide: Bool) -> some View {
        if let video = player.currentVideo {
            // **Two render modes for the lower section, picked by `pushedChannel`:**
            //
            // 1. **Panel mode (default, channel == nil):** plain ScrollView, NO
            //    NavigationStack. The outer VStack's `.background { thinMaterial }` paints
            //    behind it directly — exactly the same backdrop the transport row above
            //    shows. This is what makes the visual treatment consistent.
            //
            // 2. **Channel-pushed mode (channel != nil):** NavigationStack rooted at
            //    `ChannelScreen`, with its own thinMaterial inside since the stack's UIKit
            //    container paints opaque. Channel's own internal NavigationLinks (to
            //    ChannelTabScreen / PlaylistScreen) push further into this stack.
            //
            // The previous version kept the NavigationStack mounted in both modes — that
            // forced us to paint an inner thinMaterial under the comments/queue panel,
            // which stacked on top of the stack's opaque container and read noticeably
            // darker than the transport row. Mounting the stack only when needed fixes it.
            Group {
                if let channel = pushedChannel {
                    channelStack(channel)
                } else if sideBySide {
                    upNextColumn
                } else {
                    panel(video)
                }
            }
        }
    }

    // MARK: - Side-by-side layout (iPad landscape, Mac, iPhone landscape)

    /// Minimum popup width before the video and the panel go side by side. Narrower windows
    /// (iPhone portrait, iPad portrait, narrow Split View / Slide Over) keep the stacked layout.
    private static let sideBySideMinWidth: CGFloat = 700
    /// Share of the popup width the video column takes in side-by-side mode.
    private static let sideBySideVideoFraction: CGFloat = 0.6
    /// Transport row height plus its vertical padding (36pt buttons / chips + 2 × 10pt), kept
    /// free under the video when capping the video column to the available height.
    private static let transportReserveHeight: CGFloat = 56

    /// Side by side when the popup is landscape-shaped and wide enough for two usable columns.
    /// Stacked, a full-width video in a landscape window is `width × 9/16` tall: on an iPad that
    /// leaves only a sliver for comments / queue, and on an iPhone it overflows the screen.
    private static func usesSideBySideLayout(for size: CGSize) -> Bool {
        size.width > size.height && size.width >= sideBySideMinWidth
    }

    /// Video column width: a fixed share of the popup, capped so the 16:9 surface and the
    /// transport row fit the height of short windows (Stage Manager, Mac).
    private static func sideBySideVideoWidth(for size: CGSize) -> CGFloat {
        let byWidth = size.width * sideBySideVideoFraction
        let available = size.height - transportReserveHeight
        let byHeight = max(0, available) * 16 / 9
        return min(byWidth, byHeight)
    }

    // MARK: - Lower section: panel vs channel-push

    /// Default panel mode. No NavigationStack wrapping — the outer popup's `.thinMaterial`
    /// shows through directly, giving the same backdrop as the transport row above.
    @ViewBuilder
    private func panel(_ video: Video) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadata(video)
                detailsSection(video: video)
                switch self.panel {
                case .comments:
                    CommentsSection(videoID: video.id)
                case .queue:
                    queuePanel
                }
            }
            .padding(.vertical)
        }
        .scrollContentBackground(.hidden)
    }

    /// Side-by-side left column under the transport row: title, channel, description and
    /// comments, scrolling independently of the Up next column.
    @ViewBuilder
    private func infoAndComments(_ video: Video) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadata(video)
                detailsSection(video: video)
                CommentsSection(videoID: video.id)
            }
            .padding(.vertical)
        }
        .scrollContentBackground(.hidden)
    }

    /// Side-by-side right column: the Up next queue on its own.
    private var upNextColumn: some View {
        ScrollView {
            queuePanel
                .padding(.vertical)
        }
        .scrollContentBackground(.hidden)
    }

    /// NavigationStack rooted at `ChannelScreen`. Mounted only when `pushedChannel != nil`.
    /// Internal `NavigationLink`s inside `ChannelScreen` push onto `channelPath`; popping the
    /// last item via our back button returns to panel mode.
    @ViewBuilder
    private func channelStack(_ root: ChannelPresentation) -> some View {
        NavigationStack(path: $channelPath) {
            channelDestination(root, isRoot: true)
                .navigationDestination(for: ChannelPresentation.self) { channel in
                    channelDestination(channel, isRoot: false)
                }
        }
    }

    /// Single channel destination — used for both the root channel (pushed from the player) and
    /// any further pushes via NavigationLink. The back button pops `channelPath` when there's
    /// something on it, otherwise clears `pushedChannel` to return to panel mode.
    @ViewBuilder
    private func channelDestination(_ channel: ChannelPresentation, isRoot: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            ChannelScreen(channelID: channel.id)
                .toolbar(.hidden, for: .navigationBar)
                // Solid black, matching the playlist push inside this same NavigationStack.
                // We deliberately don't use `.thinMaterial` here — pushed destinations inside
                // the popup body use opaque black for visual consistency with PlaylistScreen,
                // while the panel-mode comments/queue area keeps the popup's outer thinMaterial.
                .background {
                    Color.black.ignoresSafeArea()
                }

            Button {
                if !channelPath.isEmpty {
                    channelPath.removeLast()
                } else {
                    pushedChannel = nil
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .padding(.top, 8)
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadata(_ video: Video) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(video.title)
                .font(.title3.weight(.semibold))
            // Tapping anywhere on the channel row pushes the channel detail screen onto the
            // popup's internal NavigationStack — banner, subscribe button, latest videos,
            // shorts, playlists. Pushing (rather than presenting) keeps the video surface and
            // transport controls visible at the top; only the panel area below is replaced.
            if !video.channelID.isEmpty {
                Button {
                    pushedChannel = ChannelPresentation(id: video.channelID)
                } label: {
                    channelRow(video)
                }
                .buttonStyle(.plain)
            } else {
                channelRow(video)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func channelRow(_ video: Video) -> some View {
        HStack(spacing: 12) {
            KFImage(video.channelThumbnailURL)
                .thumbnail(size: CGSize(width: 32, height: 32)) {
                    Circle().fill(.gray.opacity(0.2))
                }
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            Text(video.channelName).font(.subheadline)
            Spacer()
        }
    }

    // MARK: - Description / details (between channel row and comments)

    /// Shows the video description in a YouTube-like collapsed-by-default block. Snippet first
    /// (if the model has one), with a "More" button under the channel row that expands the block
    /// and fetches the full details payload (description text + view count + tags etc.).
    @ViewBuilder
    private func detailsSection(video: Video) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDetailsExpanded {
                expandedDetailsBody(video: video)
            } else {
                collapsedDetailsBody(video: video)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func collapsedDetailsBody(video: Video) -> some View {
        if let snippet = inlineDescriptionSnippet(video: video) {
            Text(snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        Button {
            isDetailsExpanded = true
            loadDetailsIfNeeded(for: video)
        } label: {
            HStack(spacing: 6) {
                Text("More")
                Image(systemName: "chevron.down")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func expandedDetailsBody(video: Video) -> some View {
        // Full description text (from the loaded details, falling back to the search-result snippet).
        if let text = details?.descriptionText ?? video.descriptionSnippet, !text.isEmpty {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        } else if isLoadingDetails {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading details…").font(.caption).foregroundStyle(.secondary)
            }
        }

        // Quick stats line: views • published date • duration.
        let statsRow = detailsStatsRow(video: video)
        if !statsRow.isEmpty {
            Text(statsRow)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // Like count if we got it from the details payload.
        if let likes = details?.likeCount, likes > 0 {
            Text("\(formatCount(likes)) likes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button {
            isDetailsExpanded = false
        } label: {
            HStack(spacing: 6) {
                Text("Show less")
                Image(systemName: "chevron.up")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Picks the description text to render in the 2-line collapsed preview. Prefer the loaded
    /// details (more complete), fall back to the search-result snippet.
    private func inlineDescriptionSnippet(video: Video) -> String? {
        let raw = details?.descriptionText ?? video.descriptionSnippet
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// `42K views • 3 days ago • 4:32`, omitting any pieces we don't have.
    private func detailsStatsRow(video: Video) -> String {
        var parts: [String] = []
        if let views = video.viewCount, views > 0 {
            parts.append("\(formatCount(views)) views")
        }
        if let published = video.publishedAt {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .short
            parts.append(relative.localizedString(for: published, relativeTo: .now))
        }
        if !video.durationString.isEmpty {
            parts.append(video.durationString)
        }
        return parts.joined(separator: " • ")
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Best-effort: if `descriptionSnippet` is already on the `Video` (from search/home), we have
    /// something to show without hitting the network. Don't preemptively fetch the full details —
    /// the user might never tap "More".
    private func prefetchDescriptionIfAvailable(for video: Video) {
        // Intentional no-op. The fetch happens on the user's first "More" tap.
        _ = video
    }

    /// Lazy fetch invoked when the user expands the description. One `VideoService.fetchInfo`
    /// call per video; subsequent expansions reuse the cached result in `details`.
    private func loadDetailsIfNeeded(for video: Video) {
        guard details == nil, !isLoadingDetails else { return }
        isLoadingDetails = true
        Task { [videoID = video.id] in
            defer { Task { @MainActor in isLoadingDetails = false } }
            do {
                let info = try await VideoService().fetchInfo(id: videoID)
                await MainActor.run {
                    // Drop the result if the user switched videos before this returned.
                    guard player.currentVideo?.id == videoID else { return }
                    details = info
                }
            } catch {
                // Network failure is non-fatal — collapsed view still shows the snippet if any.
            }
        }
    }

    // MARK: - Transport

    /// Row under the video: the video's actions (Like, Save, Copy URL) and — stacked layout only —
    /// the queue / comments toggle. Play/pause, seeking and close live on the video itself
    /// (`PlayerControlsOverlay`), so they aren't repeated here;
    /// previous / next are covered by the Up next list and the lock-screen remote.
    ///
    /// `showsPanelToggle`: the queue / comments switch only matters in the stacked layout, where
    /// the two share one panel; side by side both are always visible.
    private func transportRow(showsPanelToggle: Bool) -> some View {
        // Each button takes an equal-width slot, so the row reads as evenly spaced and centered
        // whether it holds one action (signed out) or four (signed in + queue toggle).
        HStack(spacing: 0) {
            if let video = player.currentVideo {
                if isSignedIn {
                    actionButton("Like", systemImage: isFavorite(video) ? "hand.thumbsup.fill" : "hand.thumbsup") {
                        toggleFavorite(video)
                    }
                    actionButton("Save", systemImage: "text.badge.plus") {
                        addToPlaylistVideo = video
                    }
                }
                actionButton(
                    showsCopied ? "Copied" : "Copy URL",
                    systemImage: showsCopied ? "checkmark" : "link"
                ) {
                    if let url = watchURL(video) {
                        UIPasteboard.general.string = url.absoluteString
                        flashCopied()
                    }
                }
            }
            if showsPanelToggle {
                queueToggleButton
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: - Actions

    /// Like and Save are auth-gated in `transportRow` — signed out, the YouTube endpoints they
    /// call would just throw `.notAuthenticated`.
    private func actionButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Swaps Copy URL to "Copied ✓" for a moment so the copy is visibly confirmed.
    private func flashCopied() {
        withAnimation(.snappy) { showsCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy) { showsCopied = false }
        }
    }

    /// True when `AuthState` reports a logged-in session. Drives auth-gated visibility of the
    /// Like and Save chips.
    private var isSignedIn: Bool {
        if case .loggedIn = AuthState.shared.status { return true }
        return false
    }

    private func watchURL(_ video: Video) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(video.id)")
    }


    /// O(N) check against the already-loaded `favorites` array — no Core Data per call. With
    /// reasonable favorite counts this is effectively free, and avoids the per-menu-render SQL hit
    /// that was lagging the UI elsewhere.
    private func isFavorite(_ video: Video) -> Bool {
        favorites.contains(where: { $0.videoID == video.id })
    }

    /// Toggles the video in the local SwiftData favorites table AND, when signed in, syncs the
    /// change to YouTube via `LikeVideoResponse` / `RemoveLikeFromVideoResponse`. The local
    /// store doubles as the "Liked Videos" cache for offline browsing — even after sign-out the
    /// user can still see what they liked while signed in.
    private func toggleFavorite(_ video: Video) {
        let wasFavorite = favorites.contains(where: { $0.videoID == video.id })
        if wasFavorite {
            for existing in favorites where existing.videoID == video.id {
                modelContext.delete(existing)
            }
        } else {
            modelContext.insert(FavoriteVideo(
                videoID: video.id,
                title: video.title,
                channelName: video.channelName,
                thumbnailURL: video.thumbnailURL
            ))
        }
        try? modelContext.save()

        // Mirror to YouTube when signed in. Fire-and-forget — the local store is the source of
        // truth for UI state, and a network failure on the YouTube side shouldn't undo the
        // user's intent. We do log the failure for diagnostics.
        if isSignedIn {
            let log = AppLog(subsystem: "com.leshko.freetube", category: "FullScreenPlayer")
            Task {
                do {
                    let actions: any VideoActionsServicing = VideoActionsService()
                    if wasFavorite {
                        try await actions.removeRating(videoID: video.id)
                    } else {
                        try await actions.like(videoID: video.id)
                    }
                } catch {
                    log.error("[favorites] YouTube sync failed for \(video.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: - Queue toggle (right of transport)

    @ViewBuilder
    private var queueToggleButton: some View {
        // Active state is the accent-colored glyph — no capsule highlight behind it.
        Button {
            withAnimation(.snappy) {
                panel = (panel == .queue) ? .comments : .queue
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(panel == .queue ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Queue controls (shuffle + repeat)

    /// Shuffle pill — active = capsule highlight behind the glyph, same icon color. Tap toggles
    /// `QueueManager.isShuffleOn` which rebuilds the play order on the queue manager itself.
    @ViewBuilder
    private var shuffleButton: some View {
        Button {
            player.queue.isShuffleOn.toggle()
        } label: {
            Image(systemName: "shuffle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 28)
                .background {
                    if player.queue.isShuffleOn {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// Repeat pill — cycles through .off → .all → .one → .off. Active states (.all and .one) get
    /// the capsule highlight; `.one` swaps to the `repeat.1` SF Symbol so the user can see the
    /// single-track variant at a glance.
    @ViewBuilder
    private var repeatButton: some View {
        Button {
            switch player.queue.repeatMode {
            case .off: player.queue.repeatMode = .all
            case .all: player.queue.repeatMode = .one
            case .one: player.queue.repeatMode = .off
            }
        } label: {
            Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 28)
                .background {
                    if player.queue.repeatMode != .off {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Queue panel sizing

    /// Fixed height of one queue row's content area. 56pt accommodates the 80×45 thumbnail with
    /// a hair of breathing room. Combined with our `.listRowInsets(top: 4, bottom: 4)` each row
    /// occupies 64pt of vertical space in the List.
    private static let queueRowHeight: CGFloat = 56

    /// Per-row footprint including insets, used by `queueListHeight` below.
    private static let queueRowFootprint: CGFloat = queueRowHeight + 8 // 4pt top + 4pt bottom insets

    /// Total height we hand to the queue `List`. Sized for the actual number of items + a 32pt
    /// bottom margin so the last row's edit-handle / swipe affordance isn't truncated.
    private var queueListHeight: CGFloat {
        let count = max(1, player.queue.items.count)
        return CGFloat(count) * Self.queueRowFootprint + 32
    }

    // MARK: - Queue panel

    @ViewBuilder
    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Up next")
                Spacer()
                shuffleButton
                repeatButton
            }
            .padding(.horizontal)
            // `List` is the cleanest source of drag-to-reorder + swipe-to-delete in SwiftUI. We're
            // already inside a ScrollView, so we cap the list with a generous fixed height so it
            // doesn't try to consume the outer scroll's gesture space.
            List {
                ForEach(player.queue.items) { video in
                    queueRow(video)
                        .listRowBackground(Color.clear)
                        // Pin a deterministic row height so the outer `.frame(height:)` below can
                        // calculate the exact List size — otherwise iOS's auto-sized rows end up
                        // slightly taller than our estimate and the last row gets clipped.
                        .frame(height: Self.queueRowHeight)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .onMove { source, destination in
                    let from = source.first ?? 0
                    player.queue.move(from: from, to: destination)
                }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) {
                        player.queue.remove(at: index)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .scrollDisabled(true)
            // Row height (`queueRowHeight`) + insets (`4+4`) + a tail margin so the last row's
            // bottom edge isn't flush with the next sibling view in the outer scroll.
            .frame(height: queueListHeight)
        }
    }

    @ViewBuilder
    private func queueRow(_ video: Video) -> some View {
        HStack(spacing: 0) {
            Button {
                player.load(video)
            } label: {
                HStack(spacing: 12) {
                    // Thumbnail with duration badge in the bottom-right corner — same affordance
                    // YouTube uses on its own video tiles. Costs no extra row height.
                    ZStack(alignment: .bottomTrailing) {
                        KFImage(video.thumbnailURL)
                            .thumbnail(size: CGSize(width: 80, height: 45)) {
                                Color.gray.opacity(0.2)
                            }
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 45)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        if !video.durationString.isEmpty {
                            Text(video.durationString)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 3))
                                .padding(3)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title)
                            .font(.subheadline)
                            .lineLimit(2)
                        // Channel name + playback count joined by a middle dot. Either piece can be
                        // empty (older listings sometimes omit view count), filter before joining so
                        // there are no stray separators.
                        Text(queueRowMetadata(for: video))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if video.id == player.currentVideo?.id {
                        // Animated audio bars instead of the static speaker glyph. Animates only
                        // for the matched row; other rows render nothing because the parent `if`
                        // gates mounting.
                        NowPlayingIndicator(videoID: video.id)
                    }
                }
            }
            .buttonStyle(.plain)

            // Sibling of the load-button so taps land in the Menu instead of the row's
            // play handler. Same actions as the row would get in search/history/library.
            VideoMoreActionsMenu(video: video)
        }
    }

    /// "Channel • 1.2M views" for the queue row's second line. Drops the dot if either side is
    /// missing so we never render a dangling separator.
    private func queueRowMetadata(for video: Video) -> String {
        [video.channelName, video.viewCountString]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}
