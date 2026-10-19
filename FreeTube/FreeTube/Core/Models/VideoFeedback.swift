import Foundation

/// The "Not interested" feedback YouTube attaches to a video in the signed-in home feed.
///
/// Both values are opaque tokens from the card's ⋯ menu: posting `notInterestedToken` to
/// YouTube's `/feedback` endpoint removes the video and tunes recommendations, exactly like the
/// official app's "Not interested"; posting `undoToken` reverts it. Tokens are bound to the
/// account and only live as long as the feed they came from — never persist them.
nonisolated struct VideoFeedback: Hashable, Sendable {
    let notInterestedToken: String
    /// Nil when YouTube didn't offer an Undo for this card.
    let undoToken: String?
}
