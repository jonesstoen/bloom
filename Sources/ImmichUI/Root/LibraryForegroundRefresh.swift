import Foundation
import SwiftUI

/// Decides when coming back to Bloom revalidates the Library, so photos deleted or added
/// elsewhere (the Immich website, another device) show up like they do in Photos.
///
/// Only a real return from the background counts, and only after a while: Control Center,
/// Face ID or a system prompt go `.active` → `.inactive` → `.active` and never reload, and a
/// quick look at another app keeps the Library as it is.
struct LibraryForegroundRefresh {
    /// Seconds in the background before coming back revalidates the Library.
    static let minimumBackgroundDuration: TimeInterval = 30

    /// When the app went to the background; `nil` while it is in the foreground.
    private var backgroundSince: Date?

    /// Records a scene phase change. Returns whether the Library should revalidate now.
    mutating func phaseChanged(to phase: ScenePhase, at now: Date) -> Bool {
        switch phase {
        case .background:
            if backgroundSince == nil { backgroundSince = now }
            return false
        case .active:
            guard let since = backgroundSince else { return false }
            backgroundSince = nil
            return now.timeIntervalSince(since) >= Self.minimumBackgroundDuration
        default:
            // `.inactive` lies on the way to and from the background: keep the timestamp.
            return false
        }
    }
}
