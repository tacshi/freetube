import Foundation

struct HomeFeedSection: Identifiable, Sendable {
    let id: String
    let title: String?
    let videos: [Video]
}

struct HomeFeed: Sendable {
    let sections: [HomeFeedSection]
    let continuationToken: String?
    /// "Not interested" tokens by video ID. Only the signed-in home feed carries them.
    var feedback: [String: VideoFeedback] = [:]
}
