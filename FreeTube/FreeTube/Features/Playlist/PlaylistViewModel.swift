import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class PlaylistViewModel {
    let playlistID: String
    private(set) var details: PlaylistDetails?
    private(set) var isLoading: Bool = false
    /// Separate flag so the row-level prefetch trigger doesn't fire while a previous
    /// `loadMore` is still in flight.
    private(set) var isLoadingMore: Bool = false
    var errorState: ErrorState?

    private let service: any PlaylistServicing
    private let videoActions: any VideoActionsServicing

    init(
        playlistID: String,
        service: any PlaylistServicing = PlaylistService(),
        videoActions: any VideoActionsServicing = VideoActionsService()
    ) {
        self.playlistID = playlistID
        self.service = service
        self.videoActions = videoActions
    }

    /// Bare playlist id — `VLWL` and `WL` both mean Watch later.
    private var bareID: String {
        playlistID.hasPrefix("VL") ? String(playlistID.dropFirst(2)) : playlistID
    }

    /// True when the user can remove videos from this playlist: their own playlists (YouTube
    /// marks them editable), Watch later, and Liked videos (removing there removes the like).
    var canRemoveVideos: Bool {
        bareID == "LL" || bareID == "WL" || details?.playlist.isOwnedByUser == true
    }

    /// True for the user's own playlists, which they can delete from the ⋯ menu. Watch later
    /// and Liked videos are built in and can't be deleted.
    var canDeletePlaylist: Bool {
        bareID != "LL" && bareID != "WL" && details?.playlist.isOwnedByUser == true
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            details = try await service.fetchPlaylist(id: playlistID)
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    /// True when the current page has a continuation token and no fetch is in flight.
    var canLoadMore: Bool {
        details?.continuationToken != nil && !isLoadingMore && !isLoading
    }

    /// Appends the next page of videos from the playlist's continuation. Replaces `details`
    /// with a new value (so `@Observable` notices), preserving the playlist header and the
    /// already-loaded videos.
    func loadMore() async {
        guard let current = details, let token = current.continuationToken, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchMore(continuation: token)
            details = PlaylistDetails(
                playlist: current.playlist,
                videos: current.videos + page.videos,
                continuationToken: page.continuationToken
            )
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func move(from source: IndexSet, to destination: Int) async {
        guard
            let details,
            let sourceIndex = source.first
        else { return }
        let item = details.videos[sourceIndex]
        do {
            try await service.move(playlistVideoID: item.id, in: playlistID, toIndex: destination)
            await load()
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    /// Deletes the whole playlist from the user's YouTube account. Returns false (and sets
    /// `errorState`) when YouTube refuses, so the screen stays put.
    func deletePlaylist() async -> Bool {
        do {
            try await service.delete(playlistID: playlistID)
            return true
        } catch {
            errorState = ErrorState(from: error)
            return false
        }
    }

    /// Removes `video` from the playlist. The row disappears right away and comes back if
    /// YouTube refuses. Liked videos is special: YouTube keeps it in sync with ratings, so
    /// the removal is an un-like.
    func remove(_ video: Video) async {
        guard let current = details,
              let index = current.videos.firstIndex(where: { $0.id == video.id })
        else { return }
        var videos = current.videos
        videos.remove(at: index)
        details = PlaylistDetails(playlist: current.playlist, videos: videos, continuationToken: current.continuationToken)
        do {
            if bareID == "LL" {
                try await videoActions.removeRating(videoID: video.id)
            } else {
                try await service.removeVideo(byID: video.id, from: playlistID)
            }
        } catch {
            if let latest = details, !latest.videos.contains(where: { $0.id == video.id }) {
                var restored = latest.videos
                restored.insert(video, at: min(index, restored.count))
                details = PlaylistDetails(playlist: latest.playlist, videos: restored, continuationToken: latest.continuationToken)
            }
            errorState = ErrorState(from: error)
        }
    }
}
