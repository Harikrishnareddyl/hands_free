import Foundation
import SwiftUI

/// Thin main-actor singleton that holds the current mic level (0…1). Written
/// to by `AudioRecorder` from its capture callback (hopped to the main actor)
/// and read by SwiftUI views — the hands-free waveform is the main consumer.
///
/// Lives outside `AudioRecorder` so pill views can observe levels without
/// plumbing the whole recorder through the SwiftUI tree.
@MainActor
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    /// Normalized 0…1. Smoothed with a simple EMA so the UI doesn't jitter
    /// between buffers.
    @Published private(set) var level: Float = 0

    private init() {}

    func update(_ newLevel: Float) {
        // EMA — alpha ~= 0.5 gives a snappy-but-not-jittery attack/release.
        let alpha: Float = 0.5
        level = alpha * newLevel + (1 - alpha) * level
    }

    func reset() {
        level = 0
    }
}
