import CoreMedia
import CoreVideo
import Foundation
import XCTest

final class StudioPrivacyIngressTests: XCTestCase {
    private let width = 96
    private let height = 72

    // MARK: - Sentinel scanning

    func testMarkerCountsBothTheTransparentAndTheOpaqueForm() throws {
        let buffer = try StudioTestBuffers.makePixelBuffer(width: 8, height: 8)
        StudioTestBuffers.setPixel(buffer, x: 1, y: 1, value: StudioPrivacySentinel.transparentMarker)
        StudioTestBuffers.setPixel(buffer, x: 2, y: 2, value: StudioPrivacySentinel.opaqueMarker)

        XCTAssertEqual(StudioPrivacySentinel.countMarkerPixels(in: buffer), 2)
    }

    func testTheTwoMarkerFormsShareOneColorAndDifferOnlyInAlpha() {
        XCTAssertEqual(StudioPrivacySentinel.transparentMarker, 0x00ff_4f00)
        XCTAssertEqual(StudioPrivacySentinel.opaqueMarker, 0xffff_4f00)
        XCTAssertEqual(
            StudioPrivacySentinel.opaqueMarker & 0x00ff_ffff,
            StudioPrivacySentinel.transparentMarker & 0x00ff_ffff
        )
    }

    func testACleanBufferReportsNoMarkerPixels() throws {
        let buffer = try StudioTestBuffers.makePixelBuffer(width: 16, height: 16)

        XCTAssertEqual(StudioPrivacySentinel.countMarkerPixels(in: buffer), 0)
        XCTAssertEqual(StudioPrivacySentinel.countNonOpaqueExteriorPixels(in: buffer), 0)
    }

    func testScanDepthMatchesTheSanitizerExteriorBand() {
        XCTAssertEqual(StudioPrivacySentinel.scanDepth(width: 1000, height: 800), 64)
        XCTAssertEqual(StudioPrivacySentinel.scanDepth(width: 40, height: 30), 15)
        XCTAssertEqual(StudioPrivacySentinel.scanDepth(width: 1, height: 1), 1)
    }

    func testNonOpaqueExteriorPixelsAreCountedBeforeSanitizing() throws {
        let buffer = try StudioTestBuffers.makePixelBuffer(width: width, height: height)
        StudioTestBuffers.setPixel(buffer, x: 0, y: 0, value: 0x0000_0000)
        StudioTestBuffers.setPixel(buffer, x: width - 1, y: height - 1, value: 0x8000_0000)

        XCTAssertEqual(StudioPrivacySentinel.countNonOpaqueExteriorPixels(in: buffer), 2)
    }

    // MARK: - Window ingress

    func testWindowIngressAcceptsASanitizedFrame() throws {
        let ingress = StudioFrameIngress()
        let sample = try StudioTestBuffers.makeVideoSample(width: width, height: height)

        let frame = try ingress.makeWindowFrame(from: sample, arrivalNanoseconds: 7)

        XCTAssertEqual(frame.sequence, 0)
        XCTAssertEqual(frame.arrivalNanoseconds, 7)
        XCTAssertEqual(StudioPrivacySentinel.countMarkerPixels(in: frame.pixelBuffer), 0)
        XCTAssertEqual(StudioPrivacySentinel.countNonOpaqueExteriorPixels(in: frame.pixelBuffer), 0)
    }

    func testWindowIngressMattesATransparentExteriorSentinel() throws {
        let ingress = StudioFrameIngress()
        let buffer = try StudioTestBuffers.makePixelBuffer(width: width, height: height)
        StudioTestBuffers.setPixel(buffer, x: 0, y: 0, value: StudioPrivacySentinel.transparentMarker)
        let sample = try StudioTestBuffers.makeVideoSample(from: buffer)

        let frame = try ingress.makeWindowFrame(from: sample, arrivalNanoseconds: 0)

        XCTAssertEqual(StudioPrivacySentinel.countMarkerPixels(in: frame.pixelBuffer), 0)
        XCTAssertEqual(StudioTestBuffers.pixel(frame.pixelBuffer, x: 0, y: 0), 0xff00_0000)
    }

    func testWindowIngressFailsClosedOnAMarkerTheSanitizerCannotReach() throws {
        let ingress = StudioFrameIngress()
        let buffer = try StudioTestBuffers.makePixelBuffer(width: width, height: height)
        // An opaque marker in the middle of the frame is outside the sanitizer's
        // exterior band, so the fail-closed scan is the only thing that catches it.
        StudioTestBuffers.setPixel(
            buffer,
            x: width / 2,
            y: height / 2,
            value: StudioPrivacySentinel.opaqueMarker
        )
        let sample = try StudioTestBuffers.makeVideoSample(from: buffer)

        XCTAssertThrowsError(try ingress.makeWindowFrame(from: sample, arrivalNanoseconds: 0)) { error in
            guard case .privacyBoundaryFailed(let markers, let nonOpaque) =
                error as? StudioIngressError else {
                return XCTFail("expected a privacy boundary failure, got \(error)")
            }
            XCTAssertEqual(markers, 1)
            XCTAssertEqual(nonOpaque, 0)
        }
    }

    func testWindowIngressRejectsAnUnsupportedPixelFormat() throws {
        let ingress = StudioFrameIngress()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer),
            kCVReturnSuccess
        )
        let sample = try StudioTestBuffers.makeVideoSample(from: try XCTUnwrap(buffer))

        XCTAssertThrowsError(try ingress.makeWindowFrame(from: sample, arrivalNanoseconds: 0))
    }

    func testWindowIngressCopiesOutOfTheSourceBuffer() throws {
        let ingress = StudioFrameIngress()
        let source = try StudioTestBuffers.makePixelBuffer(width: width, height: height)
        let sample = try StudioTestBuffers.makeVideoSample(from: source)

        let frame = try ingress.makeWindowFrame(from: sample, arrivalNanoseconds: 0)
        StudioTestBuffers.fill(source, withPixel: StudioPrivacySentinel.opaqueMarker)

        XCTAssertEqual(StudioPrivacySentinel.countMarkerPixels(in: frame.pixelBuffer), 0)
    }

    func testWindowIngressSequenceNumbersIncrement() throws {
        let ingress = StudioFrameIngress()
        let sample = try StudioTestBuffers.makeVideoSample(width: width, height: height)

        let first = try ingress.makeWindowFrame(from: sample, arrivalNanoseconds: 0)
        let second = try ingress.makeWindowFrame(from: sample, arrivalNanoseconds: 1)

        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(second.sequence, 1)
    }

    // MARK: - Camera ingress

    func testCameraIngressCopiesOutOfTheSourceBuffer() throws {
        let ingress = StudioFrameIngress()
        let source = try StudioTestBuffers.makePixelBuffer(width: 32, height: 32)
        StudioTestBuffers.fill(source, withPixel: 0xff11_2233)
        let sample = try StudioTestBuffers.makeVideoSample(from: source)

        let frame = try ingress.makeCameraFrame(from: sample, arrivalNanoseconds: 3)
        StudioTestBuffers.fill(source, withPixel: 0xffaa_bbcc)

        XCTAssertEqual(frame.sequence, 0)
        XCTAssertEqual(frame.arrivalNanoseconds, 3)
        XCTAssertEqual(StudioTestBuffers.pixel(frame.pixelBuffer, x: 4, y: 4), 0xff11_2233)
    }

    // MARK: - Latest-frame cache

    func testCacheStartsEmpty() {
        let snapshot = StudioFrameCache().snapshot()

        XCTAssertNil(snapshot.camera)
        XCTAssertNil(snapshot.window)
    }

    func testCacheReplacesTheHeldCameraFrameRatherThanQueueingIt() throws {
        let ingress = StudioFrameIngress()
        let cache = StudioFrameCache()
        let sample = try StudioTestBuffers.makeVideoSample(width: 32, height: 32)

        for index in 0..<5 {
            cache.storeCamera(
                try ingress.makeCameraFrame(from: sample, arrivalNanoseconds: UInt64(index))
            )
        }

        let snapshot = cache.snapshot()
        XCTAssertEqual(snapshot.camera?.sequence, 4)
        XCTAssertEqual(snapshot.camera?.arrivalNanoseconds, 4)
    }

    func testCacheReplacesTheHeldWindowFrameRatherThanQueueingIt() throws {
        let ingress = StudioFrameIngress()
        let cache = StudioFrameCache()
        let sample = try StudioTestBuffers.makeVideoSample(width: width, height: height)

        for index in 0..<3 {
            cache.storeWindow(
                try ingress.makeWindowFrame(from: sample, arrivalNanoseconds: UInt64(index) * 10)
            )
        }

        let snapshot = cache.snapshot()
        XCTAssertEqual(snapshot.window?.sequence, 2)
        XCTAssertEqual(snapshot.window?.arrivalNanoseconds, 20)
    }

    func testCameraAndWindowSlotsAreIndependent() throws {
        let ingress = StudioFrameIngress()
        let cache = StudioFrameCache()
        let camera = try StudioTestBuffers.makeVideoSample(width: 32, height: 32)

        cache.storeCamera(try ingress.makeCameraFrame(from: camera, arrivalNanoseconds: 1))

        XCTAssertNotNil(cache.snapshot().camera)
        XCTAssertNil(cache.snapshot().window)
    }
}
