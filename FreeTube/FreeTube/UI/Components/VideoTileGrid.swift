import SwiftUI

/// Adaptive grid of `VideoCard` tiles for regular-width layouts (iPad, Mac). Column count
/// follows the available width — two columns in a half-screen iPad window, three or four
/// full-screen — so the feed fills the screen without stretching one thumbnail across it.
///
/// Lazy, so `onItemAppear` works for pagination the same way `List` row `onAppear` does.
/// Compact-width screens keep their single-column `List`; callers branch on
/// `horizontalSizeClass` and only use this grid for `.regular`.
@available(iOS 17.0, *)
struct VideoTileGrid: View {
    /// Columns for video tiles.
    static let columns = [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)]
    /// Columns for compact rows (channels, playlists) laid out as tiles alongside a video grid.
    static let rowColumns = [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)]

    let videos: [Video]
    var showsMoreMenu: Bool = true
    let onPlay: (Video) -> Void
    var onItemAppear: (Video) -> Void = { _ in }

    var body: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 24) {
            ForEach(videos) { video in
                VideoCard(
                    video: video,
                    onTap: { onPlay(video) },
                    showsMoreMenu: showsMoreMenu,
                    layout: .tile
                )
                .onAppear { onItemAppear(video) }
            }
        }
    }
}
