import SwiftUI

/// Sits over the video surface while a stream is resolving (spinner, like the YouTube app) or
/// after every stream source failed (warning + message). Invisible once playback is ready.
@available(iOS 17.0, *)
struct PlaybackStatusOverlay: View {
    let state: PlayerStateManager.LoadState

    var body: some View {
        switch state {
        case .resolving:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.3)
                .transition(.opacity)
        case .failed(let message):
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    // `message` is already localized (`YouTubeServiceError.errorDescription`).
                    Text(verbatim: message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .transition(.opacity)
        case .idle, .readyToPlay:
            EmptyView()
        }
    }
}
