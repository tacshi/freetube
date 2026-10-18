import SwiftUI
import Kingfisher

/// Vertical "feed" video card — used in Home, Subscriptions, Channel videos.
///
/// `layout: .tile` is the grid variant used on wide (regular-width) layouts: rounded thumbnail
/// and no horizontal padding, because the grid supplies the gutters between tiles.
///
/// Set `showsMoreMenu: true` to render the trailing ellipsis Menu (open in browser, copy URL,
/// favorites, add to playlist) on the metadata row. The Menu sits as a sibling of
/// the card's main tap target so its taps don't trigger `onTap`.
@available(iOS 17.0, *)
struct VideoCard: View {
    enum Layout {
        /// Edge-to-edge thumbnail in a single-column list.
        case feed
        /// Rounded thumbnail sized by its grid cell.
        case tile
    }

    let video: Video
    var onTap: () -> Void = {}
    var showsMoreMenu: Bool = false
    var layout: Layout = .feed

    /// Channel name plus the playback count and relative upload date. Joined by middle dots so
    /// the line reads naturally and any missing segment is dropped without leaving stray
    /// separators ("Channel" / "Channel • 1.2M views" / "Channel • 1.2M views • 3 days ago").
    private var metadataLine: String {
        let parts = [video.channelName, video.viewCountString, video.publishedRelative ?? ""]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onTap) {
                thumbnail
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(video.title), \(video.channelName)"))

            // Metadata row is split into its own HStack so the ellipsis Menu can live as a
            // sibling of the title/avatar tap target (which still routes to `onTap`). Nesting
            // the Menu inside the outer Button would route taps to playback instead of to the
            // Menu, since SwiftUI's outer Button consumes the gesture first.
            metadataRow
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch layout {
        case .feed:
            ZStack(alignment: .bottomTrailing) {
                thumbnailImage
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16/9, contentMode: .fill)
                    .clipped()
                durationBadge
            }
        case .tile:
            // A fixed-ratio clear box sized by the grid cell, with the image filling it, keeps
            // every tile in a row the same height regardless of the source thumbnail's ratio.
            Color.clear
                .aspectRatio(16/9, contentMode: .fit)
                .overlay { thumbnailImage }
                .overlay(alignment: .bottomTrailing) { durationBadge }
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var thumbnailImage: some View {
        KFImage(video.thumbnailURL)
            .thumbnail(size: CGSize(width: 400, height: 225)) {
                Color.gray.opacity(0.2)
            }
            .resizable()
            .scaledToFill()
    }

    @ViewBuilder
    private var durationBadge: some View {
        if !video.durationString.isEmpty {
            Text(video.durationString)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.75))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
    }

    private var metadataRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 12) {
                    KFImage(video.channelThumbnailURL)
                        .thumbnail(size: CGSize(width: 36, height: 36)) {
                            Circle().fill(.gray.opacity(0.2))
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text(metadataLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsMoreMenu {
                VideoMoreActionsMenu(video: video)
            }
        }
        .padding(.horizontal, layout == .feed ? nil : 0)
    }
}
