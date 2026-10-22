import SwiftUI

/// The player's ⋯ settings menu, in the YouTube app's order: Quality, Playback speed, Subtitles,
/// Audio track, Loop video, Sleep timer. Each picker is a submenu that shows its current value,
/// so the menu stays short enough to fit even in landscape (and scrolls if it ever doesn't).
///
/// **Its own view on purpose.** `PlayerControlsOverlay`'s body re-evaluates on every time tick
/// (the elapsed / remaining labels). A `Menu` built inside that body is rebuilt with it, and an
/// open menu cross-fades on every rebuild — it flashed twice a second. As a separate view it only
/// re-evaluates when a property it reads changes (rate, tracks, quality, sleep timer…).
@available(iOS 17.0, *)
struct PlayerSettingsMenu: View {
    @Environment(PlayerStateManager.self) private var player

    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Menu {
            if !player.qualityChoices.isEmpty {
                Picker(selection: Binding(
                    get: { player.effectiveQuality },
                    set: { player.setQuality($0) }
                )) {
                    if let height = player.playingHeight, player.quality == .auto {
                        Text("Auto (\(height)p)").tag(VideoQuality.auto)
                    } else {
                        Text("Auto").tag(VideoQuality.auto)
                    }
                    ForEach(player.qualityChoices) { quality in
                        Text(verbatim: quality.rawValue).tag(quality)
                    }
                } label: {
                    Label("Quality", systemImage: "slider.horizontal.3")
                }
                .pickerStyle(.menu)
            }

            Picker(selection: Binding(
                get: { player.playbackRate },
                set: { player.setPlaybackRate($0) }
            )) {
                ForEach(Self.speeds, id: \.self) { speed in
                    if speed == 1 {
                        Text("Normal").tag(speed)
                    } else {
                        Text(verbatim: Self.speedLabel(speed)).tag(speed)
                    }
                }
            } label: {
                Label("Playback speed", systemImage: "gauge.with.dots.needle.67percent")
            }
            .pickerStyle(.menu)

            if !player.captionTracks.isEmpty {
                Picker(selection: Binding(
                    get: { player.selectedCaptionID },
                    set: { player.selectCaption($0) }
                )) {
                    Text("Off").tag(String?.none)
                    ForEach(player.captionTracks) { track in
                        Text(verbatim: track.name).tag(String?.some(track.id))
                    }
                } label: {
                    Label("Subtitles", systemImage: "captions.bubble")
                }
                .pickerStyle(.menu)
            }

            if player.audioChoices.count > 1 {
                Picker(selection: Binding(
                    get: { player.selectedAudioID ?? 0 },
                    set: { player.selectAudio($0) }
                )) {
                    ForEach(player.audioChoices) { choice in
                        Text(verbatim: choice.name).tag(choice.id)
                    }
                } label: {
                    Label("Audio track", systemImage: "waveform")
                }
                .pickerStyle(.menu)
            }

            // YouTube's "Loop video": replays the current video instead of autoplaying the next.
            Toggle(isOn: Binding(
                get: { player.queue.repeatMode == .one },
                set: { player.queue.repeatMode = $0 ? .one : .off }
            )) {
                Label("Loop video", systemImage: "repeat.1")
            }

            Picker(selection: Binding(
                get: { player.sleepTimer },
                set: { player.setSleepTimer($0) }
            )) {
                ForEach(SleepTimer.choices) { timer in
                    switch timer {
                    // Own key: the subtitles "Off" is plural in some languages ("Desactivados").
                    case .off: Text(String(localized: "sleepTimer.off", defaultValue: "Off")).tag(timer)
                    case .minutes(let minutes): Text("\(minutes) minutes").tag(timer)
                    case .endOfVideo: Text("End of video").tag(timer)
                    }
                }
            } label: {
                Label("Sleep timer", systemImage: "moon.zzz")
            }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    private static func speedLabel(_ speed: Double) -> String {
        let number = speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", speed)
        return number + "×"
    }
}
