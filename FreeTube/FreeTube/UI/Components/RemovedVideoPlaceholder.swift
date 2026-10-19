import SwiftUI

/// Stands in for a video the user marked "Not interested", the way the official app collapses
/// the card into "Video removed" with an Undo button. Keeps the thumbnail's 16:9 footprint so
/// the feed doesn't jump.
@available(iOS 17.0, *)
struct RemovedVideoPlaceholder: View {
    var layout: VideoCard.Layout = .feed
    let onUndo: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Video removed")
                .font(.subheadline.weight(.semibold))
            Text("You'll see fewer videos like this.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: layout == .tile ? 12 : 0))
    }
}
