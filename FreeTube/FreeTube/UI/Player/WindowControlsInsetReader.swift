import SwiftUI
import UIKit

/// Reports how far the iPadOS window controls (the close / minimize / tile "traffic lights" of a
/// windowed app) reach into this view's top edge beyond the regular safe area. 0 when there are
/// no window controls (iPhone, full-screen app, iPadOS < 26).
///
/// **Why it exists:** SwiftUI's safe area doesn't include the window controls, so the player's
/// video surface started right under them and they covered the player's top-bar controls.
/// UIKit exposes the controls' footprint through the corner-adapted safe area layout region
/// (iOS 26+); SwiftUI has no equivalent, hence this bridge.
///
/// Attach it to a container whose frame doesn't move when the reported inset is applied (e.g.
/// as a `.background` of the whole player), otherwise the measurement would feed back into
/// itself.
@available(iOS 17.0, *)
struct WindowControlsInsetReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReportingView, context: Context) {
        view.onChange = onChange
    }

    final class ReportingView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var lastReported: CGFloat = -1

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            var inset: CGFloat = 0
            if #available(iOS 26.0, *) {
                // Vertical corner adaptation grows the top inset to clear the window controls.
                let adapted = edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
                inset = max(0, adapted.top - safeAreaInsets.top)
            }
            guard abs(inset - lastReported) > 0.5 else { return }
            lastReported = inset
            // Deferred: reporting synchronously would mutate SwiftUI state mid-layout.
            let onChange = onChange
            DispatchQueue.main.async { onChange?(inset) }
        }
    }
}
