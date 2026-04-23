import Foundation
import SwiftUI

/// Published countdown for the final seconds of an active recording. Non-nil
/// only during the last N seconds before the max-duration cap forces a
/// submit — the pill swaps its waveform for this number while it's set.
///
/// Lives next to `AudioLevelMonitor` because the pill already observes
/// singletons of this shape; keeping it independent avoids piping timer
/// state through the SwiftUI tree.
@MainActor
final class SessionCountdown: ObservableObject {
    static let shared = SessionCountdown()

    /// Seconds remaining until auto-submit, or nil if no countdown is active.
    @Published private(set) var secondsRemaining: Int?

    private init() {}

    func set(_ seconds: Int) {
        // Clamp to avoid negative/zero flashes.
        let clamped = max(0, seconds)
        if secondsRemaining != clamped {
            secondsRemaining = clamped
        }
    }

    func clear() {
        if secondsRemaining != nil {
            secondsRemaining = nil
        }
    }
}
