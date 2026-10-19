import Foundation

import YouTubeKit

/// `HomeScreenResponse` (+Continuation) plus the "Not interested" feedback tokens YouTubeKit
/// doesn't parse.
///
/// Same request as `HomeScreenResponse` (`headersType` and validation are copied from it), and
/// the videos are decoded by YouTubeKit's own decoder. On top of that, each feed item's ⋯ menu
/// is searched for the "Not interested" entry, whose `feedbackEndpoint` carries the token
/// `FeedbackService` posts, and the `undoFeedbackEndpoint` YouTube shows after it.
///
/// Two menu shapes exist: the legacy `videoRenderer.menu.menuRenderer` (icon `NOT_INTERESTED`)
/// and the current `lockupViewModel` bottom sheet (leading image `NOT_INTERESTED`). If no item
/// is labelled, the first item carrying a `feedbackEndpoint` is used: YouTube lists
/// "Not interested" before "Don't recommend channel".
nonisolated struct HomeScreenFeedbackResponse: YouTubeResponse {
    static let headersType: HeaderTypes = HomeScreenResponse.headersType
    static let parametersValidationList: ValidationList = HomeScreenResponse.parametersValidationList

    let page: HomeScreenResponse
    let feedback: [String: VideoFeedback]

    static func decodeJSON(json: JSON) throws -> HomeScreenFeedbackResponse {
        let items = json["contents", "twoColumnBrowseResultsRenderer", "tabs"].arrayValue
            .filter { $0["tabRenderer", "selected"].bool ?? false }
            .flatMap { $0["tabRenderer", "content", "richGridRenderer", "contents"].arrayValue }
        return HomeScreenFeedbackResponse(
            page: HomeScreenResponse.decodeJSON(json: json),
            feedback: FeedbackTokenParser.feedback(in: items)
        )
    }

    /// Next page of the home feed, with its feedback tokens.
    nonisolated struct Continuation: YouTubeResponse {
        static let headersType: HeaderTypes = HomeScreenResponse.Continuation.headersType
        static let parametersValidationList: ValidationList = HomeScreenResponse.Continuation.parametersValidationList

        let page: HomeScreenResponse.Continuation
        let feedback: [String: VideoFeedback]

        static func decodeJSON(json: JSON) throws -> Continuation {
            let items = json["onResponseReceivedActions"].arrayValue
                .flatMap { $0["appendContinuationItemsAction", "continuationItems"].arrayValue }
            return Continuation(
                page: HomeScreenResponse.Continuation.decodeJSON(json: json),
                feedback: FeedbackTokenParser.feedback(in: items)
            )
        }
    }
}

/// Pulls "Not interested" tokens out of `richItemRenderer` feed items.
private nonisolated enum FeedbackTokenParser {
    private static let notInterestedIcon = "NOT_INTERESTED"

    static func feedback(in items: [JSON]) -> [String: VideoFeedback] {
        var result: [String: VideoFeedback] = [:]
        for item in items {
            let content = item["richItemRenderer", "content"]
            if let videoID = content["videoRenderer", "videoId"].string {
                let menu = content["videoRenderer", "menu", "menuRenderer", "items"].arrayValue.map { entry in
                    MenuEntry(
                        icon: entry["menuServiceItemRenderer", "icon", "iconType"].string,
                        command: entry["menuServiceItemRenderer", "serviceEndpoint"]
                    )
                }
                result[videoID] = feedback(from: menu)
            } else if let videoID = content["lockupViewModel", "contentId"].string {
                let menu = content[
                    "lockupViewModel", "metadata", "lockupMetadataViewModel", "menuButton", "buttonViewModel",
                    "onTap", "innertubeCommand", "showSheetCommand", "panelLoadingStrategy", "inlineContent",
                    "sheetViewModel", "content", "listViewModel", "listItems"
                ].arrayValue.map { entry in
                    MenuEntry(
                        icon: entry["listItemViewModel", "leadingImage", "sources", 0, "clientResource", "imageName"].string,
                        command: entry["listItemViewModel", "rendererContext", "commandContext", "onTap"]
                    )
                }
                result[videoID] = feedback(from: menu)
            }
        }
        return result
    }

    private struct MenuEntry {
        let icon: String?
        let command: JSON
    }

    private static func feedback(from menu: [MenuEntry]) -> VideoFeedback? {
        let candidates = menu.compactMap { entry -> (icon: String?, endpoint: JSON)? in
            guard let endpoint = firstValue(forKey: "feedbackEndpoint", in: entry.command) else { return nil }
            return (entry.icon, endpoint)
        }
        guard let chosen = candidates.first(where: { $0.icon == notInterestedIcon }) ?? candidates.first,
              let token = chosen.endpoint["feedbackToken"].string
        else { return nil }
        let undoToken = firstValue(forKey: "undoToken", in: chosen.endpoint)?.string
        return VideoFeedback(notInterestedToken: token, undoToken: undoToken)
    }

    /// Depth-first search for the first value stored under `key` anywhere inside `json`.
    /// YouTube wraps commands differently between experiments (`commandExecutorCommand`,
    /// `replaceEnclosingAction`, …), so fixed paths below the menu entry are too brittle.
    private static func firstValue(forKey key: String, in json: JSON) -> JSON? {
        if let dictionary = json.dictionary {
            if let value = dictionary[key] { return value }
            for (_, child) in dictionary {
                if let found = firstValue(forKey: key, in: child) { return found }
            }
        } else if let array = json.array {
            for child in array {
                if let found = firstValue(forKey: key, in: child) { return found }
            }
        }
        return nil
    }
}
