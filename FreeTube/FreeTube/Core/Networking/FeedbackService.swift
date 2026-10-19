import Foundation
import OSLog

import YouTubeKit

protocol FeedbackServicing: Sendable {
    /// Posts a feedback token (a video's "Not interested", or its undo) to the signed-in account.
    func send(token: String) async throws
}

/// Sends "Not interested" and its Undo to YouTube, like the official app's feed menu.
///
/// Wraps `FeedbackResponse`. The tokens come from `HomeScreenFeedbackResponse` and are only
/// valid for the signed-in account that loaded the feed.
final class FeedbackService: FeedbackServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "FeedbackService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func send(token: String) async throws {
        let response: FeedbackResponse
        do {
            response = try await FeedbackResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.movingVideoId: token]
            )
        } catch {
            log.error("Feedback request failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        if response.isDisconnected {
            log.notice("Feedback: response isDisconnected=true")
            throw YouTubeServiceError.notAuthenticated
        }
        guard response.success else {
            log.error("Feedback not processed")
            throw YouTubeServiceError.unknown(CocoaError(.featureUnsupported))
        }
        log.info("Feedback processed")
    }
}
