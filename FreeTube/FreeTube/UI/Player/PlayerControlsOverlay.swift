import SwiftUI

/// The player's own controls, drawn over `VideoSurface` (CLAUDE.md §8).
///
/// - **Top bar:** close chevron on the leading side; captions (CC, when the video has any),
///   theater mode (wide windows), full screen, Picture in Picture and AirPlay on the trailing side.
/// - **Center:** −10s / play-pause / +10s.
/// - **Bottom:** elapsed time, scrubber, remaining time, ⋯ menu (`PlayerSettingsMenu`).
/// - **Captions:** the selected YouTube caption track, drawn above the bottom bar.
///
/// Gestures on the video: tap shows / hides the controls (they auto-hide after a few seconds
/// while playing), double-tap the leading / trailing half seeks −10s / +10s, drag sideways
/// scrubs, pull down closes (or leaves full screen).
@available(iOS 17.0, *)
struct PlayerControlsOverlay: View {
    @Environment(PlayerStateManager.self) private var player
    @Environment(\.layoutDirection) private var layoutDirection
    @Binding var isFullScreen: Bool
    /// Theater-mode toggle state; `nil` hides the button (narrow / stacked layouts, full screen).
    var theaterMode: Binding<Bool>?
    let pictureInPicture: PictureInPictureModel
    /// Extra top padding for the top bar — the iPad window controls' footprint when the video
    /// fills the window in full-screen mode.
    var topInset: CGFloat = 0
    let onClose: () -> Void

    @State private var controlsVisible = true
    @State private var hideToken = UUID()
    @State private var dragMode: DragMode?
    @State private var scrubStart: TimeInterval = 0
    /// Target of a sideways drag on the video, or of a drag on the scrubber bar.
    @State private var scrubTarget: TimeInterval?
    @State private var isDraggingScrubber = false
    @State private var seekFlash: SeekFlash?

    private enum DragMode { case scrub, dismiss }

    private struct SeekFlash: Equatable {
        let forward: Bool
        let seconds: Int
        let token: UUID
    }

    private static let seekStep = 10
    /// Seconds a drag across the full video width moves (capped at the video's length).
    private static let scrubSecondsPerWidth: TimeInterval = 120
    private static let autoHideDelay: Duration = .seconds(3)

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                gestureLayer(size: proxy.size)

                captionLayer(videoHeight: proxy.size.height)

                // Faded rather than removed, so an open ⋯ menu isn't torn down when the controls
                // auto-hide underneath it.
                controls
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)

                seekFlashOverlay
                if !isDraggingScrubber {
                    scrubTimeOverlay
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { scheduleAutoHide() }
        .onChange(of: player.isPlaying) { _, playing in
            if playing {
                scheduleAutoHide()
            } else {
                showControls()
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.65),
                    .init(color: .black.opacity(0.6), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.top, topInset)
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            if player.loadState == .readyToPlay {
                centerControls
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            iconButton(
                "chevron.down",
                label: isFullScreen ? "Exit full screen" : "Close full screen player"
            ) {
                if isFullScreen {
                    setFullScreen(false)
                } else {
                    onClose()
                }
            }
            Spacer(minLength: 0)
            if !player.captionTracks.isEmpty {
                iconButton(
                    player.selectedCaptionID == nil ? "captions.bubble" : "captions.bubble.fill",
                    label: "Subtitles"
                ) {
                    player.toggleCaptions()
                }
            }
            if let theaterMode {
                iconButton(
                    label: theaterMode.wrappedValue ? "Exit theater mode" : "Theater mode",
                    action: { withAnimation(.snappy) { theaterMode.wrappedValue.toggle() } }
                ) {
                    TheaterModeIcon(isOn: theaterMode.wrappedValue)
                }
            }
            iconButton(
                isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                label: isFullScreen ? "Exit full screen" : "Full screen"
            ) {
                setFullScreen(!isFullScreen)
            }
            if pictureInPicture.isPossible {
                iconButton(
                    pictureInPicture.isActive ? "pip.exit" : "pip.enter",
                    label: "Picture in Picture"
                ) {
                    pictureInPicture.toggle()
                }
            }
            AirPlayButton()
                .frame(width: 44, height: 44)
        }
    }

    private var centerControls: some View {
        HStack(spacing: 56) {
            iconButton("gobackward.10", label: "Back 10 seconds", font: .title) {
                player.seekRelative(by: -TimeInterval(Self.seekStep))
            }
            iconButton(
                player.isPlaying ? "pause.fill" : "play.fill",
                label: player.isPlaying ? "Pause" : "Play",
                font: .system(size: 44)
            ) {
                player.togglePlayPause()
            }
            iconButton("goforward.10", label: "Forward 10 seconds", font: .title) {
                player.seekRelative(by: TimeInterval(Self.seekStep))
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if player.duration > 0 {
                Text(verbatim: Self.timestamp(scrubTarget ?? player.displayPosition))
                    .font(.caption.monospacedDigit())
                ScrubberBar(
                    position: scrubTarget ?? player.displayPosition,
                    duration: player.duration,
                    onChanged: { target in
                        isDraggingScrubber = true
                        scrubTarget = target
                        player.seek(to: target, precise: false)
                        keepControlsVisible()
                    },
                    onEnded: { target in
                        player.seek(to: target)
                        scrubTarget = nil
                        isDraggingScrubber = false
                        scheduleAutoHide()
                    }
                )
                Text(verbatim: "−" + Self.timestamp(max(0, player.duration - (scrubTarget ?? player.displayPosition))))
                    .font(.caption.monospacedDigit())
            } else {
                Spacer(minLength: 0)
            }
            PlayerSettingsMenu()
        }
    }

    // MARK: - Gestures

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        let trailing = layoutDirection == .rightToLeft
                            ? value.location.x < size.width / 2
                            : value.location.x > size.width / 2
                        doubleTapSeek(forward: trailing)
                    }
                    .exclusively(before: TapGesture().onEnded { toggleControls() })
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { videoDragChanged($0, size: size) }
                    .onEnded { videoDragEnded($0) }
            )
    }

    private func doubleTapSeek(forward: Bool) {
        let step = Self.seekStep
        player.seekRelative(by: TimeInterval(forward ? step : -step))
        let previous = seekFlash.flatMap { $0.forward == forward ? $0.seconds : nil } ?? 0
        let flash = SeekFlash(forward: forward, seconds: previous + step, token: UUID())
        withAnimation(.easeOut(duration: 0.15)) { seekFlash = flash }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            if seekFlash?.token == flash.token {
                withAnimation(.easeOut(duration: 0.25)) { seekFlash = nil }
            }
        }
    }

    private func videoDragChanged(_ value: DragGesture.Value, size: CGSize) {
        if dragMode == nil {
            if abs(value.translation.width) > abs(value.translation.height) {
                guard player.duration > 0 else { return }
                dragMode = .scrub
                scrubStart = player.livePosition
            } else {
                dragMode = .dismiss
            }
        }
        guard dragMode == .scrub, size.width > 0 else { return }
        let span = min(player.duration, Self.scrubSecondsPerWidth)
        let target = min(max(scrubStart + Double(value.translation.width / size.width) * span, 0), player.duration)
        scrubTarget = target
        player.seek(to: target, precise: false)
    }

    private func videoDragEnded(_ value: DragGesture.Value) {
        defer {
            dragMode = nil
            scrubTarget = nil
        }
        switch dragMode {
        case .scrub:
            if let scrubTarget { player.seek(to: scrubTarget) }
        case .dismiss:
            let mostlyDown = value.translation.height > 90
                && abs(value.translation.width) < value.translation.height
            let fastFlick = value.predictedEndTranslation.height > 180
            guard mostlyDown || fastFlick else { return }
            if isFullScreen {
                setFullScreen(false)
            } else {
                onClose()
            }
        case nil:
            break
        }
    }

    // MARK: - Visibility

    private func toggleControls() {
        if controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        } else {
            showControls()
        }
    }

    private func showControls() {
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        scheduleAutoHide()
    }

    /// Keeps the controls up during an interaction (cancels any pending auto-hide).
    private func keepControlsVisible() {
        hideToken = UUID()
        if !controlsVisible { controlsVisible = true }
    }

    private func scheduleAutoHide() {
        let token = UUID()
        hideToken = token
        guard player.isPlaying else { return }
        Task {
            try? await Task.sleep(for: Self.autoHideDelay)
            guard hideToken == token, player.isPlaying, !isDraggingScrubber, dragMode == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    private func setFullScreen(_ value: Bool) {
        withAnimation(.snappy) { isFullScreen = value }
        scheduleAutoHide()
    }

    /// Icon-only control button with a 44pt hit target; any tap also resets the auto-hide timer.
    private func iconButton(
        _ systemImage: String,
        label: LocalizedStringKey,
        font: Font = .title3,
        action: @escaping () -> Void
    ) -> some View {
        iconButton(label: label, action: action) {
            Image(systemName: systemImage)
                .font(font.weight(.semibold))
        }
    }

    private func iconButton<Icon: View>(
        label: LocalizedStringKey,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button {
            action()
            showControls()
        } label: {
            icon()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Overlays

    /// Current caption line, bottom-centered; lifted above the bottom bar while it's showing.
    /// Scales with the video so it stays readable in full screen without crowding a small player.
    @ViewBuilder
    private func captionLayer(videoHeight: CGFloat) -> some View {
        if let text = player.captionText {
            Text(verbatim: text)
                .font(.system(size: min(max(videoHeight * 0.045, 14), 30), weight: .medium))
                .multilineTextAlignment(.center)
                // No box behind the text: a tight dark edge plus a soft shadow keeps white
                // captions readable on bright frames.
                .shadow(color: .black.opacity(0.9), radius: 1)
                .shadow(color: .black.opacity(0.6), radius: 4)
                .padding(.horizontal, 32)
                .padding(.bottom, controlsVisible ? 56 : 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: controlsVisible)
        }
    }

    @ViewBuilder
    private var seekFlashOverlay: some View {
        if let seekFlash {
            Label {
                Text(verbatim: seekFlash.forward ? "+\(seekFlash.seconds)s" : "−\(seekFlash.seconds)s")
            } icon: {
                Image(systemName: seekFlash.forward ? "forward.fill" : "backward.fill")
            }
            .font(.title3.weight(.semibold))
            .shadow(radius: 4)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, alignment: seekFlash.forward ? .trailing : .leading)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// Big "target / duration" readout while scrubbing by dragging on the video.
    @ViewBuilder
    private var scrubTimeOverlay: some View {
        if let scrubTarget, dragMode == .scrub {
            Text(verbatim: "\(Self.timestamp(scrubTarget)) / \(Self.timestamp(player.duration))")
                .font(.title2.weight(.semibold).monospacedDigit())
                .shadow(radius: 4)
                .allowsHitTesting(false)
        }
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Theater-mode glyph: a wide rectangle with triangles on its left and right — pointing outward
/// to widen, inward to go back. SF Symbols has no landscape rectangle with side arrows
/// (`rectangle.arrowtriangle.2.outward` puts them above and below), hence the composition.
@available(iOS 17.0, *)
private struct TheaterModeIcon: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: isOn ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                .font(.system(size: 8, weight: .bold))
            Image(systemName: "rectangle")
                .font(.title3.weight(.semibold))
            Image(systemName: isOn ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                .font(.system(size: 8, weight: .bold))
        }
    }
}

/// Thin seek bar: drag (or tap) anywhere on it to scrub. Coarse seeks while dragging, a precise
/// seek on release (both done by the caller).
@available(iOS 17.0, *)
private struct ScrubberBar: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onChanged: (TimeInterval) -> Void
    let onEnded: (TimeInterval) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: isDragging ? 6 : 4)
                Capsule()
                    .fill(.white)
                    .frame(width: width * fraction, height: isDragging ? 6 : 4)
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 18 : 12, height: isDragging ? 18 : 12)
                    .offset(x: width * fraction - (isDragging ? 9 : 6))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onChanged(target(at: value.location.x, width: width))
                    }
                    .onEnded { value in
                        isDragging = false
                        onEnded(target(at: value.location.x, width: width))
                    }
            )
            .animation(.easeOut(duration: 0.15), value: isDragging)
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(verbatim: PlayerControlsOverlay.timestamp(position)))
    }

    private func target(at x: CGFloat, width: CGFloat) -> TimeInterval {
        min(max(Double(x / width), 0), 1) * duration
    }
}
