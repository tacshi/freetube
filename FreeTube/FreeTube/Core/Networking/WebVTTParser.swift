import Foundation

/// Minimal WebVTT parser for YouTube timedtext (`fmt=vtt`). Keeps cue timing and text; drops
/// cue settings, styling and YouTube's inline word-timing tags (`<00:00:01.000><c> word</c>`).
nonisolated enum WebVTTParser {
    static func parse(_ text: String) -> [CaptionCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var cues: [CaptionCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
                  let end = timestamp(String(endToken)),
                  end > start else { continue }
            let body = lines[(timingIndex + 1)...]
                .map { decodeEntities(stripTags($0)).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(CaptionCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// `hh:mm:ss.mmm` or `mm:ss.mmm`.
    private static func timestamp(_ raw: String) -> TimeInterval? {
        let fields = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var seconds: TimeInterval = 0
        for field in fields {
            guard let value = TimeInterval(field) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static func stripTags(_ line: String) -> String {
        line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func decodeEntities(_ line: String) -> String {
        line.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
