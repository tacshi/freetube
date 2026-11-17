import Foundation
import UIKit

/// Helpers that only do something useful when the app is running on macOS — the Mac Catalyst
/// build (`isMacCatalystApp`), or the iPad build run on an Apple-silicon Mac (`isiOSAppOnMac`).
/// On iPhone/iPad these are no-ops, so callers can always invoke them without guarding the host
/// platform themselves.
///
/// **Why a free namespace and not a `View` extension:** the reveal-in-Finder bridge uses
/// `NSWorkspace` via Objective-C runtime lookup — touching it inside SwiftUI code paths
/// would imply AppKit at compile time, which would break the iOS build. Keeping it here as
/// pure-Foundation API lets the file compile cleanly everywhere and run conditionally.
enum MacIntegration {
    /// The smallest window the Mac layouts are designed for. Catalyst windows always report a
    /// regular size class, so the phone layouts never take over in a narrow window; below this
    /// the regular layouts (player with side column, tile grids) would crowd.
    private static let minimumWindowSize = CGSize(width: 760, height: 560)

    /// True when the app is running on macOS: the Catalyst build, or the iPad build on a Mac.
    static var isRunningOnMac: Bool {
        let info = ProcessInfo.processInfo
        return info.isMacCatalystApp || info.isiOSAppOnMac
    }

    /// Keeps every window at least `minimumWindowSize`. Call once a window is on screen; a new
    /// window calls it again from its own root view. No-op off the Mac.
    static func restrictWindowSizes() {
        guard isRunningOnMac else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = minimumWindowSize
        }
    }

    /// Pops a Finder window selecting the file. Uses `NSWorkspace.sharedWorkspace
    /// .activateFileViewerSelectingURLs:` via Objective-C runtime lookup — we can't
    /// `import AppKit` because the binary also has to compile for iOS, but `NSWorkspace` is
    /// reachable from a Mac runtime via `NSClassFromString`.
    ///
    /// No-op when not running on a Mac runtime (the runtime check fails fast).
    static func revealInFinder(_ url: URL) {
        guard isRunningOnMac else { return }
        guard let workspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type else { return }
        let sel = NSSelectorFromString("sharedWorkspace")
        let workspace = workspaceClass.perform(sel)?.takeUnretainedValue() as? NSObject
        _ = workspace?.perform(
            NSSelectorFromString("activateFileViewerSelectingURLs:"),
            with: [url] as NSArray
        )
    }
}
