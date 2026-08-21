import Foundation

/// The configured recording time limit. Every status-bar branch asks this one question on
/// each tick, so no recording path can enforce the limit differently.
enum CaptureAutoStop {
    static func shouldStop(autoStopMinutes: Int, elapsed: TimeInterval) -> Bool {
        autoStopMinutes != 0 && elapsed / 60 >= Double(autoStopMinutes)
    }
}
