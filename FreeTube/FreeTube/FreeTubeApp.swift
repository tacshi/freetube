//
//  FreeTubeApp.swift
//  FreeTube
//
//  Created by leshko on 17/5/26.
//
//  CLAUDE.md says iOS 16.0+, but SwiftData and `@Observable` require iOS 17.0+. The deployment
//  target should be bumped to 17.0 in the Xcode project; this file requires iOS 17.
//

import SwiftUI
import SwiftData

@main
@available(iOS 17.0, *)
struct FreeTubeApp: App {
    @State private var appEnvironment = AppEnvironment()
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment.playerStateManager)
                .modelContainer(PersistenceController.sharedContainer)
                // Settings → Appearance. Set on the windows rather than with
                // `.preferredColorScheme`, which doesn't reliably go back to following the
                // system once it has been given a fixed scheme. Runs in every window's
                // RootView, so a new iPad window picks it up too.
                .onChange(of: appearanceModeRaw, initial: true) { _, raw in
                    applyAppearance(AppearanceMode(rawValue: raw) ?? .system)
                }
        }
        // Menu-bar items + keyboard shortcuts. Only meaningful on Mac (via "Designed for
        // iPad on Mac" — Catalyst would also pick them up if we ever enable it), but
        // harmless to register everywhere — iPhone shows no menu bar, iPad-with-keyboard
        // picks up the shortcuts which is a fine bonus. See `MacCommands`.
        .commands {
            MacCommands(player: appEnvironment.playerStateManager)
        }
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            window.overrideUserInterfaceStyle = mode.userInterfaceStyle
        }
    }
}
