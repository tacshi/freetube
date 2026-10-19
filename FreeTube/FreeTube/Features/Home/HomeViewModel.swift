import Foundation
import Observation
import OSLog

@available(iOS 17.0, *)
@Observable
@MainActor
final class HomeViewModel {
    private(set) var sections: [HomeFeedSection] = []
    private(set) var isLoading: Bool = false
    private(set) var continuationToken: String?
    /// Videos the user marked "Not interested". Their cards show a "Video removed" placeholder
    /// with Undo, like the official app, until the feed is refreshed.
    private(set) var removedVideoIDs: Set<String> = []
    var errorState: ErrorState?

    /// "Not interested" tokens for the loaded feed, by video ID.
    private var feedback: [String: VideoFeedback] = [:]

    private let service: any HomeServicing
    private let feedbackService: any FeedbackServicing
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "HomeViewModel")

    init(service: any HomeServicing = HomeService(), feedbackService: any FeedbackServicing = FeedbackService()) {
        self.service = service
        self.feedbackService = feedbackService
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let feed = try await service.fetchHome()
            sections = feed.sections
            continuationToken = feed.continuationToken
            feedback = feed.feedback
        } catch {
            log.error("Home fetch failed: \(String(describing: error), privacy: .public)")
            errorState = ErrorState(from: error)
        }
    }

    func loadMore() async {
        guard let token = continuationToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let feed = try await service.fetchMore(continuation: token)
            sections.append(contentsOf: feed.sections)
            continuationToken = feed.continuationToken
            feedback.merge(feed.feedback) { _, new in new }
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func refresh() async {
        continuationToken = nil
        sections = []
        feedback = [:]
        removedVideoIDs = []
        await load()
    }

    // MARK: - Not interested

    /// Whether YouTube offered "Not interested" for this video (signed-in home feed only).
    func canMarkNotInterested(_ video: Video) -> Bool {
        feedback[video.id] != nil && !removedVideoIDs.contains(video.id)
    }

    /// Removes the video from the feed right away and tells YouTube; puts it back if that fails.
    func markNotInterested(_ video: Video) async {
        guard let token = feedback[video.id]?.notInterestedToken else { return }
        removedVideoIDs.insert(video.id)
        do {
            try await feedbackService.send(token: token)
            log.info("Not interested: \(video.id, privacy: .public)")
        } catch {
            log.error("Not interested failed for \(video.id, privacy: .public): \(String(describing: error), privacy: .public)")
            removedVideoIDs.remove(video.id)
            errorState = ErrorState(from: error)
        }
    }

    /// Restores a removed video and sends YouTube's undo token, when it gave one.
    func undoNotInterested(_ video: Video) async {
        guard removedVideoIDs.remove(video.id) != nil else { return }
        guard let undoToken = feedback[video.id]?.undoToken else { return }
        do {
            try await feedbackService.send(token: undoToken)
            log.info("Undo not interested: \(video.id, privacy: .public)")
        } catch {
            log.error("Undo not interested failed for \(video.id, privacy: .public): \(String(describing: error), privacy: .public)")
            removedVideoIDs.insert(video.id)
            errorState = ErrorState(from: error)
        }
    }
}
