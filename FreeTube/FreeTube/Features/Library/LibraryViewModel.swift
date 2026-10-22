import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class LibraryViewModel {
    private(set) var library: AccountLibrary?
    private(set) var isLoading: Bool = false
    var errorState: ErrorState?

    private let service: any AccountServicing
    private let playlistService: any PlaylistServicing

    init(
        service: any AccountServicing = AccountService(),
        playlistService: any PlaylistServicing = PlaylistService()
    ) {
        self.service = service
        self.playlistService = playlistService
    }

    /// Drops cached library data. Called on sign-out so the next sign-in starts fresh and the
    /// menu's data-driven destinations (Playlists, Your videos) don't keep showing stale entries.
    func clear() {
        library = nil
        errorState = nil
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            library = try await service.fetchLibrary()
        } catch YouTubeServiceError.notAuthenticated {
            // No cookies / signed-out — the library menu degrades to "sign in" prompts and
            // shouldn't surface a toast for this expected state.
            library = nil
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    /// Deletes one of the user's playlists on YouTube, then drops it from the cached library
    /// so the Playlists list and its count update without a refetch.
    func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await playlistService.delete(playlistID: playlist.id)
            forgetPlaylist(id: playlist.id)
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    /// Drops a deleted playlist from the cached library. Also called when it was deleted from
    /// its own screen (`PlaylistScreen`'s ⋯ menu).
    func forgetPlaylist(id: String) {
        guard let current = library else { return }
        library = AccountLibrary(
            history: current.history,
            historyCount: current.historyCount,
            watchLater: current.watchLater,
            watchLaterCount: current.watchLaterCount,
            likedVideos: current.likedVideos,
            likedCount: current.likedCount,
            playlists: current.playlists.filter { $0.id != id },
            userChannelID: current.userChannelID
        )
    }
}
