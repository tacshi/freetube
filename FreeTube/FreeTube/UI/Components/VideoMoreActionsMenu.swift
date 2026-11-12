import SwiftUI
import SwiftData
import UIKit
import OSLog

/// Reusable trailing ellipsis Menu for `Video` items. Used by search results, history,
/// the playback queue, and anywhere else a video appears in a list. Owns its own favorites
/// `@Query` and add-to-playlist sheet so callers just drop it in next to
/// the row's main tap target.
///
/// Auth-gating rules (per product spec):
///   - Open in browser, Copy URL: always shown
///   - Download (or, once downloaded, Share video file… / Remove download): always shown,
///     except Download on live streams
///   - Add to favorites / Remove from favorites: shown only when signed in
///   - Add to playlist: shown only when signed in
///   - Not interested: shown only where the hosting feed set `notInterestedAction` and YouTube
///     offered it for this video (signed-in home feed)
@available(iOS 17.0, *)
struct VideoMoreActionsMenu: View {
    let video: Video

    @Environment(\.modelContext) private var modelContext
    @Environment(\.notInterestedAction) private var notInterestedAction
    @Query private var favorites: [FavoriteVideo]

    @State private var addToPlaylistVideo: Video?
    @State private var downloads = DownloadManager.shared
    @State private var sharedFile: URL?

    var body: some View {
        Menu {
            menuContent
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(item: $addToPlaylistVideo) { video in
            AddToPlaylistSheet(videoID: video.id, videoTitle: video.title)
        }
        .fileShareSheet($sharedFile)
    }

    @ViewBuilder
    private var menuContent: some View {
        Button {
            if let url = watchURL { UIApplication.shared.open(url) }
        } label: {
            Label("Open in browser", systemImage: "safari")
        }
        Button {
            if let url = watchURL { UIPasteboard.general.string = url.absoluteString }
        } label: {
            Label("Copy URL", systemImage: "link")
        }
        downloadItems
        if isSignedIn {
            Divider()
            Button {
                toggleFavorite()
            } label: {
                if isFavorite {
                    Label("Remove from favorites", systemImage: "hand.thumbsup.fill")
                } else {
                    Label("Add to favorites", systemImage: "hand.thumbsup")
                }
            }
            Button {
                addToPlaylistVideo = video
            } label: {
                Label("Add to playlist", systemImage: "text.badge.plus")
            }
        }
        if let notInterestedAction, notInterestedAction.isAvailable(video) {
            Divider()
            Button {
                notInterestedAction.perform(video)
            } label: {
                Label("Not interested", systemImage: "nosign")
            }
        }
    }

    /// Download, or — once the video is a file — share it to another app / remove it.
    @ViewBuilder
    private var downloadItems: some View {
        if let file = downloads.localFile(for: video.id) {
            Button {
                sharedFile = file
            } label: {
                Label("Share video file…", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                downloads.delete(videoID: video.id)
            } label: {
                Label("Remove download", systemImage: "trash")
            }
        } else if let job = downloads.job(for: video.id), job.isActive {
            Button {
                downloads.cancel(videoID: video.id)
            } label: {
                Label("Cancel download", systemImage: "xmark")
            }
        } else if !video.isLive {
            Button {
                downloads.download(video)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
    }

    // MARK: - Helpers

    private var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(video.id)")
    }

    private var isSignedIn: Bool {
        if case .loggedIn = AuthState.shared.status { return true }
        return false
    }

    private var isFavorite: Bool {
        favorites.contains { $0.videoID == video.id }
    }

    /// Toggles the local favorite + (when signed in) fires the YouTube like/unlike sync.
    /// Mirrors `FullScreenPlayer.toggleFavorite` so the behaviour is identical wherever the
    /// menu appears.
    private func toggleFavorite() {
        let wasFavorite = isFavorite
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

        if isSignedIn {
            let log = AppLog(subsystem: "com.leshko.freetube", category: "VideoMoreActionsMenu")
            Task { [videoID = video.id] in
                do {
                    let actions: any VideoActionsServicing = VideoActionsService()
                    if wasFavorite {
                        try await actions.removeRating(videoID: videoID)
                    } else {
                        try await actions.like(videoID: videoID)
                    }
                } catch {
                    log.error("[favorites] YouTube sync failed for \(videoID, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
