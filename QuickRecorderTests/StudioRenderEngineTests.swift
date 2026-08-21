import CoreMedia
import CoreVideo
import Foundation
import Metal
import XCTest

final class StudioRenderEngineTests: XCTestCase {
    private let canvas = StudioCanvas(width: 128, height: 72)
    private let framesPerSecond = 60

    private struct Harness {
        let engine: StudioRenderEngine
        let clock: StudioTestClock
        let trigger: StudioManualTriggerSource
        let compositor: StudioStubCompositor
        let writer: StudioRecordingWriterSurface
        let frameInterval: TimeInterval
    }

    private func makeHarness(
        requiresWindow: Bool = false,
        framesPerSecond: Int? = nil
    ) -> Harness {
        let configuration = StudioRenderConfiguration(
            canvas: canvas,
            framesPerSecond: framesPerSecond ?? self.framesPerSecond,
            requiresWindow: requiresWindow
        )
        let clock = StudioTestClock()
        let trigger = StudioManualTriggerSource()
        let compositor = StudioStubCompositor()
        let writer = StudioRecordingWriterSurface(canvas: canvas)
        let engine = StudioRenderEngine(
            configuration: configuration,
            clock: clock,
            compositor: compositor,
            writerSurface: writer,
            triggerSource: trigger
        )
        return Harness(
            engine: engine,
            clock: clock,
            trigger: trigger,
            compositor: compositor,
            writer: writer,
            frameInterval: configuration.frameInterval
        )
    }

    private func feedCamera(_ harness: Harness) throws {
        let sample = try StudioTestBuffers.makeVideoSample(width: 64, height: 36)
        harness.engine.receiveCamera(sample)
    }

    private func feedWindow(_ harness: Harness) throws {
        let sample = try StudioTestBuffers.makeVideoSample(width: 96, height: 72)
        harness.engine.receiveWindow(sample)
    }

    // MARK: - Fixed clock

    func testStartSchedulesTheTriggerAtTheFrameInterval() {
        let harness = makeHarness()

        harness.engine.start()

        XCTAssertEqual(harness.trigger.startCount, 1)
        XCTAssertEqual(harness.trigger.interval ?? 0, 1.0 / 60, accuracy: 1e-12)
    }

    func testEachFixedClockTriggerProducesOneMonotonicOutputFrame() throws {
        let harness = makeHarness()
        try feedCamera(harness)
        harness.engine.start()

        for _ in 0..<10 {
            harness.clock.advance(seconds: harness.frameInterval)
            harness.trigger.fire()
        }

        let times = harness.writer.appendedVideoTimes
        XCTAssertEqual(times.count, 10)
        XCTAssertEqual(times.map(\.seconds), times.map(\.seconds).sorted())
        XCTAssertTrue(times.allSatisfy { $0.timescale == 60_000 })
        XCTAssertEqual(times.last?.seconds ?? 0, harness.frameInterval * 10, accuracy: 1e-4)
    }

    func testRenderIsDrivenByTheClockNotByCameraArrivals() throws {
        let harness = makeHarness()

        for _ in 0..<20 { try feedCamera(harness) }

        XCTAssertTrue(harness.writer.appendedVideoTimes.isEmpty)
        XCTAssertEqual(harness.compositor.composeCount, 0)
    }

    // MARK: - Rate guard

    func testRateGuardDropsATriggerEarlierThanThreeQuartersOfTheInterval() throws {
        let harness = makeHarness()
        try feedCamera(harness)

        harness.clock.advance(seconds: harness.frameInterval)
        XCTAssertEqual(harness.engine.renderOnce(), .appended(
            StudioTimeline.presentationTime(seconds: harness.frameInterval)
        ))

        harness.clock.advance(seconds: harness.frameInterval * 0.5)
        XCTAssertEqual(harness.engine.renderOnce(), .skippedRateGuard)
        XCTAssertEqual(harness.writer.appendedVideoTimes.count, 1)
    }

    func testRateGuardAdmitsATriggerAtThreeQuartersOfTheInterval() throws {
        let harness = makeHarness()
        try feedCamera(harness)

        harness.clock.advance(seconds: harness.frameInterval)
        harness.engine.renderOnce()
        harness.clock.advance(seconds: harness.frameInterval * 0.75)

        guard case .appended = harness.engine.renderOnce() else {
            return XCTFail("a trigger at the rate guard threshold must be admitted")
        }
        XCTAssertEqual(harness.writer.appendedVideoTimes.count, 2)
    }

    // The same threshold at a second frame rate, so a regression to a hardcoded
    // sixtieth of a second would be caught here.
    func testRateGuardTracksTheConfiguredFrameRateAtThirtyFramesPerSecond() throws {
        let harness = makeHarness(framesPerSecond: 30)
        try feedCamera(harness)
        XCTAssertEqual(harness.frameInterval, 1.0 / 30, accuracy: 1e-12)

        harness.clock.advance(seconds: harness.frameInterval)
        harness.engine.renderOnce()

        // A gap that clears the guard at 60 fps is still too early at 30 fps.
        harness.clock.advance(seconds: 1.0 / 60)
        XCTAssertEqual(harness.engine.renderOnce(), .skippedRateGuard)
        XCTAssertEqual(harness.writer.appendedVideoTimes.count, 1)

        harness.clock.advance(seconds: harness.frameInterval * 0.75)
        guard case .appended = harness.engine.renderOnce() else {
            return XCTFail("a trigger past the 30 fps threshold must be admitted")
        }
        XCTAssertEqual(harness.writer.appendedVideoTimes.count, 2)
    }

    func testTheFirstFrameIsNotHeldBackByTheRateGuard() throws {
        let harness = makeHarness()
        try feedCamera(harness)

        guard case .appended = harness.engine.renderOnce() else {
            return XCTFail("the first frame must not be rate guarded")
        }
    }

    // MARK: - Writer timestamps

    func testAWriterTimestampRegressionIsRejected() throws {
        let harness = makeHarness()
        try feedCamera(harness)

        harness.clock.advance(seconds: 1)
        harness.engine.renderOnce()
        harness.clock.rewind(seconds: 0.5)

        XCTAssertEqual(harness.engine.renderOnce(), .rejectedTimestamp)
        XCTAssertEqual(harness.writer.appendedVideoTimes.count, 1)
        XCTAssertNil(harness.engine.stopReason)
    }

    // Admission is reserved before the composite, so a frame that never reaches the
    // writer has to put the guard state back or the next trigger would be rejected
    // against a timestamp that was never written.
    func testASkippedFrameReleasesItsAdmissionReservation() throws {
        let harness = makeHarness()
        try feedCamera(harness)

        harness.clock.advance(seconds: 1)
        harness.writer.isReadyForVideo = false
        XCTAssertEqual(harness.engine.renderOnce(), .skippedWriterNotReady)

        harness.writer.isReadyForVideo = true
        XCTAssertEqual(harness.engine.renderOnce(), .appended(
            StudioTimeline.presentationTime(seconds: 1)
        ))
        XCTAssertEqual(harness.writer.appendedVideoTimes.count, 1)
    }

    func testASkippedAudioBufferReleasesItsAdmissionReservation() throws {
        let harness = makeHarness()
        harness.clock.advance(seconds: 1)
        harness.writer.readyTracks = []

        XCTAssertEqual(
            harness.engine.receiveAudio(
                try StudioTestBuffers.makeAudioSample(sampleCount: 4, startSeconds: 0),
                track: .systemAudio
            ),
            .skippedWriterNotReady
        )

        harness.writer.readyTracks = [.systemAudio]
        XCTAssertEqual(
            harness.engine.receiveAudio(
                try StudioTestBuffers.makeAudioSample(sampleCount: 4, startSeconds: 0),
                track: .systemAudio
            ),
            .appended(StudioTimeline.presentationTime(seconds: 1))
        )
    }

    func testWriterNotReadySkipsTheFrameWithoutStoppingTheEngine() throws {
        let harness = makeHarness()
        try feedCamera(harness)
        harness.writer.isReadyForVideo = false

        harness.clock.advance(seconds: 1)

        XCTAssertEqual(harness.engine.renderOnce(), .skippedWriterNotReady)
        XCTAssertNil(harness.engine.stopReason)
    }

    func testAFailedVideoAppendStopsTheEngine() throws {
        let harness = makeHarness()
        try feedCamera(harness)
        harness.writer.videoAppendSucceeds = false
        harness.engine.start()

        harness.clock.advance(seconds: 1)

        XCTAssertEqual(harness.engine.renderOnce(), .stopped(.videoAppendFailed))
        XCTAssertEqual(harness.engine.stopReason, .videoAppendFailed)
        XCTAssertFalse(harness.trigger.isRunning)
    }

    func testAnUnavailablePixelBufferPoolStopsTheEngine() throws {
        let harness = makeHarness()
        try feedCamera(harness)
        harness.writer.poolIsUnavailable = true

        harness.clock.advance(seconds: 1)
        harness.engine.renderOnce()

        guard case .writerBufferUnavailable = try XCTUnwrap(harness.engine.stopReason) else {
            return XCTFail("an unavailable pool must stop the engine")
        }
    }

    // MARK: - Inputs

    func testRenderWaitsForACameraFrame() {
        let harness = makeHarness()
        harness.clock.advance(seconds: 1)

        XCTAssertEqual(harness.engine.renderOnce(), .skippedMissingCamera)
    }

    func testRenderWaitsForTheWindowWhenTheCanvasRequiresIt() throws {
        let harness = makeHarness(requiresWindow: true)
        try feedCamera(harness)
        harness.clock.advance(seconds: 1)

        XCTAssertEqual(harness.engine.renderOnce(), .skippedMissingWindow)

        try feedWindow(harness)
        guard case .appended = harness.engine.renderOnce() else {
            return XCTFail("the frame must render once the window arrives")
        }
        XCTAssertTrue(harness.compositor.lastWindowWasPresent)
    }

    // MARK: - Pause

    func testRenderIsSkippedWhilePausedAndPausedTimeNeverReachesTheOutputPTS() throws {
        let harness = makeHarness()
        try feedCamera(harness)

        harness.clock.advance(seconds: 1)
        harness.engine.renderOnce()

        harness.engine.setPaused(true)
        harness.clock.advance(seconds: 30)
        XCTAssertEqual(harness.engine.renderOnce(), .skippedPaused)

        harness.engine.setPaused(false)
        harness.clock.advance(seconds: 1)
        harness.engine.renderOnce()

        let times = harness.writer.appendedVideoTimes.map(\.seconds)
        XCTAssertEqual(times.count, 2)
        XCTAssertEqual(times[0], 1, accuracy: 1e-4)
        XCTAssertEqual(times[1], 2, accuracy: 1e-4)
    }

    // MARK: - Fail-closed privacy

    func testASentinelOnTheCompositedFrameStopsTheEngineBeforeItIsWritten() throws {
        let harness = makeHarness()
        try feedCamera(harness)
        harness.compositor.writesPrivacyMarker = true
        harness.engine.start()

        harness.clock.advance(seconds: 1)

        XCTAssertEqual(
            harness.engine.renderOnce(),
            .stopped(.privacySentinelRendered(pixels: 1))
        )
        XCTAssertTrue(harness.writer.appendedVideoTimes.isEmpty)
        XCTAssertFalse(harness.trigger.isRunning)
    }

    func testASentinelAtWindowIngressStopsTheEngineBeforeItReachesTheCache() throws {
        let harness = makeHarness(requiresWindow: true)
        try feedCamera(harness)
        harness.engine.start()

        let buffer = try StudioTestBuffers.makePixelBuffer(width: 96, height: 72)
        StudioTestBuffers.setPixel(
            buffer,
            x: 48,
            y: 36,
            value: StudioPrivacySentinel.opaqueMarker
        )
        harness.engine.receiveWindow(try StudioTestBuffers.makeVideoSample(from: buffer))

        guard case .windowIngressFailed = try XCTUnwrap(harness.engine.stopReason) else {
            return XCTFail("a sentinel at ingress must stop the engine")
        }
        XCTAssertFalse(harness.trigger.isRunning)

        harness.clock.advance(seconds: 1)
        XCTAssertEqual(harness.engine.renderOnce(), .skippedStopped)
    }

    func testTheFirstStopReasonIsTheOneThatIsKept() throws {
        let harness = makeHarness()
        try feedCamera(harness)
        harness.compositor.writesPrivacyMarker = true

        harness.clock.advance(seconds: 1)
        harness.engine.renderOnce()
        harness.engine.stop(reason: .requested("later"))

        XCTAssertEqual(harness.engine.stopReason, .privacySentinelRendered(pixels: 1))
    }

    // MARK: - Audio

    func testAudioIsStampedFromTheSameWallClockAsVideo() throws {
        let harness = makeHarness()
        try feedCamera(harness)

        harness.clock.advance(seconds: 1.25)
        harness.engine.renderOnce()
        let sample = try StudioTestBuffers.makeAudioSample(sampleCount: 4, startSeconds: 900)
        XCTAssertEqual(
            harness.engine.receiveAudio(sample, track: .systemAudio),
            .appended(StudioTimeline.presentationTime(seconds: 1.25))
        )

        XCTAssertEqual(harness.writer.appendedVideoTimes.first?.seconds ?? 0, 1.25, accuracy: 1e-4)
        XCTAssertEqual(
            harness.writer.appendedAudioTimes(for: .systemAudio).first?.seconds ?? 0,
            1.25,
            accuracy: 1e-4
        )
    }

    func testAudioStaysMonotonicAcrossPauseAndResume() throws {
        let harness = makeHarness()

        for step in 0..<4 {
            harness.clock.advance(seconds: 0.2)
            let sample = try StudioTestBuffers.makeAudioSample(
                sampleCount: 4,
                startSeconds: Double(step) * 11
            )
            harness.engine.receiveAudio(sample, track: .microphone)
            if step == 1 {
                harness.engine.setPaused(true)
                harness.clock.advance(seconds: 20)
                harness.engine.setPaused(false)
            }
        }

        let seconds = harness.writer.appendedAudioTimes(for: .microphone).map(\.seconds)
        XCTAssertEqual(seconds.count, 4)
        XCTAssertEqual(seconds, seconds.sorted())
        XCTAssertEqual(seconds.last ?? 0, 0.8, accuracy: 1e-4)
    }

    func testAudioIsDroppedWhilePaused() throws {
        let harness = makeHarness()
        harness.engine.setPaused(true)
        harness.clock.advance(seconds: 1)

        let sample = try StudioTestBuffers.makeAudioSample(sampleCount: 4, startSeconds: 0)

        XCTAssertEqual(harness.engine.receiveAudio(sample, track: .systemAudio), .skippedPaused)
        XCTAssertTrue(harness.writer.appendedAudio.isEmpty)
    }

    func testEachAudioTrackKeepsItsOwnMonotonicGuard() throws {
        let harness = makeHarness()

        harness.clock.advance(seconds: 1)
        harness.engine.receiveAudio(
            try StudioTestBuffers.makeAudioSample(sampleCount: 4, startSeconds: 0),
            track: .systemAudio
        )
        // The microphone track has not seen this instant yet, so it is admitted.
        XCTAssertEqual(
            harness.engine.receiveAudio(
                try StudioTestBuffers.makeAudioSample(sampleCount: 4, startSeconds: 0),
                track: .microphone
            ),
            .appended(StudioTimeline.presentationTime(seconds: 1))
        )
        // The system track has, so a repeat at the same instant is rejected.
        XCTAssertEqual(
            harness.engine.receiveAudio(
                try StudioTestBuffers.makeAudioSample(sampleCount: 4, startSeconds: 0),
                track: .systemAudio
            ),
            .rejectedTimestamp
        )
    }

    func testAudioIsSkippedWhenTheWriterTrackIsNotReady() throws {
        let harness = makeHarness()
        harness.writer.readyTracks = [.microphone]
        harness.clock.advance(seconds: 1)

        let sample = try StudioTestBuffers.makeAudioSample(sampleCount: 4, startSeconds: 0)

        XCTAssertEqual(
            harness.engine.receiveAudio(sample, track: .systemAudio),
            .skippedWriterNotReady
        )
    }

    // MARK: - Core Image compositor

    func testCoreImageCompositorFillsAnOpaqueSentinelFreeCanvas() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal is unavailable on this host")
        let compositor = try StudioCoreImageCompositor(canvas: canvas)
        let camera = try StudioTestBuffers.makePixelBuffer(width: 64, height: 36)
        StudioTestBuffers.fill(camera, withPixel: 0xff00_ff00)
        let output = try StudioTestBuffers.makePixelBuffer(width: canvas.width, height: canvas.height)
        StudioTestBuffers.fill(output, withPixel: StudioPrivacySentinel.opaqueMarker)

        compositor.compose(camera: camera, window: nil, into: output)

        XCTAssertEqual(StudioPrivacySentinel.countMarkerPixels(in: output), 0)
        XCTAssertEqual(StudioPrivacySentinel.countNonOpaqueExteriorPixels(in: output), 0)
    }

    func testCameraInsetSitsInsideTheCanvas() {
        XCTAssertTrue(canvas.rect.contains(canvas.cameraInsetRect))
    }
}
