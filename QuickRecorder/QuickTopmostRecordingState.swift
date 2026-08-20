import AppKit
import Combine
import Foundation

/// The window a Quick Topmost pill is tethered to. It travels with the capture request so
/// a failed start can never leave a pill on screen.
struct QuickTopmostPillTarget: Equatable {
    let windowTitle: String
    let windowFrame: CGRect
}

/// Window settings for the on-window pill. `sharingType = .none` is what keeps the pill out
/// of the captured output, the same exclusion the window-selection overlays use.
struct QuickTopmostPillWindowSettings: Equatable {
    static let excludedFromCapture = QuickTopmostPillWindowSettings(
        sharingType: .none,
        level: .statusBar
    )

    let sharingType: NSWindow.SharingType
    let level: NSWindow.Level

    func apply(to window: NSWindow) {
        window.sharingType = sharingType
        window.level = level
        // An empty title keeps closeAllWindow() from closing the pill mid-recording.
        window.title = ""
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    }
}

/// Minutes and seconds for both Quick Topmost readouts ("0:07", "1:05", "1:01:05").
enum QuickTopmostElapsed {
    static func text(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// The recording clock the surfaces read: the app's own elapsed time and pause flag, never
/// a second clock of their own.
struct QuickTopmostClockReading: Equatable {
    let elapsed: TimeInterval
    let isPaused: Bool
}

/// The one recording state both Quick Topmost surfaces read: the on-window pill and the
/// menu-bar indicator. Both render from `snapshot()` and both act through `requestStop()`
/// and `requestPause()`, so they cannot disagree and cannot stop or pause differently.
final class QuickTopmostRecordingState: ObservableObject {
    struct Snapshot: Equatable {
        let isRecording: Bool
        let isPaused: Bool
        let windowTitle: String
        let elapsed: String
    }

    static let shared = QuickTopmostRecordingState()

    @Published private(set) var isRecording = false
    @Published private(set) var windowTitle = ""

    /// Installed once at launch with the app's single stop and pause functions and its
    /// recording clock.
    var stopHandler: (() -> Void)?
    var pauseHandler: (() -> Void)?
    var clock: () -> QuickTopmostClockReading = { QuickTopmostClockReading(elapsed: 0, isPaused: false) }

    func begin(windowTitle: String) {
        self.windowTitle = windowTitle
        isRecording = true
    }

    func end() {
        isRecording = false
        windowTitle = ""
    }

    func requestStop() {
        guard isRecording else { return }
        stopHandler?()
    }

    func requestPause() {
        guard isRecording else { return }
        pauseHandler?()
        objectWillChange.send()
    }

    func snapshot() -> Snapshot {
        guard isRecording else {
            return Snapshot(
                isRecording: false,
                isPaused: false,
                windowTitle: "",
                elapsed: QuickTopmostElapsed.text(0)
            )
        }
        let reading = clock()
        return Snapshot(
            isRecording: true,
            isPaused: reading.isPaused,
            windowTitle: windowTitle,
            elapsed: QuickTopmostElapsed.text(reading.elapsed)
        )
    }
}
