import SwiftUI
import SwiftData
import Kingfisher

/// Playlist detail screen. Top-down layout:
///   1. Large playlist artwork
///   2. Title + channel + video-count metadata
///   3. Glass-pill action toolbar — Play all / Shuffle all + More menu
///   4. List of videos
///
/// A `List` rather than a `ScrollView` so video rows get swipe actions: swipe left removes the
/// video when `PlaylistViewModel.canRemoveVideos` (the user's own playlists, Watch later,
/// Liked videos). Other people's playlists get no swipe action. Deleting the whole playlist
/// lives in the ⋯ menu, for the user's own playlists only.
@available(iOS 17.0, *)
struct PlaylistScreen: View {
    @State private var model: PlaylistViewModel
    @Environment(PlayerStateManager.self) private var player
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// Reactive list of saved-playlist favorites so the More menu can show the right
    /// "Add to favorites" / "Remove from favorites" state without a per-render fetch.
    @Query private var favorites: [FavoritePlaylist]

    /// True after the user taps "More" — expands the metadata block to show the full description
    /// and every available stat (view count + video count + creator). Collapsed by default so the
    /// header stays compact and the video list isn't pushed below the fold.
    @State private var isDetailsExpanded = false

    @State private var isConfirmingDelete = false

    /// Called after the playlist was deleted from the ⋯ menu, before the screen pops — lets
    /// the Library's Playlists list drop it without a refetch.
    private let onDeleted: (() -> Void)?

    init(playlistID: String, onDeleted: (() -> Void)? = nil) {
        _model = State(wrappedValue: PlaylistViewModel(playlistID: playlistID))
        self.onDeleted = onDeleted
    }

    var body: some View {
        List {
            if let details = model.details {
                // Header row: artwork + metadata + toolbar inside a leading-aligned VStack,
                // with the blurred-artwork backdrop applied via `.background { … }`. The
                // VStack's `.frame(maxWidth: .infinity, alignment: .leading)` forces full-width
                // layout — a `ZStack(alignment: .top)` would center-align horizontally.
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        artworkHeader(details)
                        metadataBlock(details)
                        actionToolbar(details)
                    }
                    // Cap the header column on wide layouts; the blurred backdrop below stays
                    // full-bleed because it's applied after the full-width frame.
                    .readableContentWidth()
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        blurredArtworkBackground(for: details)
                    }

                    // Full-bleed divider — no horizontal padding so the line spans edge to edge.
                    Divider()
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                videosList(details.videos)
            } else if model.isLoading {
                LoadingView()
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        // Hide the navigation bar's own background so the blurred artwork shows through it —
        // without this the nav bar paints its standard translucent material on top, hiding the
        // top edge of the backdrop.
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await model.load() }
        .errorToast(Bindable(model).errorState)
        .confirmationDialog(
            "Delete this playlist?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete playlist", role: .destructive) {
                Task {
                    if await model.deletePlaylist() {
                        onDeleted?()
                        dismiss()
                    }
                }
            }
        } message: {
            if let title = model.details?.playlist.title {
                Text("\"\(title)\" will be deleted from your YouTube account.")
            }
        }
    }

    // MARK: - Blurred artwork backdrop

    /// Heavily-blurred, dimmed copy of the playlist artwork, layered behind the header row.
    /// It stops at the bottom of the toolbar (the divider underneath) and overflows the row's
    /// top edge by `overscan`, so it reaches up under the navigation and status bars — and
    /// covers the pull-down bounce. List rows don't clip, and nothing sits above the header.
    ///
    /// Three layers stacked inside:
    ///   1. The artwork itself, `.resizable().scaledToFill().blur(radius: 60)`.
    ///   2. A dark overlay (`Color.black.opacity(0.55)`) for foreground-text contrast.
    ///   3. A subtle bottom-edge gradient that fades into the screen background so the divider
    ///      below doesn't look pasted on.
    @ViewBuilder
    private func blurredArtworkBackground(for details: PlaylistDetails) -> some View {
        let url = details.playlist.thumbnailURL ?? details.videos.first?.thumbnailURL
        ZStack {
            // Heavy blur — we can downsample aggressively (200×112) since the source pixels
            // are mostly thrown away by the 60-radius blur anyway.
            KFImage(url)
                .thumbnail(size: CGSize(width: 200, height: 112)) {
                    Color.black
                }
                .resizable()
                .scaledToFill()
                .blur(radius: 60)
            Color.black.opacity(0.55)
            LinearGradient(
                colors: [Color.clear, Color.clear, Color.black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
        .padding(.top, -overscan)
    }

    /// How far the blurred backdrop reaches above the header row.
    private let overscan: CGFloat = 400

    // MARK: - Artwork

    /// Full-bleed playlist artwork at the top — uses the playlist's own thumbnail when present,
    /// falls back to the first video's thumbnail (YouTubeKit doesn't always return a playlist
    /// banner). 16:9 aspect ratio keeps the layout stable across loading states.
    @ViewBuilder
    private func artworkHeader(_ details: PlaylistDetails) -> some View {
        let url = details.playlist.thumbnailURL ?? details.videos.first?.thumbnailURL
        KFImage(url)
            .thumbnail(size: CGSize(width: 400, height: 225)) {
                Color.gray.opacity(0.15)
            }
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .aspectRatio(16/9, contentMode: .fill)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - Metadata

    /// Title + always-visible labeled stat rows (Videos, Views, Description) + a collapsible
    /// description preview/full toggle. The "More details" pill no longer hides the counters —
    /// they're shown unconditionally so the user sees them on first render. The button now only
    /// toggles the description between a 2-line preview and the full text.
    ///
    /// **Why the fallback on Videos:** YouTubeKit's `processNewInfoModel` doesn't extract
    /// `videoCount` / `viewCount` — only the legacy `playlistHeaderRenderer` path does. Most
    /// modern playlists arrive in the new format, so `playlist.videoCount` is nil even for
    /// large playlists. We fall back to `details.videos.count` (with a `+` suffix when there
    /// are more pages to load) so the row never says "nil videos".
    @ViewBuilder
    private func metadataBlock(_ details: PlaylistDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(details.playlist.title)
                .font(.title3.weight(.semibold))
                .lineLimit(3)

            if let channelName = details.playlist.channelName, !channelName.isEmpty {
                Text(channelName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Stats rows — always rendered. Videos has a guaranteed fallback; Views and
            // Description self-hide when nil/empty.
            VStack(alignment: .leading, spacing: 6) {
                statRow(label: "Videos", value: videoCountLabel(for: details))
                statRow(label: "Views", value: viewsLabel(for: details))
                descriptionRow(details.playlist.descriptionText)
            }

            if shouldShowMoreButton(for: details.playlist.descriptionText) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isDetailsExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(isDetailsExpanded ? "Less" : "More details")
                        Image(systemName: isDetailsExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    /// "{N} videos" using YouTubeKit's parsed total when present, otherwise the loaded count
    /// with a `+` when more pages remain.
    private func videoCountLabel(for details: PlaylistDetails) -> String {
        if let total = details.playlist.videoCount {
            return "\(total)"
        }
        let suffix = details.continuationToken != nil ? "+" : ""
        return "\(details.videos.count)\(suffix)"
    }

    /// Compact view count string, or nil if YouTube didn't return one (new-format playlists).
    private func viewsLabel(for details: PlaylistDetails) -> String? {
        guard let views = details.playlist.viewCount else { return nil }
        return formattedAbbreviated(views)
    }

    /// Description row — switches between a 2-line preview (collapsed) and the full untruncated
    /// text (expanded). Hidden entirely when the playlist has no description.
    @ViewBuilder
    private func descriptionRow(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text("Description")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 84, alignment: .leading)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(isDetailsExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// We only show "More details" when there's a description that could plausibly need
    /// expansion. With no description, the counter rows are static and there's nothing to toggle.
    private func shouldShowMoreButton(for description: String?) -> Bool {
        guard let description, !description.isEmpty else { return false }
        // Cheap heuristic — anything over ~100 chars likely wraps past 2 lines on iPhone widths.
        return description.count > 100
    }

    /// Single labeled stat row. Hides itself when the value is nil/empty so the expanded block
    /// only shows fields YouTube actually returned. Uses top alignment so multi-line values
    /// (like the description) wrap underneath their own column without dragging the label down
    /// to the middle of the block.
    @ViewBuilder
    private func statRow(label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 84, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func formattedAbbreviated(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    // MARK: - Glass toolbar

    /// Horizontal row of capsule pills with `.ultraThinMaterial` backdrops. Three primary
    /// actions on the left, a `Menu` for secondary actions on the right.
    @ViewBuilder
    private func actionToolbar(_ details: PlaylistDetails) -> some View {
        HStack(spacing: 10) {
            glassPill(title: "Play all", systemImage: "play.fill") {
                guard !details.videos.isEmpty else { return }
                player.queue.replace(with: details.videos)
                // `skipRecommendations: true` — the user explicitly chose the playlist as their
                // queue, so we don't want YouTube's "more like this" picks appended underneath.
                if let first = details.videos.first {
                    player.load(first, skipRecommendations: true)
                }
            }
            glassPill(title: "Shuffle", systemImage: "shuffle") {
                guard !details.videos.isEmpty else { return }
                let shuffled = details.videos.shuffled()
                player.queue.replace(with: shuffled)
                player.queue.isShuffleOn = true
                if let first = shuffled.first {
                    player.load(first, skipRecommendations: true)
                }
            }
            Spacer(minLength: 0)
            moreMenu(details)
        }
        .padding(.horizontal)
    }

    /// Capsule action button styled to match the "glass" look used on the full-screen player —
    /// `.ultraThinMaterial` backdrop, hairline white stroke, white icon + label.
    private func glassPill(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// "More actions" pill — same capsule chrome as the primary actions, just with an ellipsis
    /// icon. Hosts the secondary menu (open in browser / favorite / copy URL).
    @ViewBuilder
    private func moreMenu(_ details: PlaylistDetails) -> some View {
        let isFavorite = favorites.contains { $0.playlistID == details.playlist.id }
        Menu {
            if let url = playlistURL(details.playlist.id) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                Button {
                    UIPasteboard.general.string = url.absoluteString
                } label: {
                    Label("Copy URL", systemImage: "link")
                }
            }
            Button {
                toggleFavorite(playlist: details.playlist, isFavorite: isFavorite)
            } label: {
                if isFavorite {
                    Label("Remove from favorites", systemImage: "hand.thumbsup.fill")
                } else {
                    Label("Add to favorites", systemImage: "hand.thumbsup")
                }
            }
            if model.canDeletePlaylist {
                Divider()
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete playlist", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }

    // MARK: - Videos

    @ViewBuilder
    private func videosList(_ videos: [Video]) -> some View {
        Group {
            ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                VideoRow(video: video) {
                    // Make sure the queue reflects the playlist's order before kicking off
                    // playback, so "next video" actually means the next playlist entry.
                    player.queue.replace(with: videos)
                    player.load(video)
                }
                .padding(.horizontal)
                .readableContentWidth()
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions {
                    if model.canRemoveVideos {
                        Button(role: .destructive) {
                            Task { await model.remove(video) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .onAppear {
                    // Trigger the next-page fetch when the row 5 from the bottom appears.
                    // PlaylistService caches the continuation token on the response struct, so
                    // each `loadMore` advances the cursor for subsequent calls.
                    if index >= videos.count - 5, model.canLoadMore {
                        Task { await model.loadMore() }
                    }
                }
            }
            if model.canLoadMore || model.isLoadingMore {
                // Bottom spinner that doubles as a safety-net trigger for very short lists
                // where the 5-row lookahead doesn't fire.
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onAppear {
                    if model.canLoadMore { Task { await model.loadMore() } }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleFavorite(playlist: Playlist, isFavorite: Bool) {
        if isFavorite {
            for fav in favorites where fav.playlistID == playlist.id {
                modelContext.delete(fav)
            }
        } else {
            modelContext.insert(FavoritePlaylist(
                playlistID: playlist.id,
                title: playlist.title,
                channelName: playlist.channelName ?? "",
                thumbnailURL: playlist.thumbnailURL,
                videoCount: playlist.videoCount
            ))
        }
        try? modelContext.save()
    }

    /// YouTube's playlist URLs use the bare playlist id, stripping the `VL` prefix YouTubeKit
    /// adds for browse requests.
    private func playlistURL(_ id: String) -> URL? {
        let bare = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
        return URL(string: "https://www.youtube.com/playlist?list=\(bare)")
    }
}
