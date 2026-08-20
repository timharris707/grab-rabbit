import AppKit
import XCTest

final class QuickTopmostSurfaceTests: XCTestCase {
    func testBothSurfacesReadOneStateAndCannotDisagree() {
        let state = QuickTopmostRecordingState()
        let start = Date(timeIntervalSinceReferenceDate: 0)

        let idlePill = state.snapshot(at: start)
        let idleIndicator = state.snapshot(at: start)
        XCTAssertEqual(idlePill, idleIndicator)
        XCTAssertFalse(idlePill.isRecording)

        state.begin(windowTitle: "Quarterly Dashboard", at: start)
        let livePill = state.snapshot(at: start.addingTimeInterval(7))
        let liveIndicator = state.snapshot(at: start.addingTimeInterval(7))
        XCTAssertEqual(livePill, liveIndicator)
        XCTAssertTrue(livePill.isRecording)
        XCTAssertEqual(livePill.windowTitle, "Quarterly Dashboard")
        XCTAssertEqual(livePill.elapsed, "0:07")

        state.end()
        XCTAssertEqual(state.snapshot(at: start.addingTimeInterval(9)), idleIndicator)
    }

    func testStoppingFromEitherSurfaceFiresTheSameStopFunction() {
        let state = QuickTopmostRecordingState()
        var stopCount = 0
        state.stopHandler = { stopCount += 1 }

        state.requestStop()
        XCTAssertEqual(stopCount, 0)

        state.begin(windowTitle: "Quarterly Dashboard", at: Date())
        state.requestStop() // pill
        state.requestStop() // indicator
        XCTAssertEqual(stopCount, 2)

        state.end()
        state.requestStop()
        XCTAssertEqual(stopCount, 2)
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
        XCTAssertFalse(surfaces.contains("SCContext.stopRecording"))
        XCTAssertFalse(surfaces.contains("DateComponentsFormatter"))
        XCTAssertEqual(occurrences(of: "state.snapshot(at: Date()).elapsed", in: surfaces), 2)
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
