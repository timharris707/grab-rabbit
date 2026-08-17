import Foundation
import LiveProbeCore
import XCTest

final class SelectionTests: XCTestCase {
    func testNoCameraFailsBeforeOutputCreation() throws {
        var outputCreated = false

        XCTAssertThrowsError(
            try LiveSourceSelection.afterValidatedSources(
                cameraID: "missing-camera",
                cameras: [],
                windowID: nil,
                windows: [],
                createOutput: {
                    outputCreated = true
                    return URL(fileURLWithPath: "/tmp/must-not-exist.mov")
                }
            )
        ) { error in
            XCTAssertEqual(error as? LiveSourceSelectionError, .noCameras)
        }
        XCTAssertFalse(outputCreated)
    }

    func testCameraSelectionNeverSubstitutesAnotherDevice() throws {
        let available = StableCameraSource(uniqueID: "camera-a", name: "A", deviceType: "external")
        XCTAssertThrowsError(try LiveSourceSelection.camera(uniqueID: "camera-b", from: [available])) { error in
            XCTAssertEqual(error as? LiveSourceSelectionError, .cameraNotFound("camera-b"))
        }
    }

    func testWindowSelectionUsesExactWindowIdentity() throws {
        let available = CapturableWindowSource(
            windowID: 42,
            title: "Static browser",
            applicationName: "Browser",
            bundleIdentifier: "example.browser",
            width: 1280,
            height: 720
        )
        XCTAssertThrowsError(try LiveSourceSelection.window(windowID: 43, from: [available])) { error in
            XCTAssertEqual(error as? LiveSourceSelectionError, .windowNotFound(43))
        }
        XCTAssertEqual(try LiveSourceSelection.window(windowID: 42, from: [available]), available)
    }

    func testSelectionErrorsDoNotExposeExactIdentifiers() {
        let cameraID = "private-camera-identifier"
        let windowID: UInt32 = 987_654_321

        XCTAssertFalse(
            LiveSourceSelectionError.cameraNotFound(cameraID).description.contains(cameraID)
        )
        XCTAssertFalse(
            LiveSourceSelectionError.windowNotFound(windowID).description.contains(String(windowID))
        )
    }
}
