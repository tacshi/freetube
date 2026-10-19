import SwiftUI

/// "Not interested" for the ⋯ menu of videos in a feed that supports it (the signed-in home
/// feed). The feed screen sets it in the environment; `VideoMoreActionsMenu` shows the item only
/// when `isAvailable` says YouTube offered it for that video. Unset everywhere else, so search
/// results, the player and library lists never show it.
@available(iOS 17.0, *)
struct NotInterestedAction {
    let isAvailable: (Video) -> Bool
    let perform: (Video) -> Void
}

@available(iOS 17.0, *)
extension EnvironmentValues {
    @Entry var notInterestedAction: NotInterestedAction?
}
