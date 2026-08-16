import XCTest

final class QuickTopmostWindowShortcutTests: XCTestCase {
    func testUnavailableContentFailsClosedOnceWithoutCaptureResidue() {
        let harness = ShortcutHarness(
            refreshResults: [
                .failure(.unavailable("Display is asleep")),
                .failure(.unavailable("Content is still loading")),
                .failure(.unavailable("Content is still loading")),
            ]
        )

        harness.shortcut.trigger()
        harness.runScheduledRetries()

        XCTAssertEqual(harness.refreshCount, 3)
        XCTAssertEqual(harness.failures, [.contentUnavailable])
        XCTAssertEqual(harness.captureStartCount, 0)
        XCTAssertTrue(harness.outputReservations.isEmpty)
        XCTAssertTrue(harness.outputs.isEmpty)
        XCTAssertTrue(harness.stagingDirectories.isEmpty)
        XCTAssertTrue(harness.sidebands.isEmpty)
        XCTAssertNil(harness.globalTarget)
    }

    func testDisplayWakeMakesInitiallyUnavailableContentReady() {
        let expected = TestTarget(windowID: 22, processID: 200)
        let harness = ShortcutHarness(
            refreshResults: [
                .failure(.unavailable("Display is asleep")),
                .success(TestContent(targets: [expected])),
            ],
            frontmostProcessID: 200
        )

        harness.shortcut.trigger()
        harness.runScheduledRetries()

        XCTAssertEqual(harness.refreshCount, 2)
        XCTAssertEqual(harness.startedTargets, [expected])
        XCTAssertTrue(harness.failures.isEmpty)
    }

    func testProviderRefreshFailureIsBoundedAndVisibleOnce() {
        let harness = ShortcutHarness(
            refreshResults: [
                .failure(.unavailable("Refresh failed")),
                .failure(.unavailable("Refresh failed")),
                .failure(.unavailable("Refresh failed")),
            ]
        )

        harness.shortcut.trigger()
        harness.runScheduledRetries()

        XCTAssertEqual(harness.refreshCount, 3)
        XCTAssertEqual(harness.failures, [.contentUnavailable])
        XCTAssertEqual(harness.visibleErrorCount, 1)
    }

    func testPermissionFailureDoesNotRetryOrStartCapture() {
        let harness = ShortcutHarness(
            refreshResults: [
                .failure(.permissionDenied),
                .success(TestContent(targets: [.init(windowID: 20, processID: 200)])),
            ]
        )

        harness.shortcut.trigger()
        harness.runScheduledRetries()

        XCTAssertEqual(harness.refreshCount, 1)
        XCTAssertEqual(harness.failures, [.permissionDenied])
        XCTAssertEqual(harness.captureStartCount, 0)
        XCTAssertNil(harness.globalTarget)
    }

    func testLoadingProviderThatNeverCompletesTimesOutAndFailsClosed() {
        let harness = ShortcutHarness(refreshResults: [])

        harness.shortcut.trigger()
        harness.runScheduledRetries()

        XCTAssertEqual(harness.refreshCount, 3)
        XCTAssertEqual(harness.failures, [.contentUnavailable])
        XCTAssertEqual(harness.captureStartCount, 0)
        XCTAssertNil(harness.globalTarget)
    }

    func testLoadedContentWithoutTopmostWindowRetriesBeforeFailingClosed() {
        let otherWindow = TestTarget(windowID: 11, processID: 100)
        let harness = ShortcutHarness(
            refreshResults: Array(repeating: .success(TestContent(targets: [otherWindow])), count: 3),
            frontmostProcessID: 200
        )

        harness.shortcut.trigger()
        harness.runScheduledRetries()

        XCTAssertEqual(harness.refreshCount, 3)
        XCTAssertEqual(harness.failures, [.topmostWindowUnavailable])
        XCTAssertEqual(harness.captureStartCount, 0)
        XCTAssertNil(harness.globalTarget)
    }

    func testSameProcessRetryUsesOnlyTheCurrentTopmostWindow() {
        let stale = TestTarget(windowID: 10, processID: 100)
        let actual = TestTarget(windowID: 20, processID: 200)
        let harness = ShortcutHarness(
            refreshResults: [
                .failure(.unavailable("Display is asleep")),
                .failure(.unavailable("Content is still loading")),
                .failure(.unavailable("Content is still loading")),
                .success(TestContent(targets: [stale, actual])),
            ],
            frontmostProcessID: 100
        )

        harness.shortcut.trigger()
        harness.runScheduledRetries()
        XCTAssertEqual(harness.failures, [.contentUnavailable])

        harness.frontmostProcessID = 200
        harness.shortcut.trigger()

        XCTAssertEqual(harness.startedTargets, [actual])
        XCTAssertEqual(harness.globalTarget, actual)
        XCTAssertNotEqual(harness.globalTarget, stale)
    }

    func testReadinessDoesNotChangeMicrophoneOrSystemAudioChoices() {
        let target = TestTarget(windowID: 20, processID: 200)
        let harness = ShortcutHarness(
            refreshResults: [
                .failure(.unavailable("Content is still loading")),
                .success(TestContent(targets: [target])),
            ],
            frontmostProcessID: 200
        )
        harness.recordMicrophone = true
        harness.recordSystemAudio = false

        harness.shortcut.trigger()
        harness.runScheduledRetries()

        XCTAssertTrue(harness.recordMicrophone)
        XCTAssertFalse(harness.recordSystemAudio)
        XCTAssertEqual(harness.mediaChoicesAtStart, [.init(microphone: true, systemAudio: false)])
    }

    func testRepeatedTriggerWhileLoadingSharesOneBoundedAttempt() {
        let harness = ShortcutHarness(
            refreshResults: [
                .failure(.unavailable("Display is asleep")),
                .failure(.unavailable("Content is still loading")),
                .failure(.unavailable("Content is still loading")),
            ]
        )

        harness.shortcut.trigger()
        harness.shortcut.trigger()
        harness.shortcut.trigger()
        harness.runScheduledRetries()

        XCTAssertEqual(harness.refreshCount, 3)
        XCTAssertEqual(harness.failures, [.contentUnavailable])
    }

    func testProductionHotkeyUsesReadinessAdapterBeforeCaptureMutation() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let hotkey = try sourceSlice(
            in: appSource,
            from: "KeyboardShortcuts.onKeyDown(for: .startWithWindow)",
            through: "updateStatusBar()"
        )
        let shortcutRefresh = try sourceSlice(
            in: contextSource,
            from: "static func refreshAvailableContentForQuickTopmost",
            through: "static func recoverScreenRecordingAccess"
        )

        XCTAssertTrue(hotkey.contains("quickTopmostWindowShortcut.trigger()"))
        XCTAssertFalse(hotkey.contains("SCContext.getWindows()"))
        XCTAssertFalse(hotkey.contains("closeAllWindow()"))
        XCTAssertFalse(hotkey.contains("prepRecord("))
        XCTAssertTrue(appSource.contains("shareableContent: content"))
        XCTAssertFalse(contextSource.contains("availableContent!"))
        XCTAssertFalse(engineSource.contains("availableContent!"))
        XCTAssertFalse(shortcutRefresh.contains("presentRecovery"))
        XCTAssertFalse(shortcutRefresh.contains("NSWorkspace.shared.open"))
        XCTAssertFalse(shortcutRefresh.contains("CGRequestScreenCaptureAccess"))
    }
}

private struct TestContent {
    let targets: [TestTarget]
}

private struct TestTarget: Equatable {
    let windowID: Int
    let processID: Int
}

private struct TestMediaChoices: Equatable {
    let microphone: Bool
    let systemAudio: Bool
}

private final class ShortcutHarness {
    private var refreshResults: [Result<TestContent, ScreenRecordingContentError>]
    private var scheduledRetries = [() -> Void]()

    var frontmostProcessID: Int
    var refreshCount = 0
    var failures = [QuickTopmostWindowShortcutFailure]()
    var startedTargets = [TestTarget]()
    var outputReservations = [String]()
    var outputs = [URL]()
    var stagingDirectories = [URL]()
    var sidebands = [URL]()
    var globalTarget: TestTarget?
    var recordMicrophone = false
    var recordSystemAudio = false
    var mediaChoicesAtStart = [TestMediaChoices]()

    lazy var shortcut = QuickTopmostWindowShortcutAdapter<TestContent, TestTarget>(
        maximumAttempts: 3,
        refreshContent: { [unowned self] completion in
            refreshCount += 1
            if !refreshResults.isEmpty {
                completion(refreshResults.removeFirst())
            }
        },
        selectCurrentTarget: { [unowned self] content in
            content.targets.first(where: { $0.processID == frontmostProcessID })
        },
        scheduleRetry: { [unowned self] retry in
            scheduledRetries.append(retry)
        },
        scheduleAttemptTimeout: { [unowned self] timeout in
            scheduledRetries.append(timeout)
        },
        startCapture: { [unowned self] _, target in
            startedTargets.append(target)
            globalTarget = target
            outputReservations.append("reserved")
            mediaChoicesAtStart.append(
                TestMediaChoices(microphone: recordMicrophone, systemAudio: recordSystemAudio)
            )
        },
        showFailure: { [unowned self] failure in
            failures.append(failure)
        }
    )

    init(
        refreshResults: [Result<TestContent, ScreenRecordingContentError>],
        frontmostProcessID: Int = 200
    ) {
        self.refreshResults = refreshResults
        self.frontmostProcessID = frontmostProcessID
    }

    var captureStartCount: Int { startedTargets.count }
    var visibleErrorCount: Int { failures.count }

    func runScheduledRetries() {
        while !scheduledRetries.isEmpty {
            scheduledRetries.removeFirst()()
        }
    }
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

private func sourceSlice(in source: String, from start: String, through end: String) throws -> String {
    let startRange = try XCTUnwrap(source.range(of: start))
    let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
    return String(source[startRange.lowerBound..<endRange.upperBound])
}
