import Foundation
import OSLog

@available(iOS 17.0, *)
@Observable
final class QueueManager {
    enum RepeatMode: String, CaseIterable, Sendable {
        case off, all, one
    }

    private(set) var items: [Video] = []
    private(set) var currentIndex: Int = 0
    var isShuffleOn: Bool = false {
        didSet { rebuildShuffleOrder() }
    }
    var repeatMode: RepeatMode = .off

    private var shuffleOrder: [Int] = []
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "QueueManager")

    var current: Video? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    // MARK: - Mutation

    func replace(with videos: [Video], startAt index: Int = 0) {
        items = videos
        currentIndex = max(0, min(index, videos.count - 1))
        rebuildShuffleOrder()
    }

    func append(_ video: Video) {
        items.append(video)
        rebuildShuffleOrder()
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        if currentIndex >= items.count { currentIndex = max(0, items.count - 1) }
        rebuildShuffleOrder()
    }

    func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0, destination <= items.count else { return }
        let video = items.remove(at: source)
        items.insert(video, at: min(destination, items.count))
        rebuildShuffleOrder()
    }

    /// Marks `video` as the current item. If it's already in `items`, updates `currentIndex`. If not,
    /// the video is appended and becomes current. Lets `PlayerStateManager.load(_:)` keep the queue
    /// coherent when the user taps a fresh video from search/home, while preserving the queue when
    /// they navigate via `playNext()` / `playPrevious()` (which both call `load` with a video that's
    /// already in `items` at the freshly-advanced position).
    ///
    /// A video that isn't in `items` (e.g. a recommendation tapped mid-playlist) leaves the
    /// playlist, so a playlist's shuffle ends with it.
    func setCurrent(_ video: Video) {
        if let idx = items.firstIndex(of: video) {
            currentIndex = idx
        } else {
            items.append(video)
            currentIndex = items.count - 1
            if isShuffleOn {
                isShuffleOn = false
            } else {
                rebuildShuffleOrder()
            }
        }
    }

    // MARK: - Navigation

    func advance() -> Video? {
        switch repeatMode {
        case .one:
            return items[safe: currentIndex]
        case .off, .all:
            let nextIndex = nextIndex()
            if let nextIndex {
                currentIndex = nextIndex
                return items[safe: currentIndex]
            }
            return nil
        }
    }

    func previous() -> Video? {
        let previousIndex = previousIndex()
        if let previousIndex {
            currentIndex = previousIndex
            return items[safe: currentIndex]
        }
        return nil
    }

    private func nextIndex() -> Int? {
        if isShuffleOn {
            guard let position = shuffleOrder.firstIndex(of: currentIndex) else { return nil }
            let nextPosition = position + 1
            if shuffleOrder.indices.contains(nextPosition) {
                return shuffleOrder[nextPosition]
            }
            if repeatMode == .all, let first = shuffleOrder.first {
                return first
            }
            return nil
        }
        let candidate = currentIndex + 1
        if items.indices.contains(candidate) { return candidate }
        if repeatMode == .all, !items.isEmpty { return 0 }
        return nil
    }

    private func previousIndex() -> Int? {
        if isShuffleOn {
            guard let position = shuffleOrder.firstIndex(of: currentIndex) else { return nil }
            let prev = position - 1
            if shuffleOrder.indices.contains(prev) {
                return shuffleOrder[prev]
            }
            return nil
        }
        let candidate = currentIndex - 1
        return items.indices.contains(candidate) ? candidate : nil
    }

    private func rebuildShuffleOrder() {
        let indices = Array(items.indices)
        shuffleOrder = isShuffleOn ? indices.shuffled() : indices
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
