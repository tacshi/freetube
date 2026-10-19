import Foundation

import YouTubeKit

/// YouTube's generic `/youtubei/v1/feedback` request.
///
/// YouTubeKit only exposes this endpoint as `RemoveVideoFromHistroryResponse` (whose token is a
/// history-removal one), so this reuses its request (`.deleteVideoFromHistory` headers: the
/// token goes in `feedbackTokens`) under its own type, keeping one response type per service
/// method (CLAUDE.md §6).
nonisolated struct FeedbackResponse: SimpleActionAuthenticatedResponse {
    static let headersType: HeaderTypes = RemoveVideoFromHistroryResponse.headersType
    static let parametersValidationList: ValidationList = RemoveVideoFromHistroryResponse.parametersValidationList

    var isDisconnected: Bool = true
    var success: Bool = false

    static func decodeJSON(json: JSON) throws -> FeedbackResponse {
        let decoded = RemoveVideoFromHistroryResponse.decodeJSON(json: json)
        return FeedbackResponse(isDisconnected: decoded.isDisconnected, success: decoded.success)
    }
}
