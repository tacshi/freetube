import Foundation

/// What `StreamService` resolves for a video: the HLS manifest `AVPlayer` streams, plus the
/// caption tracks YouTube offers alongside it (captions aren't inside YouTube's HLS streams).
struct ResolvedStream: Sendable {
    let hlsURL: URL
    let captions: [CaptionTrack]
}
