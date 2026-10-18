import SwiftUI
import UIKit

/// Caps a screen's content to a centered readable column on wide layouts (full-screen iPad,
/// large Stage Manager windows, Mac). On iPhone and narrow iPad windows the container is
/// already narrower than `maxWidth`, so this is a no-op there.
///
/// **Why a frame and not `.contentMargins`.** `contentMargins` would keep the scroll view
/// edge-to-edge, but it propagates through the environment into every descendant scroll view —
/// including sheets presented from list rows (e.g. `VideoMoreActionsMenu` → add-to-playlist),
/// which would inherit the full-width inset and be squeezed to a sliver inside a form sheet.
/// A frame doesn't leak.
///
/// **Gutter background.** Tab root screens pass the background their list style paints so the
/// area outside the column matches. Pushed screens (`ChannelScreen`, `PlaylistScreen`, …) pass
/// `nil`: they're also mounted inside the player popup, whose backdrop must stay visible
/// (CLAUDE.md §8 — never introduce an opaque background in the popup body).
@available(iOS 17.0, *)
struct ReadableContentWidthModifier: ViewModifier {
    enum Gutter {
        /// Matches `.plain` lists and plain scroll views.
        case plain
        /// Matches `.insetGrouped` lists and `Form`.
        case grouped

        var color: Color {
            switch self {
            case .plain: Color(uiColor: .systemBackground)
            case .grouped: Color(uiColor: .systemGroupedBackground)
            }
        }
    }

    static let defaultMaxWidth: CGFloat = 720

    let maxWidth: CGFloat
    let gutter: Gutter?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
            .background {
                if let gutter {
                    gutter.color.ignoresSafeArea()
                }
            }
    }
}

@available(iOS 17.0, *)
extension View {
    /// Centers this content in a column at most `maxWidth` points wide. See
    /// `ReadableContentWidthModifier` for when to pass a `gutter`.
    func readableContentWidth(
        _ maxWidth: CGFloat = ReadableContentWidthModifier.defaultMaxWidth,
        gutter: ReadableContentWidthModifier.Gutter? = nil
    ) -> some View {
        modifier(ReadableContentWidthModifier(maxWidth: maxWidth, gutter: gutter))
    }
}
