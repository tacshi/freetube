import Foundation

/// One timed caption line from a WebVTT file.
struct CaptionCue: Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}
