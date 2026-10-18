import SwiftUI

/// Top-level tabbed shell.
///
/// Tab layout (3):
/// - Home (home video feed, with the search field and recent searches in the same screen)
/// - Library (subsumes the former Account + Subscriptions tabs; includes Favorites/Recents/Playlists/Login)
/// - Settings (preferences, quality, reset-session)
///
/// **Playback works like the YouTube app:** tapping a video presents `FullScreenPlayer` as a
/// full-screen cover and starts streaming. There is no mini player — closing the player
/// (Close button or pull-down) stops playback.
@available(iOS 17.0, *)
struct RootView: View {
    @Environment(PlayerStateManager.self) private var player
    @State private var selectedTab: Tab = .home

    enum Tab: Hashable {
        case home, library, settings
    }

    var body: some View {
        @Bindable var player = player

        TabView(selection: $selectedTab) {
            HomeScreen()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            LibraryScreen()
                .tabItem { Label("Library", systemImage: "play.square.stack") }
                .tag(Tab.library)

            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        // `PlayerStateManager.load(_:)` flips `fullScreenPresented` on; the player's Close button
        // and pull-down gesture flip it off, and `onDismiss` stops playback.
        .fullScreenCover(isPresented: $player.fullScreenPresented, onDismiss: {
            player.dismiss()
        }) {
            FullScreenPlayer()
        }
        .task {
            await SessionManager.shared.bootstrap()
        }
        // Menu-bar / keyboard-shortcut driven tab switching from `MacCommands`. The
        // notification is meaningful only on Mac (where the menu bar exists) and on iPad
        // with a hardware keyboard; everywhere else nobody posts it and this is a no-op.
        .onReceive(NotificationCenter.default.publisher(for: .freetubeSelectTab)) { note in
            if let tab = note.object as? Tab {
                selectedTab = tab
            }
        }
    }
}
