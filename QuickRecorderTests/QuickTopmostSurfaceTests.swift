import AppKit
import XCTest

final class QuickTopmostSurfaceTests: XCTestCase {
    func testBothSurfacesReadOneStateAndCannotDisagree() {
        let state = QuickTopmostRecordingState()
        var elapsed: TimeInterval = 0
        state.clock = { QuickTopmostClockReading(elapsed: elapsed, isPaused: false) }

        let idlePill = state.snapshot()
        let idleIndicator = state.snapshot()
        XCTAssertEqual(idlePill, idleIndicator)
        XCTAssertFalse(idlePill.isRecording)

        state.begin(windowTitle: "Quarterly Dashboard")
        elapsed = 7
        let livePill = state.snapshot()
        let liveIndicator = state.snapshot()
        XCTAssertEqual(livePill, liveIndicator)
        XCTAssertTrue(livePill.isRecording)
        XCTAssertEqual(livePill.windowTitle, "Quarterly Dashboard")
        XCTAssertEqual(livePill.elapsed, "0:07")

        state.end()
        XCTAssertEqual(state.snapshot(), idleIndicator)
    }

    func testStoppingFromEitherSurfaceFiresTheSameStopFunction() {
        let state = QuickTopmostRecordingState()
        var stopCount = 0
        state.stopHandler = { stopCount += 1 }

        state.requestStop()
        XCTAssertEqual(stopCount, 0)

        state.begin(windowTitle: "Quarterly Dashboard")
        state.requestStop() // pill
        state.requestStop() // indicator
        XCTAssertEqual(stopCount, 2)

        state.end()
        state.requestStop()
        XCTAssertEqual(stopCount, 2)
    }

    func testPausingFromTheIndicatorPausesTheRecording() {
        let state = QuickTopmostRecordingState()
        var isPaused = false
        var pauseCount = 0
        state.pauseHandler = {
            pauseCount += 1
            isPaused.toggle()
        }
        state.clock = { QuickTopmostClockReading(elapsed: 12, isPaused: isPaused) }

        state.requestPause()
        XCTAssertEqual(pauseCount, 0)

        state.begin(windowTitle: "Quarterly Dashboard")
        state.requestPause()
        XCTAssertEqual(pauseCount, 1)
        XCTAssertTrue(state.snapshot().isPaused)

        state.requestPause()
        XCTAssertEqual(pauseCount, 2)
        XCTAssertFalse(state.snapshot().isPaused)

        state.end()
        state.requestPause()
        XCTAssertEqual(pauseCount, 2)
    }

    func testSurfacesStillCannotDisagreeWhilePaused() {
        let state = QuickTopmostRecordingState()
        var isPaused = false
        var elapsed: TimeInterval = 12
        state.pauseHandler = { isPaused.toggle() }
        state.clock = { QuickTopmostClockReading(elapsed: elapsed, isPaused: isPaused) }
        state.begin(windowTitle: "Quarterly Dashboard")

        state.requestPause()
        let pausedPill = state.snapshot()
        let pausedIndicator = state.snapshot()
        XCTAssertEqual(pausedPill, pausedIndicator)
        XCTAssertTrue(pausedPill.isPaused)
        XCTAssertEqual(pausedPill.elapsed, "0:12")

        // The app's clock stops while paused, so both readouts freeze together.
        let stillPill = state.snapshot()
        XCTAssertEqual(stillPill, pausedIndicator)

        state.requestPause()
        elapsed = 20
        XCTAssertEqual(state.snapshot(), state.snapshot())
        XCTAssertFalse(state.snapshot().isPaused)
        XCTAssertEqual(state.snapshot().elapsed, "0:20")
    }

    func testPauseReachesBothSurfacesWithoutWaitingForATimerTick() throws {
        let state = QuickTopmostRecordingState()
        var isPaused = false
        state.pauseHandler = { isPaused.toggle() }
        state.clock = { QuickTopmostClockReading(elapsed: 12, isPaused: isPaused) }
        state.begin(windowTitle: "Quarterly Dashboard")

        // No timer tick between the request and the assertions.
        let revisionBeforePause = state.revision
        state.requestPause()
        XCTAssertNotEqual(state.revision, revisionBeforePause)
        XCTAssertTrue(state.snapshot().isPaused)

        let revisionBeforeResume = state.revision
        state.requestPause()
        XCTAssertNotEqual(state.revision, revisionBeforeResume)
        XCTAssertFalse(state.snapshot().isPaused)

        // Both surfaces refresh their rendered snapshot on that revision, so the paused
        // label and the pause glyph cannot lag a tick behind the state.
        let surfaces = try projectSource("QuickRecorder/ViewModel/QuickTopmostSurfaces.swift")
        XCTAssertEqual(
            occurrences(of: ".onChange(of: state.revision) { _ in snapshot = state.snapshot() }", in: surfaces),
            2
        )
    }

    func testAutoStopEnforcesTheConfiguredLimitOnBothStatusBarBranches() throws {
        XCTAssertFalse(CaptureAutoStop.shouldStop(autoStopMinutes: 0, elapsed: 6000))
        XCTAssertFalse(CaptureAutoStop.shouldStop(autoStopMinutes: 5, elapsed: 299))
        XCTAssertTrue(CaptureAutoStop.shouldStop(autoStopMinutes: 5, elapsed: 300))
        XCTAssertTrue(CaptureAutoStop.shouldStop(autoStopMinutes: 5, elapsed: 900))

        // Both recording branches tick through the same handler, so a Quick Topmost
        // recording cannot outlive the configured limit.
        let statusBarSource = try projectSource("QuickRecorder/ViewModel/StatusBar.swift")
        XCTAssertEqual(occurrences(of: ".onReceive(updateTimer) { _ in recordingTick() }", in: statusBarSource), 1)
        XCTAssertEqual(occurrences(of: "recordingTick()", in: statusBarSource), 3)
        XCTAssertEqual(occurrences(of: "CaptureAutoStop.shouldStop(", in: statusBarSource), 1)
        XCTAssertFalse(statusBarSource.contains("SCContext.autoStop != 0"))
        XCTAssertTrue(statusBarSource.contains("Recording Controller"))
    }

    func testPillWindowIsExcludedFromTheCapturedOutput() {
        let settings = QuickTopmostPillWindowSettings.excludedFromCapture
        XCTAssertEqual(settings.sharingType, .none)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settings.apply(to: panel)

        XCTAssertEqual(panel.sharingType, .none)
        // An empty title keeps closeAllWindow() from closing the pill mid-recording.
        XCTAssertEqual(panel.title, "")
        XCTAssertFalse(panel.isOpaque)
    }

    func testElapsedReadoutMatchesThePillFormat() {
        XCTAssertEqual(QuickTopmostElapsed.text(0), "0:00")
        XCTAssertEqual(QuickTopmostElapsed.text(-5), "0:00")
        XCTAssertEqual(QuickTopmostElapsed.text(7), "0:07")
        XCTAssertEqual(QuickTopmostElapsed.text(65), "1:05")
        XCTAssertEqual(QuickTopmostElapsed.text(3665), "1:01:05")
    }

    func testSurfacesShareOneStopPathAndOneReadout() throws {
        let surfaces = try projectSource("QuickRecorder/ViewModel/QuickTopmostSurfaces.swift")

        XCTAssertEqual(occurrences(of: "state.requestStop()", in: surfaces), 2)
        // Pause belongs to the menu-bar capsule only; the pill stays Stop-only.
        XCTAssertEqual(occurrences(of: "state.requestPause()", in: surfaces), 1)
        XCTAssertFalse(surfaces.contains("SCContext.stopRecording"))
        XCTAssertFalse(surfaces.contains("SCContext.pauseRecording"))
        XCTAssertFalse(surfaces.contains("DateComponentsFormatter"))
        // Each surface refreshes from the one snapshot twice: on the timer tick and on the
        // state's revision.
        XCTAssertEqual(occurrences(of: ".onReceive(updateTimer) { _ in snapshot = state.snapshot() }", in: surfaces), 2)
        XCTAssertEqual(occurrences(of: "snapshot = state.snapshot()", in: surfaces), 4)
        XCTAssertTrue(surfaces.contains("QuickTopmostPillWindowSettings.excludedFromCapture.apply(to: panel)"))
    }

    func testProductionWiringPresentsBothSurfacesFromOneRecordingState() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let statusBarSource = try projectSource("QuickRecorder/ViewModel/StatusBar.swift")
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")

        XCTAssertEqual(
            occurrences(of: "QuickTopmostRecordingState.shared.stopHandler = { SCContext.stopRecording() }", in: appSource),
            1
        )
        XCTAssertEqual(
            occurrences(of: "QuickTopmostRecordingState.shared.pauseHandler = { SCContext.pauseRecording() }", in: appSource),
            1
        )
        XCTAssertTrue(appSource.contains("QuickTopmostClockReading(elapsed: SCContext.getRecordingElapsed(), isPaused: SCContext.isPaused)"))
        XCTAssertTrue(appSource.contains("quickTopmost: QuickTopmostPillTarget("))
        XCTAssertTrue(engineSource.contains("QuickTopmostPresence.shared.activate(quickTopmost)"))
        XCTAssertTrue(contextSource.contains("QuickTopmostPresence.shared.dismiss()"))
        XCTAssertTrue(statusBarSource.contains("QuickTopmostIndicatorView()"))
        XCTAssertTrue(statusBarSource.contains("QuickTopmostRecordingState.shared.isRecording"))
    }

    func testQuickTopmostIsTheOnlyNameOnScreen() throws {
        let settingsSource = try projectSource("QuickRecorder/ViewModel/SettingsView.swift")
        let shortcutSource = try projectSource("QuickRecorder/QuickTopmostWindowShortcut.swift")
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let statusBarSource = try projectSource("QuickRecorder/ViewModel/StatusBar.swift")
        let surfaces = try projectSource("QuickRecorder/ViewModel/QuickTopmostSurfaces.swift")

        XCTAssertFalse(settingsSource.contains("Record Topmost Window"))
        XCTAssertTrue(settingsSource.contains("SItem(label: \"Quick Topmost\")"))
        XCTAssertTrue(settingsSource.contains("SGroupBox(label: \"Quick Topmost\")"))
        for source in [settingsSource, shortcutSource, contextSource, appSource, engineSource, statusBarSource, surfaces] {
            XCTAssertFalse(source.contains("Quick Topmost Window"))
        }
    }
}

private func occurrences(of needle: String, in source: String) -> Int {
    var count = 0
    var searchStart = source.startIndex
    while let range = source.range(of: needle, range: searchStart..<source.endIndex) {
        count += 1
        searchStart = range.upperBound
    }
    return count
}

private func projectSource(_ path: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(path),
        encoding: .utf8
    )
}
