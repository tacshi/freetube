import Foundation

/// Why a download failed, beyond what the stream lookup (`YouTubeServiceError`) and the
/// stream fetch (`HLSDownloadError`, `URLError`) already report.
enum DownloadError: LocalizedError {
    case cellularNotAllowed
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .cellularNotAllowed:
            return String(localized: "Waiting for Wi-Fi. Downloads over cellular are turned off in Settings.")
        case .conversionFailed:
            return String(localized: "Couldn't save the video file.")
        }
    }
}
