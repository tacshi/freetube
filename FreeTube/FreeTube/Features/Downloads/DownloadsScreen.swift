import SwiftUI
import UIKit

import Kingfisher

/// The Downloads tab: what's downloading now, and the saved videos.
///
/// A saved video plays on tap (from the file, so it works offline). Getting it into another app
/// is one tap on the row's share button — the system share sheet offers Save to Files, AirDrop,
/// Save Video and every app that opens videos — or a drag of the row on iPad. Swipe to delete.
@available(iOS 17.0, *)
struct DownloadsScreen: View {
    @Environment(PlayerStateManager.self) private var player
    @State private var manager = DownloadManager.shared
    @State private var store = DownloadsStore.shared
    @State private var sharedFile: URL?

    private static let thumbnailSize = CGSize(width: 120, height: 68)

    var body: some View {
        NavigationStack {
            List {
                if !manager.jobs.isEmpty {
                    Section("Downloading") {
                        ForEach(manager.jobs) { job in
                            jobRow(job)
                        }
                    }
                }

                if !store.entries.isEmpty {
                    Section {
                        ForEach(store.entries) { entry in
                            savedRow(entry)
                        }
                    } footer: {
                        if MacIntegration.isRunningOnMac {
                            Text("\(totalSize) used.")
                        } else {
                            Text("\(totalSize) used. Also in the Files app, in the FreeTube folder.")
                        }
                    }
                }
            }
            .overlay {
                if manager.jobs.isEmpty && store.entries.isEmpty {
                    EmptyStateView(
                        systemImage: "arrow.down.circle",
                        title: String(localized: "No downloads yet"),
                        message: String(localized: "Tap Download under a video you're watching, or in a video's ⋯ menu.")
                    )
                }
            }
            .readableContentWidth(gutter: .grouped)
            .navigationTitle("Downloads")
            .fileShareSheet($sharedFile)
            .task { await store.reload() }
        }
    }

    private var totalSize: String {
        ByteCountFormatter.string(fromByteCount: store.entries.reduce(0) { $0 + $1.fileSize }, countStyle: .file)
    }

    // MARK: - In progress

    private func jobRow(_ job: DownloadJob) -> some View {
        HStack(spacing: 12) {
            KFImage(job.video.thumbnailURL)
                .thumbnail(size: Self.thumbnailSize) { Color.gray.opacity(0.2) }
                .resizable()
                .scaledToFill()
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text(job.video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                jobStatus(job)
            }
            Spacer(minLength: 0)

            if case .failed = job.status {
                Button {
                    manager.download(job.video)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Retry")
            }
            Button {
                manager.cancel(videoID: job.id)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Cancel download")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func jobStatus(_ job: DownloadJob) -> some View {
        switch job.status {
        case .queued:
            Text("Waiting…").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            let progress = manager.progress(for: job.id)
            ProgressView(value: progress)
            Text(verbatim: "\(Int(progress * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        case .saving:
            ProgressView(value: 1)
            Text("Saving…").font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }

    // MARK: - Saved

    private func savedRow(_ entry: DownloadEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                player.load(entry.video)
            } label: {
                HStack(spacing: 12) {
                    thumbnail(entry)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if !entry.channelName.isEmpty {
                            Text(entry.channelName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(verbatim: details(entry))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                sharedFile = entry.fileURL
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share video file…")
        }
        // Dragging the row hands the MP4 itself to whatever it's dropped on (Files, Photos,
        // another app in Split View).
        .onDrag {
            NSItemProvider(contentsOf: entry.fileURL) ?? NSItemProvider()
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.delete(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                sharedFile = entry.fileURL
            } label: {
                Label("Share video file…", systemImage: "square.and.arrow.up")
            }
            if MacIntegration.isRunningOnMac {
                Button {
                    MacIntegration.revealInFinder(entry.fileURL)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            if entry.metadata != nil {
                Button {
                    UIPasteboard.general.string = "https://www.youtube.com/watch?v=\(entry.videoID)"
                } label: {
                    Label("Copy URL", systemImage: "link")
                }
            }
            Button(role: .destructive) {
                store.delete(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ entry: DownloadEntry) -> some View {
        Group {
            if let data = entry.metadata?.thumbnailData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.2)
                    .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
            }
        }
        .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// "12:34 • 85 MB" — duration and file size.
    private func details(_ entry: DownloadEntry) -> String {
        [entry.video.durationString, ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file)]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}
