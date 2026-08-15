import CoreVideo
import AVFoundation
import Foundation
import ScreenCaptureKit
import XCTest

final class WindowCapturePrivacyTests: XCTestCase {
    private let width = 64
    private let height = 48
    private let cornerRadius = 10
    private let testMatte = WindowCapturePrivacy.opaqueMatte
    private let sentinels: [WindowCaptureMatte] = [
        .init(red: 255, green: 79, blue: 0),
        .init(red: 255, green: 0, blue: 255),
        .init(red: 0, green: 255, blue: 255),
        .init(red: 0, green: 255, blue: 0),
    ]

    func testSentinelCornersAreSanitizedForEveryWallpaperAndMode() throws {
        for sentinel in sentinels {
            for mode in WindowCaptureMode.allCases {
                let buffer = try makeRoundedWindow(over: sentinel)
                try WindowCapturePrivacy.sanitize(buffer, mode: mode, matte: testMatte)

                XCTAssertEqual(CVPixelBufferGetWidth(buffer), width)
                XCTAssertEqual(CVPixelBufferGetHeight(buffer), height)

                let result = try inspectExterior(of: buffer, mode: mode, sentinel: sentinel)
                XCTAssertEqual(result.sentinelPixels, 0, "\(mode) leaked sentinel pixels")
                XCTAssertEqual(result.invalidPixels, 0, "\(mode) produced the wrong exterior")
            }
        }
    }

    func testWindowDimensionsFollowSourceContentAtBothResolutionSettings() {
        let source = CGRect(x: 500, y: 300, width: 987.5, height: 1040)

        let sourceResolution = WindowCapturePrivacy.pixelDimensions(
            contentRect: source,
            pointPixelScale: 2,
            highResolution: false
        )
        XCTAssertEqual(sourceResolution.width, 988)
        XCTAssertEqual(sourceResolution.height, 1040)

        let retinaResolution = WindowCapturePrivacy.pixelDimensions(
            contentRect: source,
            pointPixelScale: 2,
            highResolution: true
        )
        XCTAssertEqual(retinaResolution.width, 1975)
        XCTAssertEqual(retinaResolution.height, 2080)
    }

    func testTransparentAndOpaqueOutputProfilesAreExplicit() {
        let transparent = WindowCapturePrivacy.outputProfile(
            mode: .transparent,
            compatibilityFileType: .mp4,
            compatibilityCodec: .h264
        )
        XCTAssertEqual(transparent.fileExtension, "mov")
        XCTAssertEqual(transparent.fileType, .mov)
        XCTAssertEqual(transparent.codec, .proRes4444)
        XCTAssertTrue(transparent.preservesAlpha)

        for fileType in [AVFileType.mov, .mp4] {
            for codec in [AVVideoCodecType.h264, .hevc] {
                let opaque = WindowCapturePrivacy.outputProfile(
                    mode: .opaque,
                    compatibilityFileType: fileType,
                    compatibilityCodec: codec
                )
                XCTAssertEqual(opaque.fileType, fileType)
                XCTAssertEqual(opaque.codec, codec)
                XCTAssertFalse(opaque.preservesAlpha)
            }
        }
    }

    func testBackgroundColorIsClearOrExactOpaqueMatte() throws {
        XCTAssertEqual(WindowCapturePrivacy.opaqueMatte, WindowCaptureMatte(red: 0, green: 0, blue: 0))
        let transparent = WindowCapturePrivacy.backgroundColor(mode: .transparent, matte: testMatte)
        XCTAssertEqual(transparent.alpha, 0)

        let opaque = WindowCapturePrivacy.backgroundColor(mode: .opaque, matte: testMatte)
        let components = try XCTUnwrap(opaque.components)
        XCTAssertEqual(opaque.alpha, 1)
        XCTAssertEqual(components[0], CGFloat(testMatte.red) / 255, accuracy: 0.0001)
        XCTAssertEqual(components[1], CGFloat(testMatte.green) / 255, accuracy: 0.0001)
        XCTAssertEqual(components[2], CGFloat(testMatte.blue) / 255, accuracy: 0.0001)
    }

    func testConfigurationBackgroundColorHasAnOwnerBeyondItsAssignmentScope() {
        let configuration = SCStreamConfiguration()
        weak var assignedColor: CGColor?
        var session: CaptureOutputSession?

        autoreleasepool {
            let owner = CaptureConfigurationOwner(windowMode: .transparent, fallbackBackgroundColor: nil)
            owner.apply(to: configuration)
            assignedColor = owner.backgroundColor
            session = CaptureOutputSession(
                stream: NSObject(),
                outputJob: nil,
                writer: nil,
                videoInput: nil,
                systemAudioInput: nil,
                standaloneAudioFile: nil,
                configurationOwner: owner,
                sampleQueue: DispatchQueue(label: "WindowCapturePrivacyTests.color-owner"),
                isAudioOnly: false
            )
        }

        XCTAssertNotNil(assignedColor, "SCStreamConfiguration.backgroundColor is assign and needs a strong session owner")
        let copiedConfiguration = configuration.copy() as? SCStreamConfiguration
        XCTAssertEqual(copiedConfiguration?.backgroundColor.alpha, 0)
        withExtendedLifetime(session) {}
        withExtendedLifetime(configuration) {}
    }

    func testDelayedOldStreamCannotUseCurrentSessionPolicyOrWriter() throws {
        let streamA = NSObject()
        let streamB = NSObject()
        let sinkA = TestVideoDestination()
        let sinkB = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: sinkA)
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: sinkB)
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("capture should not stop") }
        )
        let delayedABuffer = try makeRoundedWindow(over: sentinels[0])
        let delayedASample = try makeSampleBuffer(imageBuffer: delayedABuffer)

        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(store.deactivate(sessionA))
        store.release(sessionA)
        XCTAssertTrue(store.install(sessionB))
        let result = core.handleSample(
            from: streamA,
            sampleBuffer: delayedASample,
            kind: .screen(isComplete: true, presenterOverlayX: nil)
        )

        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(sinkA.appendCount, 0)
        XCTAssertEqual(sinkB.appendCount, 0)
        let unchanged = try inspectExterior(of: delayedABuffer, mode: .transparent, sentinel: sentinels[0])
        XCTAssertGreaterThan(unchanged.sentinelPixels, 0, "B's opaque sanitizer must not touch a delayed A frame")

        let currentBBuffer = try makeRoundedWindow(over: sentinels[1])
        let currentBSample = try makeSampleBuffer(imageBuffer: currentBBuffer)
        XCTAssertEqual(
            core.handleSample(
                from: streamB,
                sampleBuffer: currentBSample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended
        )
        XCTAssertEqual(sinkA.appendCount, 0)
        XCTAssertEqual(sinkB.appendCount, 1)
        let sanitized = try inspectExterior(of: currentBBuffer, mode: .opaque, sentinel: sentinels[1])
        XCTAssertEqual(sanitized.sentinelPixels, 0)
        XCTAssertEqual(sanitized.invalidPixels, 0)
    }

    func testLateOldStreamCannotDeactivateCurrentSession() {
        let streamA = NSObject()
        let streamB = NSObject()
        let store = CaptureOutputSessionStore()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())

        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(store.deactivate(sessionA))
        store.release(sessionA)
        XCTAssertTrue(store.install(sessionB))

        XCTAssertNil(store.session(for: streamA))
        XCTAssertFalse(store.deactivate(sessionA), "a late A stop/error must not deactivate B")
        XCTAssertTrue(store.session(for: streamB) === sessionB)
    }

    func testInFlightSessionRevalidatesAfterReplacement() throws {
        let streamA = NSObject()
        let streamB = NSObject()
        let sinkA = TestVideoDestination()
        let sinkB = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: sinkA)
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: sinkB)
        XCTAssertTrue(store.install(sessionA))
        let capturedA = try XCTUnwrap(store.session(for: streamA))

        XCTAssertTrue(store.deactivate(sessionA))
        store.release(sessionA)
        XCTAssertTrue(store.install(sessionB))

        XCTAssertNil(store.acquire(capturedA))
        XCTAssertEqual(sinkA.appendCount, 0)
        XCTAssertEqual(sinkB.appendCount, 0)
    }

    func testRetiredSessionBlocksReplacementUntilFinalization() {
        let streamA = NSObject()
        let streamB = NSObject()
        let store = CaptureOutputSessionStore()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())

        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(store.deactivate(sessionA))
        XCTAssertFalse(store.install(sessionB), "B must not install while A can still finalize shared state")
        XCTAssertNil(store.session(for: streamB))

        store.release(sessionA)
        XCTAssertTrue(store.install(sessionB))
        XCTAssertFalse(store.deactivate(sessionA), "a late A stop must not deactivate B")
        XCTAssertTrue(store.session(for: streamB) === sessionB)
    }

    func testInFlightCallbackLeaseDelaysFinalizationAndBlocksReplacement() throws {
        let streamA = NSObject()
        let streamB = NSObject()
        let store = CaptureOutputSessionStore()
        let finalizedSessions = LockedSessionIDs()
        let finalizationFinished = expectation(description: "A finalization finished")
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { session in
                finalizedSessions.append(session.id)
                store.release(session)
                finalizationFinished.fulfill()
            }
        )
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))
        let leaseAcquired = expectation(description: "A callback acquired its lease")
        let callbackFinished = expectation(description: "A callback finished")
        let allowCallbackToContinue = DispatchSemaphore(value: 0)

        XCTAssertTrue(store.install(sessionA))
        DispatchQueue(label: "WindowCapturePrivacyTests.blocked-callback").async {
            let result = core.handleSample(
                from: streamA,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil),
                afterLeaseAcquired: {
                    leaseAcquired.fulfill()
                    _ = allowCallbackToContinue.wait(timeout: .now() + 2)
                }
            )
            XCTAssertEqual(result, .appended)
            callbackFinished.fulfill()
        }
        wait(for: [leaseAcquired], timeout: 2)

        XCTAssertTrue(core.handleStop(from: streamA))
        XCTAssertTrue(finalizedSessions.values.isEmpty, "A must not finalize while its callback is executing")
        XCTAssertFalse(store.install(sessionB), "B must not install while A is draining an in-flight callback")

        allowCallbackToContinue.signal()
        wait(for: [callbackFinished, finalizationFinished], timeout: 2)
        XCTAssertEqual(finalizedSessions.values, [sessionA.id])
        XCTAssertTrue(store.install(sessionB))
        XCTAssertTrue(store.session(for: streamB) === sessionB)
    }

    func testRepeatedStopDuringDrainIsHandledWithoutEarlyFinalization() {
        let streamA = NSObject()
        let streamB = NSObject()
        let store = CaptureOutputSessionStore()
        let finalizedSessions = LockedSessionIDs()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { session in
                finalizedSessions.append(session.id)
                store.release(session)
            }
        )

        XCTAssertTrue(store.install(sessionA))
        let heldLease = store.acquire(sessionA)
        XCTAssertNotNil(heldLease)

        XCTAssertTrue(core.handleStop(from: streamA))
        XCTAssertTrue(
            core.handleStop(from: streamA),
            "a repeated stop for a retired matching stream must be handled instead of falling through"
        )
        XCTAssertTrue(finalizedSessions.values.isEmpty, "A must not finalize while its callback lease is held")
        XCTAssertFalse(store.install(sessionB), "B must remain blocked while A is draining")

        heldLease?.release()
        XCTAssertEqual(finalizedSessions.values, [sessionA.id], "A must finalize exactly once")
        XCTAssertTrue(store.install(sessionB))
        XCTAssertTrue(store.session(for: streamB) === sessionB)
    }

    func testQueuedOldCallbackIsRejectedAfterDrainAndReplacement() throws {
        let streamA = NSObject()
        let streamB = NSObject()
        let sinkA = TestVideoDestination()
        let sinkB = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: sinkA)
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: sinkB)
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { store.release($0) }
        )
        let delayedSample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))

        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(core.handleStop(from: streamA))
        XCTAssertTrue(store.install(sessionB))

        XCTAssertEqual(
            core.handleSample(
                from: streamA,
                sampleBuffer: delayedSample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .rejected
        )
        XCTAssertEqual(sinkA.appendCount, 0)
        XCTAssertEqual(sinkB.appendCount, 0)
        XCTAssertTrue(store.session(for: streamB) === sessionB)
    }

    func testSanitizerFailureFinalizesOnlyItsExactSessionWithoutDeadlock() throws {
        let streamA = NSObject()
        let streamB = NSObject()
        let store = CaptureOutputSessionStore()
        let failedSessions = LockedSessionIDs()
        let stoppedSessions = LockedSessionIDs()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { session in
                failedSessions.append(session.id)
                store.release(session)
            },
            stopHandler: { session in
                stoppedSessions.append(session.id)
                store.release(session)
            }
        )
        let unsupportedBuffer = try makePixelBuffer(pixelFormat: kCVPixelFormatType_32ARGB)
        let unsupportedSample = try makeSampleBuffer(imageBuffer: unsupportedBuffer)

        XCTAssertTrue(store.install(sessionA))
        XCTAssertEqual(
            core.handleSample(
                from: streamA,
                sampleBuffer: unsupportedSample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .failed
        )
        XCTAssertEqual(failedSessions.values, [sessionA.id])
        XCTAssertTrue(stoppedSessions.values.isEmpty)
        XCTAssertTrue(store.install(sessionB), "the exact failed session must release its retired gate")
        XCTAssertTrue(store.session(for: streamB) === sessionB)
    }

    func testStartFailureHelperWaitsForExactSessionLeaseBeforeCleanup() {
        let streamA = NSObject()
        let streamB = NSObject()
        let store = CaptureOutputSessionStore()
        let cleanedSessions = LockedSessionIDs()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("stream should not stop") }
        )

        XCTAssertTrue(store.install(sessionA))
        let lease = store.acquire(sessionA)
        XCTAssertNotNil(lease)
        XCTAssertTrue(core.handleStartFailure(sessionA) { session in
            cleanedSessions.append(session.id)
            store.release(session)
        })

        XCTAssertTrue(cleanedSessions.values.isEmpty, "start-failure cleanup must wait for A's callback lease")
        XCTAssertFalse(store.install(sessionB), "B must remain blocked until failed A cleanup finishes")

        lease?.release()
        XCTAssertEqual(cleanedSessions.values, [sessionA.id])
        XCTAssertTrue(store.install(sessionB))
        XCTAssertTrue(store.session(for: streamB) === sessionB)
    }

    func testLateOldStreamErrorCannotStopOrFinalizeReplacement() {
        let streamA = NSObject()
        let streamB = NSObject()
        let store = CaptureOutputSessionStore()
        let finalizedSessions = LockedSessionIDs()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { session in
                finalizedSessions.append(session.id)
                store.release(session)
            }
        )

        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(core.handleStop(from: streamA))
        XCTAssertEqual(finalizedSessions.values, [sessionA.id])
        XCTAssertTrue(store.install(sessionB))

        XCTAssertFalse(core.handleStop(from: streamA), "a late didStopWithError for A must be ignored")
        XCTAssertEqual(finalizedSessions.values, [sessionA.id], "the late A error must not finalize B")
        XCTAssertTrue(store.session(for: streamB) === sessionB)
    }

    func testCaptureCoreSanitizesExteriorBeforeWriterAppend() throws {
        let stream = NSObject()
        let buffer = try makeRoundedWindow(over: sentinels[0])
        let sample = try makeSampleBuffer(imageBuffer: buffer)
        let sink = InspectingVideoDestination { [self] appendedBuffer in
            guard let imageBuffer = appendedBuffer.imageBuffer,
                  let result = try? inspectExterior(
                    of: imageBuffer,
                    mode: .transparent,
                    sentinel: sentinels[0]
                  ) else { return false }
            return result.sentinelPixels == 0 && result.invalidPixels == 0
        }
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(stream: stream, mode: .transparent, sink: sink)
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("capture should not stop") }
        )

        XCTAssertTrue(store.install(session))
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended
        )
        XCTAssertTrue(sink.observedSanitizedFrame, "the writer destination must see the sanitized frame")
    }

    func testSaveRequestPersistsUntilAnEligibleScreenFrame() throws {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        var savedFrames = 0
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination(),
            saveFrameHandler: { _ in savedFrames += 1 }
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("capture should not stop") }
        )
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))

        XCTAssertTrue(store.install(session))
        session.requestSaveFrame()

        XCTAssertEqual(core.handleSample(from: stream, sampleBuffer: sample, kind: .audio), .ignored)
        XCTAssertEqual(savedFrames, 0, "an audio callback must not consume a pending screenshot")
        XCTAssertTrue(session.stateSnapshot().saveFrameRequested)

        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: false, presenterOverlayX: nil)
            ),
            .ignored
        )
        XCTAssertEqual(savedFrames, 0, "an incomplete screen frame must not consume a pending screenshot")
        XCTAssertTrue(session.stateSnapshot().saveFrameRequested)

        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended
        )
        XCTAssertEqual(savedFrames, 1)
        XCTAssertFalse(session.stateSnapshot().saveFrameRequested)
    }

    func testSavedWindowFrameIsSanitizedBeforeTheSaveHandlerRuns() throws {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        var savedFrameWasSanitized = false
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination(),
            saveFrameHandler: { [self] sample in
                guard let imageBuffer = sample.imageBuffer,
                      let result = try? inspectExterior(
                        of: imageBuffer,
                        mode: .transparent,
                        sentinel: sentinels[0]
                      ) else { return }
                savedFrameWasSanitized = result.sentinelPixels == 0 && result.invalidPixels == 0
            }
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("capture should not stop") }
        )
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))

        XCTAssertTrue(store.install(session))
        session.requestSaveFrame()
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended
        )
        XCTAssertTrue(savedFrameWasSanitized, "save output must never observe raw exterior RGB")
    }

    func testSaveRequestRejectsInvalidAndImageLessScreenFrames() throws {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        var savedFrames = 0
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination(),
            saveFrameHandler: { _ in savedFrames += 1 }
        )
        let invalidSample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))
        CMSampleBufferInvalidate(invalidSample)
        let imageLessSample = try makeImageLessSampleBuffer()

        XCTAssertTrue(store.install(session))
        session.requestSaveFrame()
        XCTAssertEqual(
            core(for: store).handleSample(
                from: stream,
                sampleBuffer: invalidSample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .ignored
        )
        XCTAssertEqual(savedFrames, 0)
        XCTAssertTrue(session.stateSnapshot().saveFrameRequested)

        XCTAssertEqual(
            core(for: store).handleSample(
                from: stream,
                sampleBuffer: imageLessSample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .ignored
        )
        XCTAssertEqual(savedFrames, 0)
        XCTAssertTrue(session.stateSnapshot().saveFrameRequested)
    }

    func testAudioOnlySessionCannotConsumeSaveRequest() throws {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        var savedFrames = 0
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination(),
            isAudioOnly: true,
            saveFrameHandler: { _ in savedFrames += 1 }
        )
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))

        XCTAssertTrue(store.install(session))
        session.requestSaveFrame()
        XCTAssertEqual(
            core(for: store).handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .ignored
        )
        XCTAssertEqual(savedFrames, 0)
        XCTAssertTrue(session.stateSnapshot().saveFrameRequested)
    }

    func testPausedSaveRequestUsesAnEligibleSanitizedScreenFrame() throws {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        var savedFrameWasSanitized = false
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination(),
            saveFrameHandler: { [self] sample in
                guard let imageBuffer = sample.imageBuffer,
                      let result = try? inspectExterior(
                        of: imageBuffer,
                        mode: .transparent,
                        sentinel: sentinels[0]
                      ) else { return }
                savedFrameWasSanitized = result.sentinelPixels == 0 && result.invalidPixels == 0
            }
        )
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))

        XCTAssertTrue(store.install(session))
        XCTAssertTrue(session.togglePause())
        session.requestSaveFrame()
        XCTAssertEqual(
            core(for: store).handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .ignored
        )
        XCTAssertTrue(savedFrameWasSanitized)
        XCTAssertFalse(session.stateSnapshot().saveFrameRequested)
    }

    func testPreviewDoesNotRetainAnUnreadyUnsanitizedFrame() throws {
        let stream = NSObject()
        let sink = TestVideoDestination()
        sink.isReadyForMoreMediaData = false
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(stream: stream, mode: .transparent, sink: sink)
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("capture should not stop") }
        )
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))

        XCTAssertTrue(store.install(session))
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .ignored
        )

        let retainedFrame = session.capturedFirstFrame()
        XCTAssertNil(retainedFrame, "an unready writer must not retain a preview frame")
        if let retainedBuffer = retainedFrame?.imageBuffer {
            let result = try inspectExterior(
                of: retainedBuffer,
                mode: .transparent,
                sentinel: sentinels[0]
            )
            XCTAssertEqual(result.sentinelPixels, 0, "a retained preview must never expose exterior RGB")
            XCTAssertEqual(result.invalidPixels, 0, "a retained preview must use transparent sanitized corners")
        }
    }

    func testProductionPresenterGeometryChangeResumesAfterSafeDelay() throws {
        let stream = NSObject()
        let sink = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(stream: stream, mode: .transparent, sink: sink)
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let productionWiresPresenterReadiness = appSource.contains("presenterReadyHandler:")
        var core: CaptureOutputCore!
        core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("capture should not stop") },
            presenterReadyHandler: { outputSession in
                guard productionWiresPresenterReadiness else { return }
                core.markPresenterReady(outputSession)
            }
        )
        let firstSample = try makeSampleBuffer(
            imageBuffer: makeRoundedWindow(over: sentinels[0]),
            presentationTime: .zero
        )
        let secondSample = try makeSampleBuffer(
            imageBuffer: makeRoundedWindow(over: sentinels[1]),
            presentationTime: CMTime(value: 1, timescale: 30)
        )

        XCTAssertTrue(store.install(session))
        XCTAssertNotNil(core.handlePresenterStarted(from: stream))
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: firstSample,
                kind: .screen(isComplete: true, presenterOverlayX: 0)
            ),
            .ignored
        )

        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: secondSample,
                kind: .screen(isComplete: true, presenterOverlayX: 0)
            ),
            .appended,
            "production presenter readiness must resume capture after the configured safe delay"
        )
        XCTAssertEqual(sink.appendCount, 1)
    }

    func testStandaloneAudioFileClosesBeforePostprocessingHandlerRuns() throws {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-audio-lifetime-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        weak var weakAudioFile: AVAudioFile?
        var externalAudioFile: AVAudioFile?
        var lifecycleEvents = [String]()
        var session: CaptureOutputSession!

        try autoreleasepool {
            let format = try XCTUnwrap(
                AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
            )
            let audioFile = try AVAudioFile(forWriting: temporaryURL, settings: format.settings)
            weakAudioFile = audioFile
            externalAudioFile = audioFile
            session = CaptureOutputSession(
                stream: stream,
                outputJob: nil,
                writer: nil,
                videoInput: nil,
                systemAudioInput: nil,
                standaloneAudioFile: audioFile,
                configurationOwner: CaptureConfigurationOwner(
                    windowMode: .transparent,
                    fallbackBackgroundColor: nil
                ),
                sampleQueue: DispatchQueue(label: "WindowCapturePrivacyTests.audio-lifetime"),
                isAudioOnly: true,
                standaloneAudioAppender: { [audioFile] _ in withExtendedLifetime(audioFile) {} },
                standaloneAudioReleaseHandler: { releasedAudioFile in
                    XCTAssertTrue(externalAudioFile === releasedAudioFile)
                    lifecycleEvents.append("external-release")
                    externalAudioFile = nil
                }
            )
        }

        var audioWasOpenWhenPostprocessingBegan: Bool?
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { stoppedSession in
                lifecycleEvents.append("postprocessing")
                audioWasOpenWhenPostprocessingBegan = weakAudioFile != nil
                store.release(stoppedSession)
            }
        )

        XCTAssertNotNil(weakAudioFile)
        XCTAssertNotNil(externalAudioFile)
        XCTAssertTrue(store.install(session))
        XCTAssertTrue(core.handleStop(from: stream))
        XCTAssertEqual(lifecycleEvents, ["external-release", "postprocessing"])
        XCTAssertNil(externalAudioFile)
        XCTAssertEqual(
            audioWasOpenWhenPostprocessingBegan,
            false,
            "standalone audio ownership must be released before conversion or packaging starts"
        )
        XCTAssertNil(weakAudioFile)
    }

    func testStartFailureReleasesStandaloneAudioBeforeCleanup() throws {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-start-audio-lifetime-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        weak var weakAudioFile: AVAudioFile?
        var externalAudioFile: AVAudioFile?
        var lifecycleEvents = [String]()
        var session: CaptureOutputSession!

        try autoreleasepool {
            let format = try XCTUnwrap(
                AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
            )
            let audioFile = try AVAudioFile(forWriting: temporaryURL, settings: format.settings)
            weakAudioFile = audioFile
            externalAudioFile = audioFile
            session = CaptureOutputSession(
                stream: stream,
                outputJob: nil,
                writer: nil,
                videoInput: nil,
                systemAudioInput: nil,
                standaloneAudioFile: audioFile,
                configurationOwner: CaptureConfigurationOwner(
                    windowMode: .transparent,
                    fallbackBackgroundColor: nil
                ),
                sampleQueue: DispatchQueue(label: "WindowCapturePrivacyTests.failed-start-audio"),
                isAudioOnly: true,
                standaloneAudioAppender: { [audioFile] _ in withExtendedLifetime(audioFile) {} },
                standaloneAudioReleaseHandler: { releasedAudioFile in
                    XCTAssertTrue(externalAudioFile === releasedAudioFile)
                    lifecycleEvents.append("external-release")
                    externalAudioFile = nil
                }
            )
        }
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("stream should not stop") }
        )

        XCTAssertTrue(store.install(session))
        let heldLease = store.acquire(session)
        XCTAssertNotNil(heldLease)
        XCTAssertTrue(core.handleStartFailure(session) { failedSession in
            lifecycleEvents.append("cleanup")
            XCTAssertNil(weakAudioFile)
            store.release(failedSession)
        })
        XCTAssertTrue(lifecycleEvents.isEmpty)
        XCTAssertNotNil(weakAudioFile)

        heldLease?.release()
        XCTAssertEqual(lifecycleEvents, ["external-release", "cleanup"])
        XCTAssertNil(externalAudioFile)
        XCTAssertNil(weakAudioFile)
    }

    func testSessionElapsedTimeFreezesWhilePausedAndExcludesThePause() throws {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(stream: stream, mode: .transparent, sink: TestVideoDestination())
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("capture should not stop") }
        )
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))
        let startedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(store.install(session))
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil),
                now: startedAt
            ),
            .appended
        )
        XCTAssertEqual(session.stateSnapshot(now: startedAt.addingTimeInterval(10)).elapsedTime, 10)

        XCTAssertTrue(session.togglePause(now: startedAt.addingTimeInterval(10)))
        XCTAssertEqual(session.stateSnapshot(now: startedAt.addingTimeInterval(50)).elapsedTime, 10)

        XCTAssertFalse(session.togglePause(now: startedAt.addingTimeInterval(50)))
        XCTAssertEqual(session.stateSnapshot(now: startedAt.addingTimeInterval(55)).elapsedTime, 15)
    }

    func testProductionCaptureConfigurationRetainsAndAppliesItsOwner() throws {
        let source = try projectSource("QuickRecorder/RecordEngine.swift")
        let privacySource = try projectSource("QuickRecorder/WindowCapturePrivacy.swift")

        XCTAssertTrue(source.contains("let configurationOwner = CaptureConfigurationOwner("))
        XCTAssertTrue(source.contains("configurationOwner.apply(to: conf)"))
        XCTAssertTrue(source.contains("configurationOwner: configurationOwner"))
        XCTAssertTrue(source.contains("CaptureStreamConstruction.build(retaining: configurationOwner)"))
        XCTAssertTrue(privacySource.contains("withExtendedLifetime(owner) { builder() }"))
    }

    func testStreamConstructionSeamKeepsItsOwnerAliveThroughConstruction() {
        weak var weakOwner: LifetimeProbe?
        var ownerWasAliveDuringConstruction = false

        autoreleasepool {
            var owner: LifetimeProbe? = LifetimeProbe()
            weakOwner = owner
            let result = CaptureStreamConstruction.build(retaining: owner!) {
                owner = nil
                ownerWasAliveDuringConstruction = weakOwner != nil
                return "constructed"
            }
            XCTAssertEqual(result, "constructed")
        }

        XCTAssertTrue(ownerWasAliveDuringConstruction)
        XCTAssertNil(weakOwner)
    }

    func testProductionCallbackAdapterForwardsSamplesAndExactSessionStops() throws {
        let stream = NSObject()
        let sink = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let finalizedSessions = LockedSessionIDs()
        let session = makeCaptureSession(stream: stream, mode: .transparent, sink: sink)
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { stoppedSession in
                finalizedSessions.append(stoppedSession.id)
                store.release(stoppedSession)
            }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))

        XCTAssertTrue(store.install(session))
        XCTAssertEqual(
            adapter.handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended
        )
        XCTAssertEqual(sink.appendCount, 1)
        XCTAssertTrue(adapter.handleStop(from: stream))
        XCTAssertEqual(finalizedSessions.values, [session.id])
    }

    func testCaptureDelegatesAndUIStopUseTheProductionCallbackAdapter() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")

        XCTAssertTrue(engineSource.contains("captureStreamCallbackAdapter.handleSample("))
        XCTAssertTrue(engineSource.contains("captureStreamCallbackAdapter.handleStop(from: stream)"))
        XCTAssertTrue(engineSource.contains("session.releaseStandaloneAudioResources()"))
        XCTAssertTrue(contextSource.contains("captureStreamCallbackAdapter.handleStop(from: activeStream)"))
    }

    func testFFmpegReadsTransparentAndOpaqueFixtures() throws {
        let ffprobe = try XCTUnwrap(executable(named: "ffprobe"))
        let ffmpeg = try XCTUnwrap(executable(named: "ffmpeg"))
        let fixtures = [
            (mode: WindowCaptureMode.transparent, fileType: AVFileType.mov, codec: AVVideoCodecType.proRes4444, expectedCodec: "prores"),
            (mode: WindowCaptureMode.opaque, fileType: AVFileType.mp4, codec: AVVideoCodecType.h264, expectedCodec: "h264"),
            (mode: WindowCaptureMode.opaque, fileType: AVFileType.mov, codec: AVVideoCodecType.hevc, expectedCodec: "hevc"),
        ]

        for fixture in fixtures {
            let url = try writeFixture(
                mode: fixture.mode,
                fileType: fixture.fileType,
                codec: fixture.codec
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let probeData = try run(
                ffprobe,
                arguments: [
                    "-v", "error",
                    "-select_streams", "v:0",
                    "-show_entries", "stream=codec_name,pix_fmt,width,height:format=format_name",
                    "-of", "json",
                    url.path,
                ]
            )
            let probe = try XCTUnwrap(try JSONSerialization.jsonObject(with: probeData) as? [String: Any])
            let streams = try XCTUnwrap(probe["streams"] as? [[String: Any]])
            let stream = try XCTUnwrap(streams.first)
            let format = try XCTUnwrap(probe["format"] as? [String: Any])
            XCTAssertEqual(stream["codec_name"] as? String, fixture.expectedCodec)
            XCTAssertEqual(stream["width"] as? Int, width)
            XCTAssertEqual(stream["height"] as? Int, height)
            XCTAssertTrue((format["format_name"] as? String)?.contains("mov") == true)
            if fixture.mode == .transparent {
                XCTAssertTrue((stream["pix_fmt"] as? String)?.contains("yuva") == true)
            }

            let rgba = try run(
                ffmpeg,
                arguments: [
                    "-v", "error",
                    "-i", url.path,
                    "-frames:v", "1",
                    "-pix_fmt", "rgba",
                    "-f", "rawvideo",
                    "pipe:1",
                ]
            )
            XCTAssertEqual(rgba.count, width * height * 4)
            let bytes = [UInt8](rgba)
            for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
                let offset = (y * width + x) * 4
                if fixture.mode == .transparent {
                    XCTAssertEqual(bytes[offset + 3], 0)
                } else {
                    XCTAssertEqual(bytes[offset + 3], 255)
                    XCTAssertEqual(bytes[offset], testMatte.red, accuracy: 24)
                    XCTAssertEqual(bytes[offset + 1], testMatte.green, accuracy: 24)
                    XCTAssertEqual(bytes[offset + 2], testMatte.blue, accuracy: 24)
                }
            }
        }
    }

    func testNormalAndQuickWindowPathsUseTheSelectedModeWithoutMutatingAudioChoices() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let selectorSource = try projectSource("QuickRecorder/ViewModel/WinSelector.swift")
        let settingsSource = try projectSource("QuickRecorder/ViewModel/SettingsView.swift")

        XCTAssertTrue(engineSource.contains("SCContentFilter(desktopIndependentWindow: includ[0])"))
        XCTAssertTrue(selectorSource.contains("windowCaptureMode: windowCaptureMode"))
        XCTAssertTrue(appSource.contains("windowCaptureMode: windowCaptureMode"))
        XCTAssertTrue(appSource.contains("fastStart: true"))
        XCTAssertTrue(settingsSource.contains("Quick Topmost Window"))
        XCTAssertTrue(selectorSource.contains("Single-window exterior"))

        XCTAssertFalse(selectorSource.contains("recordWinSound ="))
        XCTAssertFalse(selectorSource.contains("recordMic ="))
        XCTAssertFalse(appSource.contains("recordWinSound ="))
        XCTAssertFalse(appSource.contains("recordMic ="))
    }

    private func makeRoundedWindow(over sentinel: WindowCaptureMatte) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw XCTSkip("Unable to allocate a BGRA test buffer: \(status)")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                if isExterior(x: x, y: y) {
                    row[offset] = sentinel.blue
                    row[offset + 1] = sentinel.green
                    row[offset + 2] = sentinel.red
                    row[offset + 3] = 0
                } else {
                    row[offset] = 231
                    row[offset + 1] = 232
                    row[offset + 2] = 233
                    row[offset + 3] = 255
                }
            }
        }
        return buffer
    }

    private func makeSampleBuffer(
        imageBuffer: CVPixelBuffer,
        presentationTime: CMTime = .zero
    ) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private func makeImageLessSampleBuffer() throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: nil,
                sampleCount: 0,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private func makePixelBuffer(pixelFormat: OSType) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw XCTSkip("Unable to allocate test pixel buffer: \(status)")
        }
        return buffer
    }

    private func makeCaptureSession(
        stream: AnyObject,
        mode: WindowCaptureMode,
        sink: any CaptureVideoSampleDestination,
        isAudioOnly: Bool = false,
        saveFrameHandler: ((CMSampleBuffer) -> Void)? = nil
    ) -> CaptureOutputSession {
        CaptureOutputSession(
            stream: stream,
            outputJob: nil,
            writer: nil,
            videoInput: sink,
            systemAudioInput: nil,
            standaloneAudioFile: nil,
            configurationOwner: CaptureConfigurationOwner(windowMode: mode, fallbackBackgroundColor: nil),
            sampleQueue: DispatchQueue(label: "WindowCapturePrivacyTests.\(mode.rawValue)"),
            isAudioOnly: isAudioOnly,
            saveFrameHandler: saveFrameHandler
        )
    }

    private func core(for store: CaptureOutputSessionStore) -> CaptureOutputCore {
        CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("capture should not stop") }
        )
    }

    private func writeFixture(
        mode: WindowCaptureMode,
        fileType: AVFileType,
        codec: AVVideoCodecType
    ) throws -> URL {
        let profile = WindowCapturePrivacy.outputProfile(
            mode: mode,
            compatibilityFileType: fileType,
            compatibilityCodec: codec
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-corner-\(UUID().uuidString)")
            .appendingPathExtension(profile.fileExtension)
        let writer = try AVAssetWriter(outputURL: url, fileType: profile.fileType)
        let settings = WindowCapturePrivacy.videoSettings(
            profile: profile,
            width: width,
            height: height,
            compressionProperties: [AVVideoExpectedSourceFrameRateKey: 30]
        )
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), writer.error?.localizedDescription ?? "writer did not start")
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<3 {
            let buffer = try makeRoundedWindow(over: sentinels[frame])
            try WindowCapturePrivacy.sanitize(buffer, mode: mode, matte: testMatte)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()

        let finished = expectation(description: "finish \(profile.codec.rawValue)")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "writer failed")
        return url
    }

    private func executable(named name: String) -> URL? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func run(_ executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: error, as: UTF8.self)
        )
        return output
    }

    private func inspectExterior(
        of buffer: CVPixelBuffer,
        mode: WindowCaptureMode,
        sentinel: WindowCaptureMatte
    ) throws -> (sentinelPixels: Int, invalidPixels: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var sentinelPixels = 0
        var invalidPixels = 0
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where isExterior(x: x, y: y) {
                let offset = x * 4
                let blue = row[offset]
                let green = row[offset + 1]
                let red = row[offset + 2]
                let alpha = row[offset + 3]
                if red == sentinel.red && green == sentinel.green && blue == sentinel.blue {
                    sentinelPixels += 1
                }
                switch mode {
                case .transparent:
                    if red != 0 || green != 0 || blue != 0 || alpha != 0 {
                        invalidPixels += 1
                    }
                case .opaque:
                    if red != testMatte.red || green != testMatte.green || blue != testMatte.blue || alpha != 255 {
                        invalidPixels += 1
                    }
                }
            }
        }
        return (sentinelPixels, invalidPixels)
    }

    private func isExterior(x: Int, y: Int) -> Bool {
        let left = x < cornerRadius
        let right = x >= width - cornerRadius
        let bottom = y < cornerRadius
        let top = y >= height - cornerRadius
        guard (left || right) && (bottom || top) else { return false }

        let centerX = left ? cornerRadius : width - cornerRadius - 1
        let centerY = bottom ? cornerRadius : height - cornerRadius - 1
        let dx = x - centerX
        let dy = y - centerY
        return dx * dx + dy * dy >= cornerRadius * cornerRadius
    }
}

private final class TestVideoDestination: CaptureVideoSampleDestination {
    var isReadyForMoreMediaData = true
    private(set) var appendCount = 0

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        appendCount += 1
        return true
    }
}

private final class InspectingVideoDestination: CaptureVideoSampleDestination {
    var isReadyForMoreMediaData = true
    private let inspection: (CMSampleBuffer) -> Bool
    private(set) var observedSanitizedFrame = false

    init(inspection: @escaping (CMSampleBuffer) -> Bool) {
        self.inspection = inspection
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        observedSanitizedFrame = inspection(sampleBuffer)
        return true
    }
}

private final class LockedSessionIDs {
    private let lock = NSLock()
    private var storage = [UUID]()

    var values: [UUID] { lock.withLock { storage } }

    func append(_ id: UUID) {
        lock.withLock { storage.append(id) }
    }
}

private final class LifetimeProbe {}
