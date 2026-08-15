import XCTest

final class PermissionFlowSourceTripwireTests: XCTestCase {
    func testDeniedContentRefreshDoesNotScheduleARecursiveRetry() throws {
        let source = try scContextSource()

        XCTAssertFalse(source.contains("asyncAfter(deadline: .now() + 1)"))
        XCTAssertFalse(source.contains("self.updateAvailableContent() {_ in}"))
    }

    func testLaunchRefreshIsAsyncAndUnavailableContentClearsReadiness() throws {
        let scContextSourceText = try scContextSource()
        let appSource = try quickRecorderAppSource()
        let contentViewSource = try source(named: "ViewModel/ContentView.swift")
        let contentViewNewSource = try source(named: "ViewModel/ContentViewNew.swift")

        XCTAssertFalse(scContextSourceText.contains("SCStreamError.userDeclined: requestPermissions()"))
        XCTAssertFalse(appSource.contains("SCContext.updateAvailableContentSync()"))
        XCTAssertTrue(appSource.contains("ScreenRecordingStartupPolicy().start"))
        XCTAssertTrue(scContextSourceText.contains("contentState.apply(result)"))
        XCTAssertTrue(scContextSourceText.contains("guard let content, !content.displays.isEmpty else"))
        XCTAssertTrue(scContextSourceText.contains("completion(.failure(.unavailable("))
        XCTAssertEqual(contentViewSource.components(separatedBy: "SCContext.recoverScreenRecordingAccess()").count - 1, 1)
        XCTAssertEqual(contentViewNewSource.components(separatedBy: "SCContext.recoverScreenRecordingAccess()").count - 1, 1)
    }

    private func scContextSource() throws -> String {
        try source(named: "SCContext.swift")
    }

    private func quickRecorderAppSource() throws -> String {
        try source(named: "QuickRecorderApp.swift")
    }

    private func source(named name: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("QuickRecorder")
            .appendingPathComponent(name)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
