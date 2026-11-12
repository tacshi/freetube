import SwiftUI

/// The player's Download action. One control that follows the video's download state:
///
/// - not downloaded → **Download** (tap starts it)
/// - downloading → live percentage (tap for Cancel)
/// - downloaded → **Downloaded** (tap for Share / Remove)
/// - failed → **Retry**
///
/// Icon only, like the other actions in `FullScreenPlayer`'s row; the titles are the
/// accessibility labels. While downloading, the icon is a ring that fills with the progress.
@available(iOS 17.0, *)
struct DownloadButton: View {
    let video: Video

    @State private var manager = DownloadManager.shared
    @State private var sharedFile: URL?

    var body: some View {
        Group {
            if let file = manager.localFile(for: video.id) {
                Menu {
                    Button {
                        sharedFile = file
                    } label: {
                        Label("Share video file…", systemImage: "square.and.arrow.up")
                    }
                    if MacIntegration.isRunningOnMac {
                        Button {
                            MacIntegration.revealInFinder(file)
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                    }
                    Button(role: .destructive) {
                        manager.delete(videoID: video.id)
                    } label: {
                        Label("Remove download", systemImage: "trash")
                    }
                } label: {
                    label(Text("Downloaded"), systemImage: "checkmark.circle.fill")
                }
            } else if let job = manager.job(for: video.id) {
                switch job.status {
                case .failed:
                    Button {
                        manager.download(video)
                    } label: {
                        label(Text("Retry"), systemImage: "exclamationmark.arrow.circlepath")
                    }
                case .queued, .downloading, .saving:
                    Menu {
                        Button(role: .destructive) {
                            manager.cancel(videoID: video.id)
                        } label: {
                            Label("Cancel download", systemImage: "xmark")
                        }
                    } label: {
                        activeLabel(job.status)
                    }
                }
            } else {
                Button {
                    manager.download(video)
                } label: {
                    label(Text("Download"), systemImage: "arrow.down.circle")
                }
            }
        }
        .buttonStyle(.plain)
        .fileShareSheet($sharedFile)
    }

    @ViewBuilder
    private func activeLabel(_ status: DownloadJob.Status) -> some View {
        switch status {
        case .queued:
            label(Text("Waiting…"), systemImage: "clock")
        case .saving:
            label(Text("Saving…"), systemImage: "arrow.down.circle.dotted")
        default:
            let progress = manager.progress(for: video.id)
            ZStack {
                Circle().stroke(.tertiary, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "stop.fill").font(.system(size: 8))
            }
            .frame(width: 22, height: 22)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
            .accessibilityLabel(Text("Downloading"))
            .accessibilityValue(Text(verbatim: "\(Int(progress * 100))%"))
        }
    }

    private func label(_ title: Text, systemImage: String) -> some View {
        Label {
            title
        } icon: {
            Image(systemName: systemImage)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        // A `Menu` tints its label; keep it the same color as the row's plain buttons.
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())
    }
}
