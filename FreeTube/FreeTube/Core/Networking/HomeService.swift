import Foundation
import OSLog
import YouTubeKit

protocol HomeServicing: Sendable {
    func fetchHome() async throws -> HomeFeed
    func fetchMore(continuation: String) async throws -> HomeFeed
}

/// Wraps YouTubeKit's `HomeScreenResponse` (+Continuation).
/// Home pages are requested as `HomeScreenFeedbackResponse`, the same request decoded by
/// YouTubeKit plus each video's "Not interested" token.
final class HomeService: HomeServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "HomeService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func fetchHome() async throws -> HomeFeed {
        log.info("Fetching home feed")
        do {
            let response = try await HomeScreenFeedbackResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:]
            )
            let videos = response.page.results.map(Mappers.video(from:))
            if !videos.isEmpty {
                let section = HomeFeedSection(id: "home", title: nil, videos: videos)
                return HomeFeed(
                    sections: [section],
                    continuationToken: response.page.continuationToken,
                    feedback: response.feedback
                )
            }
            // YouTube returns an empty home feed for anonymous users (no cookies). We don't want
            // the user staring at a blank tab in that case, so fall back to a curated discovery
            // grid: one section per evergreen category, populated via SearchResponse.
            log.notice("HomeScreenResponse empty — falling back to discovery categories")
            return try await fetchDiscoveryFeed()
        } catch {
            log.error("HomeScreenResponse failed: \(String(describing: error), privacy: .public)")
            // Network failure → still try the discovery fallback so the tab isn't useless.
            if let fallback = try? await fetchDiscoveryFeed() {
                return fallback
            }
            throw YouTubeServiceError.network(error)
        }
    }

    /// Issues a few parallel `SearchResponse` requests for evergreen categories and turns the
    /// results into one section per category. Used when the personalized home feed isn't available
    /// (i.e. anonymous YouTubeKit session).
    private func fetchDiscoveryFeed() async throws -> HomeFeed {
        let categories = ["Trending", "Music", "Gaming", "News", "Sports"]
        let sections = await withTaskGroup(of: HomeFeedSection?.self) { group -> [HomeFeedSection] in
            for category in categories {
                group.addTask { [client] in
                    do {
                        let response = try await SearchResponse.sendThrowingRequest(
                            youtubeModel: client.model,
                            data: [.query: category]
                        )
                        let videos = response.results
                            .prefix(20)
                            .compactMap { $0 as? YTVideo }
                            .map(Mappers.video(from:))
                        guard !videos.isEmpty else { return nil }
                        return HomeFeedSection(id: "discovery-\(category)", title: category, videos: videos)
                    } catch {
                        return nil
                    }
                }
            }
            var out: [HomeFeedSection] = []
            for await section in group { if let section { out.append(section) } }
            // Preserve the configured category order so the UI is deterministic across launches.
            let order = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1, $0) })
            return out.sorted { (order[$0.title ?? ""] ?? .max) < (order[$1.title ?? ""] ?? .max) }
        }
        return HomeFeed(sections: sections, continuationToken: nil)
    }

    func fetchMore(continuation: String) async throws -> HomeFeed {
        log.info("Fetching home continuation")
        do {
            let response = try await HomeScreenFeedbackResponse.Continuation.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.continuation: continuation]
            )
            let videos = response.page.results.map(Mappers.video(from:))
            let section = HomeFeedSection(id: "home-cont-\(UUID().uuidString)", title: nil, videos: videos)
            return HomeFeed(
                sections: [section],
                continuationToken: response.page.continuationToken,
                feedback: response.feedback
            )
        } catch {
            throw YouTubeServiceError.network(error)
        }
    }
}
