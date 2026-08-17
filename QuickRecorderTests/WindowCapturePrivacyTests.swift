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

    func testAppDelegateSharedResolvesTheSwiftUIApplicationDelegateWithoutConstructingAnother() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")
        let registry = ApplicationDelegateRegistry<TestCaptureDelegate>()
        let realDelegate = TestCaptureDelegate()
        let decoyDelegate = TestCaptureDelegate()
        let swiftUIApplicationDelegateProxy = NSObject()
        registry.register(realDelegate)
        let earlyResolved = try registry.resolve(applicationDelegate: nil)
        let installedResolved = try registry.resolve(applicationDelegate: realDelegate)
        let proxyResolved = try registry.resolve(applicationDelegate: swiftUIApplicationDelegateProxy)
        let streamA = NSObject()
        let streamB = NSObject()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())

        XCTAssertTrue(earlyResolved === realDelegate)
        XCTAssertTrue(installedResolved === realDelegate)
        XCTAssertTrue(proxyResolved === realDelegate, "SwiftUI may install its own NSApplication delegate proxy after the adaptor has registered the Grab Rabbit delegate")
        XCTAssertFalse(installedResolved === decoyDelegate)
        XCTAssertTrue(installedResolved.store.install(sessionA))
        XCTAssertTrue(installedResolved.adapter.handleStop(from: streamA))
        XCTAssertTrue(installedResolved.store.install(sessionB), "restart must use the same store released by Stop")
        XCTAssertThrowsError(try registry.resolve(applicationDelegate: decoyDelegate)) { error in
            XCTAssertEqual(error as? ApplicationDelegateRegistryError, .applicationDelegateMismatch)
        }

        XCTAssertTrue(appSource.contains("@NSApplicationDelegateAdaptor(AppDelegate.self)"))
        XCTAssertFalse(appSource.contains("static let shared = AppDelegate()"))
        XCTAssertTrue(appSource.contains("registry.resolve(applicationDelegate: NSApp.delegate)"))
        XCTAssertTrue(contextSource.contains("let sessions = AppDelegate.shared.captureOutputSessions"))
        XCTAssertTrue(contextSource.contains("AppDelegate.shared.captureStreamCallbackAdapter.handleStop"))
    }

    func testConcurrentApplicationDelegateResolutionUsesOneRegisteredIdentity() throws {
        let registry = ApplicationDelegateRegistry<TestCaptureDelegate>()
        let registeredDelegate = TestCaptureDelegate()
        let observations = LockedDelegateIdentities()
        registry.register(registeredDelegate)

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                observations.record(try registry.resolve(applicationDelegate: nil))
            } catch {
                observations.record(error)
            }
        }

        XCTAssertTrue(observations.errors.isEmpty)
        XCTAssertEqual(observations.identities, [ObjectIdentifier(registeredDelegate)])
    }

    func testAppDelegateRegistersBeforeEarlySwiftUIViewResolution() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")

        XCTAssertTrue(appSource.contains("ApplicationDelegateRegistry<AppDelegate>"))
        XCTAssertTrue(appSource.contains("Self.registry.register(self)"))
        XCTAssertTrue(appSource.contains("registry.resolve(applicationDelegate: NSApp.delegate)"))
        XCTAssertFalse(appSource.contains("static let shared = AppDelegate()"))
        XCTAssertFalse(appSource.contains("GRAB_RABBIT_HEADLESS"))
        XCTAssertFalse(appSource.contains("hiddenUI"))
    }

    func testMaximumRateFrameIntervalIsValidAndThirtyFPSRemainsOneThirtieth() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let sixtyFPSInterval = CaptureFrameCadence.minimumFrameInterval(frameRate: 60, audioOnly: false)
        let thirtyFPSInterval = CaptureFrameCadence.minimumFrameInterval(frameRate: 30, audioOnly: false)
        let audioInterval = CaptureFrameCadence.minimumFrameInterval(frameRate: 60, audioOnly: true)

        XCTAssertTrue(sixtyFPSInterval.isValid)
        XCTAssertEqual(sixtyFPSInterval, .zero)
        XCTAssertTrue(thirtyFPSInterval.isValid)
        XCTAssertEqual(thirtyFPSInterval.value, 1)
        XCTAssertEqual(thirtyFPSInterval.timescale, 30)
        XCTAssertTrue(audioInterval.isValid)
        XCTAssertNotEqual(audioInterval.timescale, 0)
        XCTAssertTrue(engineSource.contains("CaptureFrameCadence.minimumFrameInterval("))
    }

    func testCaptureDiagnosticsAreExplicitlyEnvironmentGatedAndAggregateOnly() throws {
        let privacySource = try projectSource("QuickRecorder/WindowCapturePrivacy.swift")
        var disabledLines = [String]()
        let disabledDiagnostics = CaptureDiagnostics.environmentConfigured(
            environment: [:],
            emitter: { disabledLines.append($0) }
        )
        disabledDiagnostics.recordScreenCallback(isValid: true, isComplete: true, hasImage: true)
        disabledDiagnostics.emitOnce(writerStatus: 1)
        XCTAssertTrue(disabledLines.isEmpty)

        var enabledLines = [String]()
        let enabledDiagnostics = CaptureDiagnostics.environmentConfigured(
            environment: [CaptureDiagnostics.environmentKey: "1"],
            emitter: { enabledLines.append($0) }
        )
        let stream = NSObject()
        let sink = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: sink,
            diagnostics: enabledDiagnostics
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { stoppedSession in store.release(stoppedSession) }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)

        XCTAssertTrue(store.install(session))
        XCTAssertEqual(
            adapter.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 0),
                kind: .screen(isComplete: false, presenterOverlayX: nil)
            ),
            .ignored
        )
        for index in 1...3 {
            XCTAssertEqual(
                adapter.handleSample(
                    from: stream,
                    sampleBuffer: try presenterSample(index: index),
                    kind: .screen(isComplete: true, presenterOverlayX: nil)
                ),
                .appended
            )
        }
        XCTAssertEqual(
            adapter.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 3),
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .ignored
        )
        sink.isReadyForMoreMediaData = false
        XCTAssertEqual(
            adapter.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 4),
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .ignored
        )
        sink.isReadyForMoreMediaData = true
        sink.appendResult = false
        XCTAssertEqual(
            adapter.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 5),
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appendFailed
        )
        sink.appendResult = true
        XCTAssertNotNil(core.handlePresenterStarted(from: stream))
        XCTAssertEqual(
            adapter.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 6),
                kind: .screen(isComplete: true, presenterOverlayX: 0)
            ),
            .ignored
        )
        XCTAssertTrue(adapter.handleStop(from: stream))
        XCTAssertFalse(adapter.handleStop(from: stream))

        XCTAssertEqual(enabledLines.count, 1)
        let line = try XCTUnwrap(enabledLines.first)
        XCTAssertTrue(line.contains("screen_callbacks=8"))
        XCTAssertTrue(line.contains("complete_frames=7"))
        XCTAssertTrue(line.contains("incomplete_frames=1"))
        XCTAssertTrue(line.contains("image_frames=8"))
        XCTAssertTrue(line.contains("pts_rejected=1"))
        XCTAssertTrue(line.contains("presenter_gate_rejected=1"))
        XCTAssertTrue(line.contains("writer_not_ready=1"))
        XCTAssertTrue(line.contains("append_succeeded=3"))
        XCTAssertTrue(line.contains("append_failed=1"))
        XCTAssertTrue(line.contains("writer_status=-1"))

        XCTAssertTrue(privacySource.contains("GRAB_RABBIT_CAPTURE_DIAGNOSTICS"))
        XCTAssertTrue(privacySource.contains("CaptureDiagnostics"))
        XCTAssertFalse(privacySource.contains("capturedPixels"))
        XCTAssertFalse(privacySource.contains("windowTitle"))
        XCTAssertFalse(privacySource.contains("audioContent"))
    }

    func testEnvironmentDiagnosticsPersistOneAggregateLineOnlyAtAnExplicitPath() throws {
        let pathKey = CaptureDiagnostics.pathEnvironmentKey
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let enabledURL = temporaryDirectory.appendingPathComponent("enabled.log")
        let disabledURL = temporaryDirectory.appendingPathComponent("disabled.log")

        let disabled = CaptureDiagnostics.environmentConfigured(
            environment: [pathKey: disabledURL.path]
        )
        disabled.recordScreenCallback(isValid: true, isComplete: true, hasImage: true)
        disabled.emitOnce(writerStatus: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disabledURL.path))

        let enabled = CaptureDiagnostics.environmentConfigured(
            environment: [
                CaptureDiagnostics.environmentKey: "1",
                pathKey: enabledURL.path,
            ]
        )
        enabled.recordScreenCallback(isValid: true, isComplete: true, hasImage: true)
        enabled.recordAudioCallback(isValid: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: enabledURL.path),
            "diagnostics must not emit per callback"
        )
        enabled.emitOnce(writerStatus: 1)
        enabled.emitOnce(writerStatus: 2)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: enabledURL.path),
            "LaunchServices diagnostics must survive at the explicitly requested path"
        )
        guard FileManager.default.fileExists(atPath: enabledURL.path) else { return }
        let contents = try String(contentsOf: enabledURL, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 1, "emitOnce must persist exactly one aggregate line")
        let line = try XCTUnwrap(lines.first).description
        let fields = line.split(separator: " ")
        XCTAssertEqual(fields.first, "[CaptureDiagnostics]")
        XCTAssertEqual(fields.dropFirst().count, 14)
        XCTAssertTrue(fields.dropFirst().allSatisfy { $0.contains("=") })
        XCTAssertEqual(
            Set(fields.dropFirst().compactMap { $0.split(separator: "=", maxSplits: 1).first }),
            Set([
                "screen_callbacks", "audio_callbacks", "invalid_callbacks",
                "complete_frames", "incomplete_frames", "image_frames", "image_missing",
                "pts_rejected", "presenter_gate_rejected", "writer_not_ready",
                "append_succeeded", "append_failed", "processing_failed", "writer_status",
            ])
        )
        XCTAssertTrue(line.contains("screen_callbacks=1"))
        XCTAssertTrue(line.contains("audio_callbacks=1"))
        XCTAssertTrue(line.contains("writer_status=1"))
        XCTAssertFalse(line.contains("writer_status=2"))
        XCTAssertFalse(line.contains("capturedPixels"))
        XCTAssertFalse(line.contains("windowTitle"))
        XCTAssertFalse(line.contains("audioContent"))
    }

    func testProductionAdapterAppendsMoreThanTwentyIncreasingCompleteFrames() throws {
        let stream = NSObject()
        let sink = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(stream: stream, mode: .transparent, sink: sink)
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { stoppedSession in store.release(stoppedSession) }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)

        XCTAssertTrue(store.install(session))
        for index in 0..<25 {
            XCTAssertEqual(
                adapter.handleSample(
                    from: stream,
                    sampleBuffer: try presenterSample(index: index),
                    kind: .screen(isComplete: true, presenterOverlayX: nil)
                ),
                .appended
            )
        }
        XCTAssertEqual(sink.appendCount, 25)
        XCTAssertGreaterThan(sink.appendCount, 1)
        XCTAssertTrue(adapter.handleStop(from: stream))
    }

    func testProductionAdapterAcceptsIncreasingPTSWhenScreenCaptureDurationIsInvalid() throws {
        let stream = NSObject()
        let sink = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        var diagnosticLines = [String]()
        let diagnostics = CaptureDiagnostics(enabled: true) { diagnosticLines.append($0) }
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: sink,
            diagnostics: diagnostics
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { stoppedSession in store.release(stoppedSession) }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)
        var acceptedPTS = [CMTime]()

        XCTAssertTrue(store.install(session))
        for index in 0..<6 {
            let presentationTime = CMTime(value: Int64(100 + index), timescale: 30)
            XCTAssertTrue(presentationTime.isValid)
            XCTAssertEqual(
                adapter.handleSample(
                    from: stream,
                    sampleBuffer: try makeSampleBuffer(
                        imageBuffer: makeRoundedWindow(over: sentinels[index % sentinels.count]),
                        presentationTime: presentationTime,
                        duration: .invalid
                    ),
                    kind: .screen(isComplete: true, presenterOverlayX: nil)
                ),
                .appended
            )
            let state = session.stateSnapshot()
            let lastPTS = try XCTUnwrap(state.lastPTS)
            XCTAssertTrue(lastPTS.isValid)
            XCTAssertEqual(lastPTS, presentationTime)
            XCTAssertEqual(state.frameCount, index + 1)
            if let previousPTS = acceptedPTS.last { XCTAssertGreaterThan(lastPTS, previousPTS) }
            acceptedPTS.append(lastPTS)
        }
        XCTAssertEqual(sink.appendCount, 6)
        XCTAssertGreaterThan(try XCTUnwrap(acceptedPTS.last), try XCTUnwrap(acceptedPTS.first))
        XCTAssertTrue(adapter.handleStop(from: stream))
        XCTAssertEqual(diagnosticLines.count, 1)
        XCTAssertTrue(try XCTUnwrap(diagnosticLines.first).contains("pts_rejected=0"))
        XCTAssertTrue(try XCTUnwrap(diagnosticLines.first).contains("append_succeeded=6"))
    }

    func testVideoAdmissionCommitsTimelineOnlyAfterAppendSucceeds() throws {
        let stream = NSObject()
        let sink = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        var firstFrames = 0
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: sink,
            firstFrameHandler: { _ in firstFrames += 1 }
        )
        let core = core(for: store)
        let firstPTS = CMTime.zero
        let secondPTS = CMTime(value: 1, timescale: 30)

        XCTAssertTrue(store.install(session))

        sink.isReadyForMoreMediaData = false
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try makeSampleBuffer(
                    imageBuffer: makeRoundedWindow(over: sentinels[0]),
                    presentationTime: firstPTS
                ),
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .ignored
        )
        XCTAssertNil(session.stateSnapshot().startTime)
        XCTAssertNil(session.stateSnapshot().lastPTS)
        XCTAssertEqual(session.stateSnapshot().frameCount, 0)
        XCTAssertNil(session.capturedFirstFrame())
        XCTAssertEqual(firstFrames, 0)

        sink.isReadyForMoreMediaData = true
        sink.appendResult = false
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try makeSampleBuffer(
                    imageBuffer: makeRoundedWindow(over: sentinels[0]),
                    presentationTime: firstPTS
                ),
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appendFailed
        )
        XCTAssertNil(session.stateSnapshot().startTime)
        XCTAssertNil(session.stateSnapshot().lastPTS)
        XCTAssertEqual(session.stateSnapshot().frameCount, 0)
        XCTAssertNil(session.capturedFirstFrame())
        XCTAssertEqual(firstFrames, 0)

        sink.appendResult = true
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try makeSampleBuffer(
                    imageBuffer: makeRoundedWindow(over: sentinels[0]),
                    presentationTime: firstPTS
                ),
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended,
            "an unready PTS must remain eligible for redelivery"
        )
        let firstCommittedState = session.stateSnapshot()
        XCTAssertNotNil(firstCommittedState.startTime)
        XCTAssertEqual(firstCommittedState.lastPTS, CMTime(value: 1, timescale: 30))
        XCTAssertEqual(firstCommittedState.frameCount, 1)
        XCTAssertNotNil(session.capturedFirstFrame())
        XCTAssertEqual(firstFrames, 1)

        sink.appendResult = false
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try makeSampleBuffer(
                    imageBuffer: makeRoundedWindow(over: sentinels[1]),
                    presentationTime: secondPTS
                ),
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appendFailed
        )
        let failedState = session.stateSnapshot()
        XCTAssertEqual(failedState.startTime, firstCommittedState.startTime)
        XCTAssertEqual(failedState.lastPTS, firstCommittedState.lastPTS)
        XCTAssertEqual(failedState.frameCount, firstCommittedState.frameCount)
        XCTAssertEqual(firstFrames, 1)

        sink.appendResult = true
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try makeSampleBuffer(
                    imageBuffer: makeRoundedWindow(over: sentinels[1]),
                    presentationTime: secondPTS
                ),
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended,
            "a failed append PTS must remain eligible for redelivery"
        )
        XCTAssertEqual(session.stateSnapshot().lastPTS, CMTime(value: 2, timescale: 30))
        XCTAssertEqual(session.stateSnapshot().frameCount, 2)
        XCTAssertEqual(sink.appendCount, 4)
        XCTAssertEqual(firstFrames, 1)
    }

    func testProductionTransparentPathCopiesIOSurfaceFramesBeforeProResEncoding() throws {
        let profile = WindowCapturePrivacy.outputProfile(
            mode: .transparent,
            compatibilityFileType: .mov,
            compatibilityCodec: .proRes4444
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-production-path-\(UUID().uuidString)")
            .appendingPathExtension(profile.fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: profile.fileType)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: WindowCapturePrivacy.videoSettings(
                profile: profile,
                width: width,
                height: height,
                compressionProperties: [AVVideoExpectedSourceFrameRateKey: 30]
            )
        )
        input.expectsMediaDataInRealTime = true
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), writer.error?.localizedDescription ?? "writer did not start")

        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let session = CaptureOutputSession(
            stream: stream,
            outputJob: nil,
            writer: writer,
            videoInput: input,
            systemAudioInput: nil,
            standaloneAudioFile: nil,
            configurationOwner: CaptureConfigurationOwner(windowMode: .transparent, fallbackBackgroundColor: nil),
            sampleQueue: DispatchQueue(label: "WindowCapturePrivacyTests.production-writer"),
            isAudioOnly: false
        )
        let core = core(for: store)
        XCTAssertTrue(store.install(session))

        for index in 0..<6 {
            let sentinel = sentinels[index % sentinels.count]
            let sourceBuffer = try makeRoundedWindow(over: sentinel)
            XCTAssertNotNil(CVPixelBufferGetIOSurface(sourceBuffer))
            XCTAssertTrue(waitUntilReady(input, timeout: 2), "writer remained backpressured before frame \(index)")
            XCTAssertEqual(
                core.handleSample(
                    from: stream,
                    sampleBuffer: try makeSampleBuffer(
                        imageBuffer: sourceBuffer,
                        presentationTime: CMTime(value: Int64(index), timescale: 30)
                    ),
                    kind: .screen(isComplete: true, presenterOverlayX: nil)
                ),
                .appended
            )
            XCTAssertGreaterThan(
                try inspectExterior(of: sourceBuffer, mode: .transparent, sentinel: sentinel).sentinelPixels,
                0,
                "the production path must not mutate a ScreenCaptureKit-owned IOSurface"
            )
        }

        input.markAsFinished()
        let finished = expectation(description: "finish production-path ProRes 4444")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "writer failed")

        let asset = AVURLAsset(url: url)
        XCTAssertGreaterThan(asset.duration, CMTime(value: 3, timescale: 30))
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "reader did not start")

        var decodedFrames = 0
        var previousPTS = CMTime.invalid
        while let decodedSample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(decodedSample)
            if previousPTS.isValid { XCTAssertGreaterThan(pts, previousPTS) }
            previousPTS = pts
            if decodedFrames == 0 {
                let decodedBuffer = try XCTUnwrap(decodedSample.imageBuffer)
                XCTAssertEqual(try exteriorCornerAlphas(of: decodedBuffer), [0, 0, 0, 0])
            }
            decodedFrames += 1
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "reader failed")
        XCTAssertGreaterThanOrEqual(decodedFrames, 3)
    }

    func testOpaqueCaptureKeepsClearBackgroundUntilTheSessionOwnedSanitizer() throws {
        let configuration = SCStreamConfiguration()
        let owner = CaptureConfigurationOwner(windowMode: .opaque, fallbackBackgroundColor: nil)

        owner.apply(to: configuration)

        XCTAssertEqual(configuration.backgroundColor.alpha, 0)
        XCTAssertEqual(owner.windowSanitizer?.mode, .opaque)
        XCTAssertEqual(owner.windowSanitizer?.matte, WindowCapturePrivacy.opaqueMatte)
        let outputMatte = WindowCapturePrivacy.backgroundColor(
            mode: .opaque,
            matte: WindowCapturePrivacy.opaqueMatte
        )
        XCTAssertEqual(outputMatte.alpha, 1)
        XCTAssertEqual(outputMatte.components, [0, 0, 0, 1])
    }

    func testProductionOpaqueH264SanitizesPrivateFramesBeforeEveryDecodedFrame() throws {
        let frameWidth = 1280
        let frameHeight = 904
        let frameCornerRadius = 36
        let frameCount = 9
        let profile = WindowCapturePrivacy.outputProfile(
            mode: .opaque,
            compatibilityFileType: .mp4,
            compatibilityCodec: .h264
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-production-opaque-\(UUID().uuidString)")
            .appendingPathExtension(profile.fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: profile.fileType)
        var videoSettings = WindowCapturePrivacy.videoSettings(
            profile: profile,
            width: frameWidth,
            height: frameHeight,
            compressionProperties: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
            ]
        )
        videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), writer.error?.localizedDescription ?? "writer did not start")

        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        var firstPrivateBuffer: CVPixelBuffer?
        let session = CaptureOutputSession(
            stream: stream,
            outputJob: nil,
            writer: writer,
            videoInput: input,
            systemAudioInput: nil,
            standaloneAudioFile: nil,
            configurationOwner: CaptureConfigurationOwner(windowMode: .opaque, fallbackBackgroundColor: nil),
            sampleQueue: DispatchQueue(label: "WindowCapturePrivacyTests.production-opaque-writer"),
            isAudioOnly: false,
            firstFrameHandler: { firstPrivateBuffer = $0.imageBuffer }
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("opaque sample processing should not fail") },
            stopHandler: { stoppedSession in store.release(stoppedSession) }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)
        XCTAssertTrue(store.install(session))

        var firstSourceBuffer: CVPixelBuffer?
        for index in 0..<frameCount {
            let sentinel = sentinels[index % sentinels.count]
            let sourceBuffer = try makeRoundedWindow(
                width: frameWidth,
                height: frameHeight,
                cornerRadius: frameCornerRadius,
                over: sentinel
            )
            if firstSourceBuffer == nil { firstSourceBuffer = sourceBuffer }
            XCTAssertNotNil(CVPixelBufferGetIOSurface(sourceBuffer))
            XCTAssertTrue(waitUntilReady(input, timeout: 2), "writer remained backpressured before frame \(index)")
            XCTAssertEqual(
                adapter.handleSample(
                    from: stream,
                    sampleBuffer: try makeSampleBuffer(
                        imageBuffer: sourceBuffer,
                        presentationTime: CMTime(value: Int64(index), timescale: 30)
                    ),
                    kind: .screen(isComplete: true, presenterOverlayX: nil)
                ),
                .appended
            )
            XCTAssertGreaterThan(
                try inspectExterior(
                    of: sourceBuffer,
                    mode: .transparent,
                    sentinel: sentinel,
                    width: frameWidth,
                    height: frameHeight,
                    cornerRadius: frameCornerRadius
                ).sentinelPixels,
                0,
                "the production path must not mutate source IOSurface frame \(index)"
            )
        }

        let privateBuffer = try XCTUnwrap(firstPrivateBuffer)
        let sourceBuffer = try XCTUnwrap(firstSourceBuffer)
        XCTAssertFalse(privateBuffer === sourceBuffer)
        let sanitized = try inspectExterior(
            of: privateBuffer,
            mode: .opaque,
            sentinel: sentinels[0],
            width: frameWidth,
            height: frameHeight,
            cornerRadius: frameCornerRadius
        )
        XCTAssertEqual(sanitized.sentinelPixels, 0)
        XCTAssertEqual(sanitized.invalidPixels, 0, "the private pre-encode frame must be exact #000000/A255")

        input.markAsFinished()
        let finished = expectation(description: "finish production-path opaque H.264")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "writer failed")

        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "reader did not start")

        var decodedFrames = 0
        var previousPTS = CMTime.invalid
        while let decodedSample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(decodedSample)
            if previousPTS.isValid { XCTAssertGreaterThan(pts, previousPTS) }
            previousPTS = pts
            for pixel in try exteriorCornerBGRA(of: XCTUnwrap(decodedSample.imageBuffer)) {
                XCTAssertLessThanOrEqual(pixel.blue, 24, "decoded frame \(decodedFrames) exceeded the codec black bound")
                XCTAssertLessThanOrEqual(pixel.green, 24, "decoded frame \(decodedFrames) exceeded the codec black bound")
                XCTAssertLessThanOrEqual(pixel.red, 24, "decoded frame \(decodedFrames) exceeded the codec black bound")
                XCTAssertEqual(pixel.alpha, 255)
            }
            decodedFrames += 1
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "reader failed")
        XCTAssertEqual(decodedFrames, frameCount)
        XCTAssertTrue(adapter.handleStop(from: stream))
    }

    func testProductionFinalizationReleasesExactlyOnceForSuccessFailureAndCancellation() throws {
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")
        let outcomes: [Result<Void, RecordingExportError>] = [
            .success(()),
            .failure(.failed(stage: .first, message: "writer failed")),
            .failure(.cancelled(stage: .first)),
        ]

        for (index, outcome) in outcomes.enumerated() {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("writer-outcome-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let job = try RecordingOutputJob.reserve(
                in: directory,
                preferredStem: "recording-\(index)",
                layout: .single(fileExtension: "mov")
            )
            XCTAssertTrue(FileManager.default.createFile(
                atPath: job.inputURL.path,
                contents: Data("writer output \(index)".utf8)
            ))
            let store = CaptureOutputSessionStore()
            let writer = DelayedCaptureWriterFinalizer()
            let sessionA = makeCaptureSession(
                stream: NSObject(),
                mode: .transparent,
                sink: TestVideoDestination(),
                outputJob: job,
                writerFinalizer: writer
            )
            let sessionB = UUID()
            let finalizer = CaptureSessionFinalizationCoordinator(store: store)
            var terminalResult: Result<URL, RecordingExportError>?
            var bodyCount = 0

            XCTAssertTrue(store.install(sessionA))
            XCTAssertTrue(store.deactivate(sessionA))
            XCTAssertFalse(store.reserve(sessionB), "B must remain blocked before A finalization")
            XCTAssertTrue(finalizer.finalize(sessionA) { finishSession in
                bodyCount += 1
                XCTAssertTrue(job.beginPostprocessing())
                sessionA.writerFinalizer?.finish { writerResult in
                    terminalResult = job.finishExport(writerResult)
                    finishSession()
                    finishSession()
                }
            })
            XCTAssertFalse(
                finalizer.finalize(sessionA) { _ in bodyCount += 1 },
                "Repeated Stop must not start a second finalization."
            )
            XCTAssertFalse(store.reserve(sessionB), "B must remain blocked while the writer is pending")
            XCTAssertEqual(job.lifecycle, .postprocessing)

            writer.complete(outcome)
            XCTAssertEqual(bodyCount, 1)
            XCTAssertEqual(job.lifecycle, .terminal)
            XCTAssertFalse(store.release(sessionA), "terminal release must happen exactly once")
            switch outcome {
            case .success:
                XCTAssertEqual(try terminalResult?.get(), job.finalURL)
                XCTAssertEqual(try Data(contentsOf: job.finalURL), Data("writer output \(index)".utf8))
            case .failure(let expectedError):
                guard case .failure(let actualError) = terminalResult else {
                    return XCTFail("Writer failure or cancellation must remain typed.")
                }
                XCTAssertEqual(actualError, expectedError)
                XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
            }
            XCTAssertFalse(
                store.reserve(sessionB),
                "B must remain blocked until terminal Stop-control dismissal."
            )
            store.acknowledgeStopControlDismissal()
            XCTAssertTrue(store.reserve(sessionB), "B may reserve after every terminal writer outcome")
            store.cancelReservation(sessionB)
        }

        XCTAssertTrue(contextSource.contains("CaptureProductionStopEntry(store: sessions).stop("))
        XCTAssertTrue(contextSource.contains("expectedSession: expectedSession"))
        XCTAssertFalse(contextSource.contains("if expectedSession == nil, let activeStream = stream"))
        XCTAssertFalse(contextSource.contains("writerFinalizer.finish"))
        XCTAssertFalse(contextSource.contains("finishedJob.beginPostprocessing"))
        XCTAssertFalse(contextSource.contains("switch finishedJob.kind"))
        XCTAssertFalse(
            contextSource.contains("if let sessionToRelease { sessions.release(sessionToRelease) }")
        )
    }

    func testProductionStopDoesNotSynchronouslyWaitForAssetWriter() throws {
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let statusSource = try projectSource("QuickRecorder/ViewModel/StatusBar.swift")
        let lifecycleSource = try projectSource("QuickRecorder/WindowCapturePrivacy.swift")

        XCTAssertFalse(
            contextSource.contains("dispatchGroup.wait()"),
            "Stop must return to the main run loop while AVAssetWriter finishes."
        )
        XCTAssertTrue(lifecycleSource.contains("writerFinalizer.finish { writerResult in"))
        XCTAssertTrue(contextSource.contains("body: \"Finalizing recording...\".local"))
        XCTAssertTrue(engineSource.contains("Another capture session is still finishing."))
        XCTAssertTrue(statusSource.contains("Text(CaptureFinalizationPresentation.statusText.local)"))
        XCTAssertTrue(statusSource.contains("!SCContext.isFinalizing && SCContext.streamType == nil"))
        XCTAssertTrue(appSource.contains("if SCContext.isFinalizing { return 112 }"))
    }

    func testProductionStopEntryHandlesRepeatedUIStopOnceAndKeepsMainResponsive() throws {
        XCTAssertTrue(Thread.isMainThread)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("production-stop-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let job = try RecordingOutputJob.reserve(
            in: directory,
            preferredStem: "recording-a",
            layout: .single(fileExtension: "mov")
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: job.inputURL.path,
            contents: Data("recording-a".utf8)
        ))
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let writer = DelayedCaptureWriterFinalizer()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination(),
            outputJob: job,
            writerFinalizer: writer
        )
        let entry = CaptureProductionStopEntry(store: store)
        let resources = CaptureProductionStopResources(
            outputJob: job,
            writerFinalizer: writer,
            isAudioOnly: false,
            markVideoInputFinished: {}
        )
        let replacementID = UUID()
        var activeStream: AnyObject? = stream
        var adapter: CaptureStreamCallbackAdapter!
        var actions: CaptureProductionStopActions!
        var finalizing = false
        var statusMessages = [String]()
        var fallbackCount = 0
        var prepareCount = 0
        var terminalCleanupCount = 0
        var pendingStatusDismissal: (() -> Void)?
        var terminalResult: Result<URL, RecordingExportError>?

        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("Stop must not take the failure route.") },
            stopHandler: { stoppedSession in
                XCTAssertEqual(
                    entry.stop(
                        expectedSession: stoppedSession,
                        activeStream: nil,
                        resolveResources: { _ in resources },
                        actions: actions
                    ),
                    .handled
                )
            }
        )
        adapter = CaptureStreamCallbackAdapter(core: core)
        actions = CaptureProductionStopActions(
            stopActiveStream: { adapter.handleStop(from: $0) },
            setFinalizing: { finalizing = $0 },
            publishStatus: { statusMessages.append($0) },
            prepareForFinalization: { _, _ in
                prepareCount += 1
                activeStream = nil
            },
            presentVideoResult: { result, _ in terminalResult = result },
            cleanupTerminal: { acknowledge in
                terminalCleanupCount += 1
                pendingStatusDismissal = acknowledge
            }
        )

        func requestProductionStop() {
            let disposition = entry.stop(
                expectedSession: nil,
                activeStream: activeStream,
                resolveResources: { _ in resources },
                actions: actions
            )
            if disposition == .fallback { fallbackCount += 1 }
        }

        XCTAssertTrue(store.install(session))
        let heartbeat = expectation(description: "main run-loop heartbeat before writer completion")
        DispatchQueue.main.async { heartbeat.fulfill() }

        requestProductionStop()
        requestProductionStop()

        wait(for: [heartbeat], timeout: 2)
        XCTAssertTrue(finalizing)
        XCTAssertEqual(statusMessages, ["Finishing..."])
        XCTAssertEqual(writer.finishCallCount, 1)
        XCTAssertEqual(fallbackCount, 0)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(terminalCleanupCount, 0)
        XCTAssertEqual(job.lifecycle, .postprocessing)
        XCTAssertFalse(store.reserve(replacementID), "Replacement must remain refused while A finishes.")

        writer.complete(.success(()))
        requestProductionStop()

        XCTAssertFalse(finalizing)
        XCTAssertEqual(writer.finishCallCount, 1)
        XCTAssertEqual(fallbackCount, 0)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(terminalCleanupCount, 1)
        XCTAssertNotNil(pendingStatusDismissal)
        XCTAssertEqual(try terminalResult?.get(), job.finalURL)
        XCTAssertEqual(try Data(contentsOf: job.finalURL), Data("recording-a".utf8))
        let replacementReservedBeforeDismissal = store.reserve(replacementID)
        if replacementReservedBeforeDismissal {
            store.cancelReservation(replacementID)
        }
        XCTAssertFalse(
            replacementReservedBeforeDismissal,
            "Replacement must remain refused until the visible finishing control is dismissed."
        )
        pendingStatusDismissal?()
        XCTAssertTrue(
            store.reserve(replacementID),
            "Replacement may start after the finishing control dismissal is acknowledged."
        )
        store.cancelReservation(replacementID)
    }

    func testFastTerminalCompletionSuppressesStaleStopUntilStatusDismissal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-stop-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try RecordingOutputJob.reserve(
            in: directory,
            preferredStem: "fast-recording",
            layout: .single(fileExtension: "mov")
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: job.inputURL.path,
            contents: Data("fast recording".utf8)
        ))
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let writer = ImmediateCaptureWriterFinalizer(result: .success(()))
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination(),
            outputJob: job,
            writerFinalizer: writer
        )
        let entry = CaptureProductionStopEntry(store: store)
        let resources = CaptureProductionStopResources(
            outputJob: job,
            writerFinalizer: writer,
            isAudioOnly: false,
            markVideoInputFinished: {}
        )
        var prepareCount = 0
        var cleanupCount = 0
        var pendingStatusDismissal: (() -> Void)?
        let actions = CaptureProductionStopActions(
            stopActiveStream: { _ in false },
            prepareForFinalization: { _, _ in prepareCount += 1 },
            cleanupTerminal: { acknowledge in
                cleanupCount += 1
                pendingStatusDismissal = acknowledge
            }
        )

        XCTAssertTrue(store.install(session))
        XCTAssertTrue(store.deactivate(session))
        XCTAssertEqual(
            entry.stop(
                expectedSession: session,
                activeStream: nil,
                resolveResources: { _ in resources },
                actions: actions
            ),
            .handled
        )
        XCTAssertEqual(job.lifecycle, .terminal)
        XCTAssertEqual(writer.finishCallCount, 1)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(
            entry.stop(
                expectedSession: nil,
                activeStream: nil,
                resolveResources: { _ in resources },
                actions: actions
            ),
            .handled
        )
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(writer.finishCallCount, 1)

        pendingStatusDismissal?()
        var legacyFallbackCount = 0
        let fallbackDisposition = entry.stop(
            expectedSession: nil,
            activeStream: nil,
            resolveResources: { _ in
                CaptureProductionStopResources(
                    outputJob: nil,
                    writerFinalizer: nil,
                    isAudioOnly: false
                )
            },
            actions: CaptureProductionStopActions(
                stopActiveStream: { _ in false },
                prepareForFinalization: { _, _ in legacyFallbackCount += 1 }
            )
        )
        XCTAssertEqual(fallbackDisposition, .fallback)
        XCTAssertEqual(legacyFallbackCount, 1)
    }

    func testProductionFastFinalizationPublishesFinishingBeforeWriterCanComplete() throws {
        let statusSource = try projectSource("QuickRecorder/ViewModel/StatusBar.swift")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-finalization-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let job = try RecordingOutputJob.reserve(
            in: directory,
            preferredStem: "fast-finalization",
            layout: .single(fileExtension: "mov")
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: job.inputURL.path,
            contents: Data("fast finalization".utf8)
        ))
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let writer = DelayedCaptureWriterFinalizer()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination(),
            outputJob: job,
            writerFinalizer: writer
        )
        let resources = CaptureProductionStopResources(
            outputJob: job,
            writerFinalizer: writer,
            isAudioOnly: false,
            markVideoInputFinished: {}
        )
        let statusDismissed = expectation(description: "terminal status dismissal")
        var isFinalizing = false
        var renderedStatusWidth: CGFloat?
        let actions = CaptureProductionStopActions(
            stopActiveStream: { _ in false },
            setFinalizing: { isFinalizing = $0 },
            publishStatus: { status in
                XCTAssertEqual(status, "Finishing...")
                CaptureStatusBarUpdateScheduler.schedule(isFinalizing: isFinalizing) {
                    renderedStatusWidth = isFinalizing ? 112 : nil
                }
            },
            cleanupTerminal: { acknowledge in
                CaptureStatusBarUpdateScheduler.schedule(isFinalizing: isFinalizing) {
                    renderedStatusWidth = nil
                    acknowledge()
                    statusDismissed.fulfill()
                }
            }
        )
        let entry = CaptureProductionStopEntry(store: store)
        let replacementID = UUID()

        XCTAssertTrue(statusSource.contains("CaptureStatusBarUpdateScheduler.schedule("))
        XCTAssertTrue(statusSource.contains("isFinalizing: SCContext.isFinalizing"))
        XCTAssertTrue(statusSource.contains("completion: { completion?() }"))

        XCTAssertTrue(store.install(session))
        XCTAssertTrue(store.deactivate(session))
        XCTAssertEqual(
            entry.stop(
                expectedSession: session,
                activeStream: nil,
                resolveResources: { _ in resources },
                actions: actions
            ),
            .handled
        )

        XCTAssertEqual(renderedStatusWidth, 112)
        XCTAssertFalse(store.reserve(replacementID), "Start must remain refused while the writer owns A.")

        writer.complete(.success(()))

        XCTAssertEqual(renderedStatusWidth, 112)
        XCTAssertFalse(
            store.reserve(replacementID),
            "Start must remain refused while the finishing control is visible."
        )
        wait(for: [statusDismissed], timeout: 1)
        XCTAssertNil(renderedStatusWidth)
        XCTAssertTrue(store.reserve(replacementID), "Start may succeed after status dismissal.")
        store.cancelReservation(replacementID)
    }

    func testFinalizationSupersedesOlderQueuedStatusUpdateWithoutAdvancingTerminalDismissal() {
        XCTAssertTrue(Thread.isMainThread)
        let olderUpdate = expectation(description: "older status update stays superseded")
        olderUpdate.isInverted = true
        let terminalDismissal = expectation(description: "terminal dismissal")
        var events = [String]()
        var terminalRenderCount = 0
        var terminalDismissalCount = 0

        CaptureStatusBarUpdateScheduler.schedule(isFinalizing: false) {
            events.append("older")
            olderUpdate.fulfill()
        }
        CaptureStatusBarUpdateScheduler.schedule(isFinalizing: true) {
            events.append("finishing")
        }
        let finalizationPublishedAt = ProcessInfo.processInfo.systemUptime
        CaptureStatusBarUpdateScheduler.schedule(
            isFinalizing: false,
            completion: {
                terminalDismissalCount += 1
                XCTAssertGreaterThanOrEqual(
                    ProcessInfo.processInfo.systemUptime - finalizationPublishedAt,
                    0.18
                )
                terminalDismissal.fulfill()
            }
        ) {
            terminalRenderCount += 1
            events.append("terminal")
        }

        XCTAssertEqual(events, ["finishing"])
        wait(for: [terminalDismissal, olderUpdate], timeout: 0.5)
        XCTAssertEqual(events, ["finishing", "terminal"])
        XCTAssertEqual(terminalRenderCount, 1)
        XCTAssertEqual(terminalDismissalCount, 1)
    }

    func testSupersededTerminalRenderStillAcknowledgesItsStaleStopExactlyOnce() {
        XCTAssertTrue(Thread.isMainThread)
        let store = CaptureOutputSessionStore()
        let entry = CaptureProductionStopEntry(store: store)
        let sessionA = makeCaptureSession(
            stream: NSObject(),
            mode: .transparent,
            sink: TestVideoDestination()
        )
        let sessionB = makeCaptureSession(
            stream: NSObject(),
            mode: .transparent,
            sink: TestVideoDestination()
        )
        let staleAcknowledgement = expectation(description: "stale Stop acknowledgement")
        var supersededRenderCount = 0
        var staleAcknowledgementCount = 0

        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(store.deactivate(sessionA))
        XCTAssertTrue(store.beginFinalization(sessionA))
        XCTAssertTrue(store.release(sessionA))
        XCTAssertTrue(store.hasPendingStopControlDismissal)

        CaptureStatusBarUpdateScheduler.schedule(
            isFinalizing: false,
            completion: {
                staleAcknowledgementCount += 1
                store.acknowledgeStopControlDismissal()
                staleAcknowledgement.fulfill()
            }
        ) {
            supersededRenderCount += 1
        }

        XCTAssertTrue(store.install(sessionB))
        XCTAssertTrue(store.deactivate(sessionB))
        XCTAssertTrue(store.beginFinalization(sessionB))
        XCTAssertTrue(store.release(sessionB))
        CaptureStatusBarUpdateScheduler.schedule(isFinalizing: true) {}

        wait(for: [staleAcknowledgement], timeout: 1)
        XCTAssertEqual(supersededRenderCount, 0)
        XCTAssertEqual(staleAcknowledgementCount, 1)
        XCTAssertTrue(store.hasPendingStopControlDismissal, "B still owns its Stop dismissal.")

        var laterStopFallbackCount = 0
        let resources = CaptureProductionStopResources(
            outputJob: nil,
            writerFinalizer: nil,
            isAudioOnly: false
        )
        let actions = CaptureProductionStopActions(
            stopActiveStream: { _ in false },
            prepareForFinalization: { _, _ in laterStopFallbackCount += 1 }
        )
        XCTAssertEqual(
            entry.stop(
                expectedSession: nil,
                activeStream: nil,
                resolveResources: { _ in resources },
                actions: actions
            ),
            .handled
        )
        XCTAssertEqual(laterStopFallbackCount, 0)

        store.acknowledgeStopControlDismissal()
        XCTAssertFalse(store.hasPendingStopControlDismissal)
        XCTAssertEqual(
            entry.stop(
                expectedSession: nil,
                activeStream: nil,
                resolveResources: { _ in resources },
                actions: actions
            ),
            .fallback
        )
        XCTAssertEqual(laterStopFallbackCount, 1)
    }

    func testStaleStopControlCannotStopReplacementBeforeDismissalAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-stop-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        func makeJob(_ stem: String) throws -> RecordingOutputJob {
            let job = try RecordingOutputJob.reserve(
                in: directory,
                preferredStem: stem,
                layout: .single(fileExtension: "mov")
            )
            XCTAssertTrue(FileManager.default.createFile(
                atPath: job.inputURL.path,
                contents: Data(stem.utf8)
            ))
            return job
        }

        let store = CaptureOutputSessionStore()
        let entry = CaptureProductionStopEntry(store: store)
        let streamA = NSObject()
        let writerA = ImmediateCaptureWriterFinalizer(result: .success(()))
        let jobA = try makeJob("recording-a")
        let sessionA = makeCaptureSession(
            stream: streamA,
            mode: .transparent,
            sink: TestVideoDestination(),
            outputJob: jobA,
            writerFinalizer: writerA
        )
        let resourcesA = CaptureProductionStopResources(
            outputJob: jobA,
            writerFinalizer: writerA,
            isAudioOnly: false,
            markVideoInputFinished: {}
        )
        var acknowledgeDismissalA: (() -> Void)?
        let actionsA = CaptureProductionStopActions(
            stopActiveStream: { _ in false },
            cleanupTerminal: { acknowledgeDismissalA = $0 }
        )

        XCTAssertTrue(store.reserve(sessionA.id))
        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(store.deactivate(sessionA))
        XCTAssertEqual(
            entry.stop(
                expectedSession: sessionA,
                activeStream: nil,
                resolveResources: { _ in resourcesA },
                actions: actionsA
            ),
            .handled
        )
        XCTAssertEqual(jobA.lifecycle, .terminal)
        XCTAssertNotNil(acknowledgeDismissalA)

        let streamB = NSObject()
        let writerB = ImmediateCaptureWriterFinalizer(result: .success(()))
        let jobB = try makeJob("recording-b")
        let sessionB = makeCaptureSession(
            stream: streamB,
            mode: .transparent,
            sink: TestVideoDestination(),
            outputJob: jobB,
            writerFinalizer: writerB
        )
        let resourcesB = CaptureProductionStopResources(
            outputJob: jobB,
            writerFinalizer: writerB,
            isAudioOnly: false,
            markVideoInputFinished: {}
        )
        var replacementStopOfferCount = 0
        var replacementFinalizationCount = 0
        var replacementPrepareCount = 0
        var replacementCleanupCount = 0
        var replacementActions: CaptureProductionStopActions!
        let replacementCore = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("Replacement B must not fail.") },
            stopHandler: { stoppedSession in
                replacementFinalizationCount += 1
                XCTAssertTrue(stoppedSession === sessionB)
                XCTAssertEqual(
                    entry.stop(
                        expectedSession: stoppedSession,
                        activeStream: nil,
                        resolveResources: { _ in resourcesB },
                        actions: replacementActions
                    ),
                    .handled
                )
            }
        )
        let replacementAdapter = CaptureStreamCallbackAdapter(core: replacementCore)
        replacementActions = CaptureProductionStopActions(
            stopActiveStream: { activeStream in
                replacementStopOfferCount += 1
                return replacementAdapter.handleStop(from: activeStream)
            },
            prepareForFinalization: { session, _ in
                replacementPrepareCount += 1
                XCTAssertTrue(session === sessionB)
            },
            cleanupTerminal: { acknowledge in
                replacementCleanupCount += 1
                acknowledge()
            }
        )

        XCTAssertFalse(store.reserve(sessionB.id))
        XCTAssertEqual(
            entry.stop(
                expectedSession: nil,
                activeStream: streamB,
                resolveResources: { _ in resourcesB },
                actions: replacementActions
            ),
            .handled
        )
        XCTAssertNil(store.activeSession())
        XCTAssertEqual(replacementStopOfferCount, 0)
        XCTAssertEqual(replacementFinalizationCount, 0)
        XCTAssertEqual(replacementPrepareCount, 0)
        XCTAssertEqual(replacementCleanupCount, 0)
        XCTAssertEqual(writerB.finishCallCount, 0)
        XCTAssertEqual(jobB.lifecycle, .recording)
        acknowledgeDismissalA?()
        XCTAssertTrue(store.reserve(sessionB.id))
        XCTAssertTrue(store.install(sessionB))
        XCTAssertEqual(
            entry.stop(
                expectedSession: nil,
                activeStream: streamB,
                resolveResources: { _ in resourcesB },
                actions: replacementActions
            ),
            .handled
        )
        XCTAssertEqual(replacementStopOfferCount, 1)
        XCTAssertEqual(replacementFinalizationCount, 1)
        XCTAssertEqual(replacementPrepareCount, 1)
        XCTAssertEqual(replacementCleanupCount, 1)
        XCTAssertEqual(writerB.finishCallCount, 1)
        XCTAssertEqual(jobB.lifecycle, .terminal)
        XCTAssertNil(store.activeSession())
    }

    func testApplicationTerminationStopsReplacementAfterEarlierStopDismissal() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termination-stale-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        func makeJob(_ stem: String) throws -> RecordingOutputJob {
            let job = try RecordingOutputJob.reserve(
                in: directory,
                preferredStem: stem,
                layout: .single(fileExtension: "mov")
            )
            XCTAssertTrue(FileManager.default.createFile(
                atPath: job.inputURL.path,
                contents: Data(stem.utf8)
            ))
            return job
        }

        let store = CaptureOutputSessionStore()
        let entry = CaptureProductionStopEntry(store: store)
        let jobA = try makeJob("finished-a")
        let sessionA = makeCaptureSession(
            stream: NSObject(),
            mode: .transparent,
            sink: TestVideoDestination(),
            outputJob: jobA,
            writerFinalizer: ImmediateCaptureWriterFinalizer(result: .success(()))
        )
        let resourcesA = CaptureProductionStopResources(
            outputJob: jobA,
            writerFinalizer: sessionA.writerFinalizer,
            isAudioOnly: false,
            markVideoInputFinished: {}
        )
        var acknowledgeDismissalA: (() -> Void)?

        XCTAssertTrue(store.reserve(sessionA.id))
        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(store.deactivate(sessionA))
        XCTAssertEqual(
            entry.stop(
                expectedSession: sessionA,
                activeStream: nil,
                resolveResources: { _ in resourcesA },
                actions: CaptureProductionStopActions(
                    stopActiveStream: { _ in false },
                    cleanupTerminal: { acknowledgeDismissalA = $0 }
                )
            ),
            .handled
        )
        XCTAssertEqual(jobA.lifecycle, .terminal)
        XCTAssertNotNil(acknowledgeDismissalA)
        XCTAssertTrue(store.hasPendingStopControlDismissal)
        acknowledgeDismissalA?()
        XCTAssertFalse(store.hasPendingStopControlDismissal)

        let streamB = NSObject()
        let writerB = DelayedCaptureWriterFinalizer()
        let jobB = try makeJob("replacement-b")
        let sessionB = makeCaptureSession(
            stream: streamB,
            mode: .transparent,
            sink: TestVideoDestination(),
            outputJob: jobB,
            writerFinalizer: writerB
        )
        let resourcesB = CaptureProductionStopResources(
            outputJob: jobB,
            writerFinalizer: writerB,
            isAudioOnly: false,
            markVideoInputFinished: {}
        )
        var stopOfferCount = 0
        var finalizationCount = 0
        var prepareCount = 0
        var cleanupCount = 0
        var actionsB: CaptureProductionStopActions!
        let coreB = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("Application termination must stop B normally.") },
            stopHandler: { stoppedSession in
                finalizationCount += 1
                XCTAssertTrue(stoppedSession === sessionB)
                XCTAssertEqual(
                    entry.stop(
                        expectedSession: stoppedSession,
                        activeStream: nil,
                        resolveResources: { _ in resourcesB },
                        actions: actionsB
                    ),
                    .handled
                )
            }
        )
        let adapterB = CaptureStreamCallbackAdapter(core: coreB)
        actionsB = CaptureProductionStopActions(
            stopActiveStream: { stream in
                stopOfferCount += 1
                return adapterB.handleStop(from: stream)
            },
            prepareForFinalization: { stoppedSession, _ in
                prepareCount += 1
                XCTAssertTrue(stoppedSession === sessionB)
            },
            cleanupTerminal: { acknowledge in
                cleanupCount += 1
                acknowledge()
            }
        )

        XCTAssertTrue(store.reserve(sessionB.id))
        XCTAssertTrue(store.install(sessionB))
        let termination = CaptureApplicationTerminationCoordinator(
            store: store,
            scheduleReply: { $0() }
        )
        var terminationStopCount = 0
        var replyCount = 0

        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: {
                terminationStopCount += 1
                XCTAssertEqual(
                    entry.stop(
                        expectedSession: nil,
                        origin: .applicationTermination,
                        activeStream: streamB,
                        resolveResources: { _ in resourcesB },
                        actions: actionsB
                    ),
                    .handled
                )
            },
            replyWhenFinished: { replyCount += 1 }
        ))
        XCTAssertNil(store.activeSession(), "Quit must retire replacement B.")
        XCTAssertEqual(terminationStopCount, 1)
        XCTAssertEqual(stopOfferCount, 1)
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(writerB.finishCallCount, 1)
        XCTAssertEqual(jobB.lifecycle, .postprocessing)
        XCTAssertEqual(replyCount, 0)

        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: { terminationStopCount += 1 },
            replyWhenFinished: { replyCount += 1 }
        ))
        XCTAssertEqual(terminationStopCount, 1)
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(replyCount, 0)

        writerB.complete(.success(()))
        XCTAssertEqual(jobB.lifecycle, .terminal)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(replyCount, 1)

        XCTAssertFalse(termination.prepareForTermination(
            stopActiveCapture: { terminationStopCount += 1 },
            replyWhenFinished: { replyCount += 1 }
        ))
        XCTAssertEqual(terminationStopCount, 1)
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(replyCount, 1)
        XCTAssertTrue(
            appSource.contains("SCContext.stopRecording(origin: .applicationTermination)"),
            "The application delegate must bind Quit to the authoritative production Stop origin."
        )
        let stopRecordingStart = try XCTUnwrap(
            contextSource.range(of: "    static func stopRecording(")
        )
        let stopRecordingEnd = try XCTUnwrap(
            contextSource.range(
                of: "    private static func finishCompletedAudioPackage(",
                range: stopRecordingStart.upperBound..<contextSource.endIndex
            )
        )
        let stopRecordingSource = contextSource[
            stopRecordingStart.lowerBound..<stopRecordingEnd.lowerBound
        ]
        XCTAssertTrue(
            stopRecordingSource.contains(
                "expectedSession: expectedSession,\n            origin: origin,\n            activeStream: stream,"
            ),
            "SCContext must forward Quit's authoritative origin into the production Stop entry."
        )
    }

    func testEachStatusDismissalMustCompleteBeforeTheNextReservation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlapping-stop-dismissals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CaptureOutputSessionStore()
        let entry = CaptureProductionStopEntry(store: store)
        var pendingStatusDismissals = [() -> Void]()

        func finishImmediately(_ stem: String) throws {
            let job = try RecordingOutputJob.reserve(
                in: directory,
                preferredStem: stem,
                layout: .single(fileExtension: "mov")
            )
            XCTAssertTrue(FileManager.default.createFile(
                atPath: job.inputURL.path,
                contents: Data(stem.utf8)
            ))
            let stream = NSObject()
            let writer = ImmediateCaptureWriterFinalizer(result: .success(()))
            let session = makeCaptureSession(
                stream: stream,
                mode: .transparent,
                sink: TestVideoDestination(),
                outputJob: job,
                writerFinalizer: writer
            )
            let resources = CaptureProductionStopResources(
                outputJob: job,
                writerFinalizer: writer,
                isAudioOnly: false,
                markVideoInputFinished: {}
            )
            let actions = CaptureProductionStopActions(
                stopActiveStream: { _ in false },
                cleanupTerminal: { pendingStatusDismissals.append($0) }
            )

            XCTAssertTrue(store.reserve(session.id))
            XCTAssertTrue(store.install(session))
            XCTAssertTrue(store.deactivate(session))
            XCTAssertEqual(
                entry.stop(
                    expectedSession: session,
                    activeStream: nil,
                    resolveResources: { _ in resources },
                    actions: actions
                ),
                .handled
            )
            XCTAssertEqual(job.lifecycle, .terminal)
        }

        try finishImmediately("recording-a")
        XCTAssertEqual(pendingStatusDismissals.count, 1)
        XCTAssertFalse(store.reserve(UUID()))
        pendingStatusDismissals[0]()
        try finishImmediately("recording-b")
        XCTAssertEqual(pendingStatusDismissals.count, 2)

        var fallbackCount = 0
        XCTAssertEqual(
            entry.stop(
                expectedSession: nil,
                activeStream: nil,
                resolveResources: { _ in
                    CaptureProductionStopResources(
                        outputJob: nil,
                        writerFinalizer: nil,
                        isAudioOnly: false
                    )
                },
                actions: CaptureProductionStopActions(
                    stopActiveStream: { _ in false },
                    prepareForFinalization: { _, _ in fallbackCount += 1 }
                )
            ),
            .handled
        )
        XCTAssertEqual(fallbackCount, 0)

        pendingStatusDismissals[1]()
        XCTAssertEqual(
            entry.stop(
                expectedSession: nil,
                activeStream: nil,
                resolveResources: { _ in
                    CaptureProductionStopResources(
                        outputJob: nil,
                        writerFinalizer: nil,
                        isAudioOnly: false
                    )
                },
                actions: CaptureProductionStopActions(
                    stopActiveStream: { _ in false },
                    prepareForFinalization: { _, _ in fallbackCount += 1 }
                )
            ),
            .fallback
        )
        XCTAssertEqual(fallbackCount, 1)
    }

    func testProductionStopEntryPreservesIdleLegacyFallback() {
        let store = CaptureOutputSessionStore()
        let entry = CaptureProductionStopEntry(store: store)
        var finalizationCount = 0

        XCTAssertEqual(
            entry.stop(
                expectedSession: nil,
                activeStream: nil,
                resolveResources: { _ in
                    CaptureProductionStopResources(
                        outputJob: nil,
                        writerFinalizer: nil,
                        isAudioOnly: false
                    )
                },
                actions: CaptureProductionStopActions(
                    stopActiveStream: { _ in false },
                    prepareForFinalization: { _, _ in finalizationCount += 1 }
                )
            ),
            .fallback
        )
        XCTAssertEqual(finalizationCount, 1)
    }


    func testPostStartActivationRejectsDelayedStopWithoutRearmingResources() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let startRange = try XCTUnwrap(engineSource.range(of: "try await stream.startCapture()"))
        let activationRange = try XCTUnwrap(
            engineSource.range(of: "CapturePostStartResourceActivation(store: captureOutputSessions).activate")
        )
        let catchRange = try XCTUnwrap(
            engineSource.range(of: "} catch {", range: activationRange.upperBound..<engineSource.endIndex)
        )
        XCTAssertLessThan(startRange.lowerBound, activationRange.lowerBound)
        XCTAssertLessThan(activationRange.lowerBound, catchRange.lowerBound)
        XCTAssertEqual(engineSource.components(separatedBy: "registerGlobalMouseMonitor()").count - 1, 1)
        XCTAssertEqual(
            engineSource.components(separatedBy: "SleepPreventer.shared.preventSleep").count - 1,
            1
        )

        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination()
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("Delayed Stop must not fail.") },
            stopHandler: { store.release($0) }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)
        let activation = CapturePostStartResourceActivation(store: store)
        var mouseMonitorRegistrations = 0
        var sleepAssertions = 0

        XCTAssertTrue(store.install(session))
        XCTAssertTrue(adapter.handleStop(from: stream))
        XCTAssertFalse(activation.activate(
            session: session,
            stream: stream,
            registerMouseMonitor: { mouseMonitorRegistrations += 1 },
            acquireSleepAssertion: {
                sleepAssertions += 1
                return true
            }
        ))
        XCTAssertEqual(mouseMonitorRegistrations, 0)
        XCTAssertEqual(sleepAssertions, 0)
    }

    func testPostStartActivationArmsResourcesOnlyForTheExactActiveOwner() {
        let stream = NSObject()
        let wrongStream = NSObject()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination()
        )
        let activation = CapturePostStartResourceActivation(store: store)
        var mouseMonitorRegistrations = 0
        var sleepAssertions = 0

        XCTAssertTrue(store.install(session))
        XCTAssertFalse(activation.activate(
            session: session,
            stream: wrongStream,
            registerMouseMonitor: { mouseMonitorRegistrations += 1 },
            acquireSleepAssertion: {
                sleepAssertions += 1
                return true
            }
        ))
        XCTAssertTrue(activation.activate(
            session: session,
            stream: stream,
            registerMouseMonitor: { mouseMonitorRegistrations += 1 },
            acquireSleepAssertion: {
                sleepAssertions += 1
                return true
            }
        ))
        XCTAssertEqual(mouseMonitorRegistrations, 1)
        XCTAssertEqual(sleepAssertions, 1)
        XCTAssertTrue(store.deactivate(session))
        XCTAssertTrue(store.release(session))
    }

    func testOwnedSleepAssertionReleasesAfterStopEvenWhenPreferenceTurnsOff() {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination()
        )
        let activation = CapturePostStartResourceActivation(store: store)
        var preventSleepPreference = true
        var acquisitionCount = 0
        var releaseCount = 0

        XCTAssertTrue(store.install(session))
        XCTAssertTrue(activation.activate(
            session: session,
            stream: stream,
            registerMouseMonitor: {},
            acquireSleepAssertion: {
                guard preventSleepPreference else { return false }
                acquisitionCount += 1
                return true
            }
        ))
        preventSleepPreference = false
        XCTAssertTrue(store.deactivate(session))

        let entry = CaptureProductionStopEntry(store: store)
        let actions = CaptureProductionStopActions(
            stopActiveStream: { _ in false },
            releaseSleepAssertion: { releaseCount += 1 }
        )
        XCTAssertEqual(
            entry.stop(
                expectedSession: session,
                activeStream: nil,
                resolveResources: { _ in
                    CaptureProductionStopResources(
                        outputJob: nil,
                        writerFinalizer: nil,
                        isAudioOnly: false
                    )
                },
                actions: actions
            ),
            .handled
        )
        XCTAssertEqual(
            entry.stop(
                expectedSession: session,
                activeStream: nil,
                resolveResources: { _ in
                    CaptureProductionStopResources(
                        outputJob: nil,
                        writerFinalizer: nil,
                        isAudioOnly: false
                    )
                },
                actions: actions
            ),
            .handled
        )
        XCTAssertEqual(acquisitionCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testPostStartActivationRejectsDelayedQuitAndRepliesExactlyOnce() {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination()
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("Delayed Quit must not fail.") },
            stopHandler: { _ in }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)
        let termination = CaptureApplicationTerminationCoordinator(
            store: store,
            scheduleReply: { $0() }
        )
        let activation = CapturePostStartResourceActivation(store: store)
        var stopCount = 0
        var replyCount = 0
        var mouseMonitorRegistrations = 0
        var sleepAssertions = 0

        XCTAssertTrue(store.install(session))
        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: {
                stopCount += 1
                XCTAssertTrue(adapter.handleStop(from: stream))
            },
            replyWhenFinished: { replyCount += 1 }
        ))
        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: { stopCount += 1 },
            replyWhenFinished: { replyCount += 1 }
        ))
        XCTAssertFalse(activation.activate(
            session: session,
            stream: stream,
            registerMouseMonitor: { mouseMonitorRegistrations += 1 },
            acquireSleepAssertion: {
                sleepAssertions += 1
                return true
            }
        ))
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(replyCount, 0)
        XCTAssertEqual(mouseMonitorRegistrations, 0)
        XCTAssertEqual(sleepAssertions, 0)

        XCTAssertTrue(store.release(session))
        XCTAssertEqual(replyCount, 1)
        XCTAssertFalse(store.release(session))
        XCTAssertEqual(replyCount, 1)
    }

    func testDelayedFinalizationKeepsMainHeartbeatAndSessionReservedUntilCompletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delayed-session-finalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let job = try RecordingOutputJob.reserve(
            in: directory,
            preferredStem: "recording-a",
            layout: .single(fileExtension: "mov")
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: job.inputURL.path,
            contents: Data("recording-a".utf8)
        ))
        let streamA = NSObject()
        let store = CaptureOutputSessionStore()
        let delayedWriter = DelayedCaptureWriterFinalizer()
        let sessionA = makeCaptureSession(
            stream: streamA,
            mode: .transparent,
            sink: TestVideoDestination(),
            outputJob: job,
            writerFinalizer: delayedWriter
        )
        let sessionB = UUID()
        let stopPipeline = CaptureSessionStopPipeline(store: store)
        let stopReturned = expectation(description: "Stop returned to the main run loop")
        let heartbeat = expectation(description: "main run-loop heartbeat")

        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(store.deactivate(sessionA))
        DispatchQueue.main.async {
            XCTAssertTrue(Thread.isMainThread)
            stopPipeline.stop(
                sessionA,
                finalization: { finishSession in
                    XCTAssertTrue(job.beginPostprocessing())
                    sessionA.writerFinalizer?.finish { result in
                        _ = job.finishExport(result)
                        finishSession()
                    }
                }
            )
            stopReturned.fulfill()
            DispatchQueue.main.async { heartbeat.fulfill() }
        }

        wait(for: [stopReturned, heartbeat], timeout: 2)
        XCTAssertEqual(job.lifecycle, .postprocessing)
        let reservedEarly = store.reserve(sessionB)
        if reservedEarly { store.cancelReservation(sessionB) }
        XCTAssertFalse(
            reservedEarly,
            "B must be visibly refused while A's delayed writer is still pending."
        )

        delayedWriter.complete(.success(()))
        XCTAssertEqual(job.lifecycle, .terminal)
        XCTAssertEqual(try Data(contentsOf: job.finalURL), Data("recording-a".utf8))
        XCTAssertFalse(store.reserve(sessionB), "B remains refused before Stop-control dismissal.")
        store.acknowledgeStopControlDismissal()
        XCTAssertTrue(store.reserve(sessionB), "B may reserve after A's Stop control is dismissed.")
        store.cancelReservation(sessionB)
    }

    func testAutomaticPackageExportRetainsSessionUntilRequiredExportIsTerminal() throws {
        let outcomes: [Result<Void, RecordingExportError>] = [
            .success(()),
            .failure(.failed(stage: .first, message: "automatic export failed")),
            .failure(.cancelled(stage: .conversion)),
        ]

        for (index, outcome) in outcomes.enumerated() {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("automatic-package-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let packageJob = try RecordingOutputJob.reserve(
                in: directory,
                preferredStem: "package-\(index)",
                layout: .package(
                    fileExtension: "qma",
                    requiredMembers: ["info.json", "sys.m4a", "mic.m4a"],
                    automaticallyExports: true
                )
            )
            for (name, contents) in [
                ("info.json", "{}"),
                ("sys.m4a", "system audio"),
                ("mic.m4a", "microphone audio"),
            ] {
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: packageJob.inputURL.appendingPathComponent(name).path,
                    contents: Data(contents.utf8)
                ))
            }
            let exportJob = try RecordingOutputJob.reserve(
                in: directory,
                preferredStem: "automatic-export-\(index)",
                layout: .single(fileExtension: "m4a")
            )
            let stream = NSObject()
            let store = CaptureOutputSessionStore()
            let writer = DelayedCaptureWriterFinalizer()
            let session = makeCaptureSession(
                stream: stream,
                mode: .transparent,
                sink: TestVideoDestination(),
                outputJob: packageJob,
                isAudioOnly: true,
                writerFinalizer: writer
            )
            let entry = CaptureProductionStopEntry(store: store)
            var automaticExportCompletion: (() -> Void)?
            var terminalScheduleCount = 0
            var terminalCleanupCount = 0
            var terminationReplyCount = 0
            let actions = CaptureProductionStopActions(
                stopActiveStream: { _ in false },
                scheduleTerminal: { action in
                    terminalScheduleCount += 1
                    action()
                },
                finishAudioPackage: { _, automaticallyExports, _, completion in
                    XCTAssertTrue(automaticallyExports)
                    automaticExportCompletion = completion
                },
                cleanupTerminal: { acknowledge in
                    terminalCleanupCount += 1
                    acknowledge()
                }
            )

            XCTAssertTrue(store.install(session))
            XCTAssertTrue(store.deactivate(session))
            XCTAssertEqual(
                entry.stop(
                    expectedSession: session,
                    activeStream: nil,
                    resolveResources: { _ in
                        CaptureProductionStopResources(
                            outputJob: packageJob,
                            writerFinalizer: writer,
                            isAudioOnly: true
                        )
                    },
                    actions: actions
                ),
                .handled
            )
            writer.complete(.success(()))

            XCTAssertEqual(packageJob.lifecycle, .terminal)
            XCTAssertNotNil(automaticExportCompletion)
            XCTAssertEqual(terminalScheduleCount, 1)
            XCTAssertEqual(exportJob.lifecycle, .recording)
            XCTAssertEqual(terminalCleanupCount, 0)
            XCTAssertFalse(store.reserve(UUID()), "Capture ownership must include pending automatic export.")

            let termination = CaptureApplicationTerminationCoordinator(
                store: store,
                scheduleReply: { $0() }
            )
            XCTAssertTrue(termination.prepareForTermination(
                stopActiveCapture: { XCTFail("The capture is already retired into postprocessing.") },
                replyWhenFinished: { terminationReplyCount += 1 }
            ))
            XCTAssertEqual(terminationReplyCount, 0)

            switch outcome {
            case .success:
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: exportJob.inputURL.path,
                    contents: Data("automatic export".utf8)
                ))
                _ = exportJob.finishSingleOutput()
            case .failure(let error):
                _ = exportJob.discardOutputs(reason: error)
            }
            automaticExportCompletion?()

            XCTAssertEqual(exportJob.lifecycle, .terminal)
            XCTAssertEqual(terminalScheduleCount, 2)
            XCTAssertEqual(terminalCleanupCount, 1)
            XCTAssertEqual(terminationReplyCount, 1)
        }
    }

    func testApplicationTerminationWaitsForExactJobWithoutRepeatingStopOrReply() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termination-finalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let job = try RecordingOutputJob.reserve(
            in: directory,
            preferredStem: "termination-recording",
            layout: .single(fileExtension: "mov")
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: job.inputURL.path,
            contents: Data("complete before quit".utf8)
        ))
        let store = CaptureOutputSessionStore()
        let writer = DelayedCaptureWriterFinalizer()
        let session = makeCaptureSession(
            stream: NSObject(),
            mode: .transparent,
            sink: TestVideoDestination(),
            outputJob: job,
            writerFinalizer: writer
        )
        let finalizer = CaptureSessionFinalizationCoordinator(store: store)
        let termination = CaptureApplicationTerminationCoordinator(
            store: store,
            scheduleReply: { $0() }
        )
        var stopCount = 0
        var replyCount = 0

        XCTAssertTrue(store.install(session))
        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: {
                stopCount += 1
                XCTAssertTrue(store.deactivate(session))
                XCTAssertTrue(finalizer.finalize(session) { finishSession in
                    XCTAssertTrue(job.beginPostprocessing())
                    session.writerFinalizer?.finish { result in
                        _ = job.finishExport(result)
                        finishSession()
                    }
                })
            },
            replyWhenFinished: { replyCount += 1 }
        ))
        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: { stopCount += 1 },
            replyWhenFinished: { replyCount += 1 }
        ))
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(replyCount, 0)
        XCTAssertEqual(job.lifecycle, .postprocessing)

        writer.complete(.success(()))
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(replyCount, 1)
        XCTAssertEqual(job.lifecycle, .terminal)
        XCTAssertEqual(try Data(contentsOf: job.finalURL), Data("complete before quit".utf8))
        XCTAssertTrue(appSource.contains("applicationShouldTerminate"))
        XCTAssertTrue(appSource.contains(".terminateLater"))
        XCTAssertTrue(appSource.contains("reply(toApplicationShouldTerminate: true)"))

        let idleTermination = CaptureApplicationTerminationCoordinator(
            store: store,
            scheduleReply: { $0() }
        )
        XCTAssertFalse(idleTermination.prepareForTermination(
            stopActiveCapture: { XCTFail("An idle app has nothing to stop.") },
            replyWhenFinished: { XCTFail("An idle app terminates immediately.") }
        ))
    }

    func testQueuedTerminationApprovalCannotBeOvertakenByReplacementReservation() {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination()
        )
        var scheduledReply: (() -> Void)?
        let termination = CaptureApplicationTerminationCoordinator(
            store: store,
            scheduleReply: { scheduledReply = $0 }
        )
        let replacementID = UUID()
        var replyCount = 0
        var replacementWasManagedInsideReply = false

        XCTAssertTrue(store.install(session))
        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: {
                XCTAssertTrue(store.deactivate(session))
                XCTAssertTrue(store.release(session))
            },
            replyWhenFinished: {
                replyCount += 1
                replacementWasManagedInsideReply = store.reserve(replacementID)
                if replacementWasManagedInsideReply { store.cancelReservation(replacementID) }
            }
        ))

        XCTAssertNotNil(scheduledReply)
        XCTAssertFalse(
            store.reserve(replacementID),
            "B cannot reserve after A becomes idle while termination approval is still queued."
        )
        scheduledReply?()
        XCTAssertEqual(replyCount, 1)
        XCTAssertFalse(replacementWasManagedInsideReply)
        XCTAssertTrue(
            store.reserve(replacementID),
            "The latch must clear after the approval callback returns rather than deadlocking legitimate state."
        )
        store.cancelReservation(replacementID)
    }

    func testApplicationTerminationDuringPendingPreparationIsObservedAfterInstallation() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let lifecycleSource = try projectSource("QuickRecorder/WindowCapturePrivacy.swift")
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: NSObject(),
            mode: .transparent,
            sink: TestVideoDestination()
        )
        let termination = CaptureApplicationTerminationCoordinator(
            store: store,
            scheduleReply: { $0() }
        )
        var stopAttemptCount = 0
        var cancelledSessionCount = 0
        var replyCount = 0

        XCTAssertTrue(store.reserve(session.id))
        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: { stopAttemptCount += 1 },
            replyWhenFinished: { replyCount += 1 }
        ))
        XCTAssertEqual(stopAttemptCount, 0, "A pending preparation has no active stream to stop yet.")
        XCTAssertEqual(replyCount, 0)

        XCTAssertTrue(store.install(session))
        XCTAssertTrue(store.consumeTerminationRequest(for: session))
        cancelledSessionCount += 1
        XCTAssertTrue(store.deactivate(session))
        XCTAssertTrue(store.release(session))

        XCTAssertEqual(cancelledSessionCount, 1)
        XCTAssertFalse(store.consumeTerminationRequest(for: session), "Cancellation is one-shot.")
        XCTAssertEqual(replyCount, 1, "Termination must reply after the exact preparation becomes idle.")
        XCTAssertTrue(engineSource.contains("captureOutputSessions.consumeTerminationRequest(for: session)"))
        XCTAssertTrue(engineSource.contains("throw RecordingExportError.cancelled(stage: .first)"))
        XCTAssertTrue(appSource.contains("dispatchPrecondition(condition: .onQueue(.main))"))
        XCTAssertTrue(lifecycleSource.contains("DispatchQueue.main.async(execute: reply)"))
    }

    func testApplicationTerminationDuringPendingCancellationOrFailureRepliesExactlyOnce() {
        for usesFailureCleanup in [false, true] {
            let store = CaptureOutputSessionStore()
            let sessionID = UUID()
            let termination = CaptureApplicationTerminationCoordinator(
                store: store,
                scheduleReply: { $0() }
            )
            var stopCount = 0
            var cleanupCount = 0
            var replyCount = 0

            XCTAssertTrue(store.reserve(sessionID))
            XCTAssertTrue(termination.prepareForTermination(
                stopActiveCapture: { stopCount += 1 },
                replyWhenFinished: { replyCount += 1 }
            ))
            XCTAssertTrue(termination.prepareForTermination(
                stopActiveCapture: { stopCount += 1 },
                replyWhenFinished: { replyCount += 1 }
            ))

            if usesFailureCleanup {
                CapturePreparationFailureCoordinator(store: store).cleanup(sessionID: sessionID) {
                    cleanupCount += 1
                }
            } else {
                store.cancelReservation(sessionID)
            }
            store.cancelReservation(sessionID)

            XCTAssertEqual(stopCount, 0)
            XCTAssertEqual(cleanupCount, usesFailureCleanup ? 1 : 0)
            XCTAssertEqual(replyCount, 1)
            XCTAssertFalse(termination.prepareForTermination(
                stopActiveCapture: { XCTFail("An idle store has no capture to stop.") },
                replyWhenFinished: { XCTFail("Idle termination does not need a deferred reply.") }
            ))
        }
    }

    func testApplicationTerminationBetweenInstallationAndStreamPublicationIsConsumedOnce() {
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: NSObject(),
            mode: .transparent,
            sink: TestVideoDestination()
        )
        let termination = CaptureApplicationTerminationCoordinator(
            store: store,
            scheduleReply: { $0() }
        )
        var stopAttemptCount = 0
        var replyCount = 0

        XCTAssertTrue(store.reserve(session.id))
        XCTAssertTrue(store.install(session))
        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: { stopAttemptCount += 1 },
            replyWhenFinished: { replyCount += 1 }
        ))

        XCTAssertEqual(stopAttemptCount, 1, "The active-session Stop still runs once.")
        XCTAssertTrue(
            store.consumeTerminationRequest(for: session),
            "The exact installed session must retain Quit until its stream is published."
        )
        XCTAssertFalse(store.consumeTerminationRequest(for: session))
        XCTAssertTrue(store.deactivate(session))
        XCTAssertTrue(store.release(session))
        XCTAssertEqual(replyCount, 1)
    }

    func testApplicationTerminationReplyReturnsToMainQueueAfterBackgroundIdleTransition() {
        let store = CaptureOutputSessionStore()
        let sessionID = UUID()
        let termination = CaptureApplicationTerminationCoordinator(store: store)
        let reply = expectation(description: "termination reply on main queue")

        XCTAssertTrue(store.reserve(sessionID))
        XCTAssertTrue(termination.prepareForTermination(
            stopActiveCapture: { XCTFail("Pending preparation has no active capture to stop.") },
            replyWhenFinished: {
                XCTAssertTrue(Thread.isMainThread)
                reply.fulfill()
            }
        ))
        DispatchQueue.global(qos: .userInitiated).async {
            store.cancelReservation(sessionID)
        }

        wait(for: [reply], timeout: 2)
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
        let unchangedB = try inspectExterior(of: currentBBuffer, mode: .transparent, sentinel: sentinels[1])
        XCTAssertGreaterThan(unchangedB.sentinelPixels, 0, "B must copy rather than mutate its source IOSurface")
        let sanitizedBuffer = try XCTUnwrap(sinkB.lastSampleBuffer?.imageBuffer)
        let sanitized = try inspectExterior(of: sanitizedBuffer, mode: .opaque, sentinel: sentinels[1])
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

    func testStopRemainsHandledWhenACompetingFailureRetiresTheSessionAfterLeaseAcquisition() throws {
        let streamA = NSObject()
        let streamB = NSObject()
        let store = CaptureOutputSessionStore()
        let failedSessions = LockedSessionIDs()
        let stoppedSessions = LockedSessionIDs()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())
        let failureFinished = expectation(description: "competing failure finalized A")
        let stopLeaseAcquired = expectation(description: "stop acquired A lease")
        let stopFinished = expectation(description: "stop returned")
        let allowStopTransition = DispatchSemaphore(value: 0)
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { session in
                failedSessions.append(session.id)
                store.release(session)
                failureFinished.fulfill()
            },
            stopHandler: { session in
                stoppedSessions.append(session.id)
                store.release(session)
            }
        )
        let unsupportedBuffer = try makePixelBuffer(pixelFormat: kCVPixelFormatType_32ARGB)
        let unsupportedSample = try makeSampleBuffer(imageBuffer: unsupportedBuffer)
        var stopWasHandled = false

        XCTAssertTrue(store.install(sessionA))
        DispatchQueue(label: "WindowCapturePrivacyTests.stop-transition-race").async {
            stopWasHandled = core.handleStop(from: streamA) {
                stopLeaseAcquired.fulfill()
                _ = allowStopTransition.wait(timeout: .now() + 2)
            }
            stopFinished.fulfill()
        }
        wait(for: [stopLeaseAcquired], timeout: 2)

        XCTAssertEqual(
            core.handleSample(
                from: streamA,
                sampleBuffer: unsupportedSample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .failed
        )
        XCTAssertFalse(store.install(sessionB), "B must remain blocked while A's stop lease drains")

        allowStopTransition.signal()
        wait(for: [stopFinished, failureFinished], timeout: 2)
        XCTAssertTrue(stopWasHandled, "the retired exact stream must never fall through to global finalization")
        XCTAssertEqual(failedSessions.values, [sessionA.id])
        XCTAssertTrue(stoppedSessions.values.isEmpty, "the competing failure owns A's sole finalization")
        XCTAssertTrue(store.install(sessionB))
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

    func testReadyPreviewFrameIsSanitizedAtTheMomentItIsRetained() throws {
        let stream = NSObject()
        let store = CaptureOutputSessionStore()
        var retainedFrameWasSanitized = false
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: TestVideoDestination(),
            firstFrameHandler: { [self] sample in
                guard let imageBuffer = sample.imageBuffer,
                      let result = try? inspectExterior(
                        of: imageBuffer,
                        mode: .transparent,
                        sentinel: sentinels[0]
                      ) else { return }
                retainedFrameWasSanitized = result.sentinelPixels == 0 && result.invalidPixels == 0
            }
        )
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))

        XCTAssertTrue(store.install(session))
        XCTAssertEqual(
            core(for: store).handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended
        )
        XCTAssertTrue(retainedFrameWasSanitized, "preview retention must observe sanitized corners")
        let retainedBuffer = try XCTUnwrap(session.capturedFirstFrame()?.imageBuffer)
        let result = try inspectExterior(
            of: retainedBuffer,
            mode: .transparent,
            sentinel: sentinels[0]
        )
        XCTAssertEqual(result.sentinelPixels, 0)
        XCTAssertEqual(result.invalidPixels, 0)
    }

    func testProductionPresenterGeometryChangeResumesAfterSafeDelay() throws {
        let stream = NSObject()
        let sink = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(stream: stream, mode: .transparent, sink: sink)
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let manualScheduler = ManualActionScheduler()
        let scheduler = CapturePresenterReadyScheduler { delay, action in
            manualScheduler.append(delay: delay, action: action)
        }
        var core: CaptureOutputCore!
        core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("capture should not stop") },
            presenterReadyHandler: { outputSession in
                scheduler.schedule(after: 1) { core.markPresenterReady(outputSession) }
            }
        )

        XCTAssertTrue(store.install(session))
        XCTAssertNotNil(core.handlePresenterStarted(from: stream))
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 0),
                kind: .screen(isComplete: true, presenterOverlayX: 0)
            ),
            .ignored
        )
        XCTAssertEqual(manualScheduler.pendingCount, 1)
        guard manualScheduler.pendingCount == 1 else { return }
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 1),
                kind: .screen(isComplete: true, presenterOverlayX: 0)
            ),
            .ignored
        )
        manualScheduler.runNext()
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 2),
                kind: .screen(isComplete: true, presenterOverlayX: 0)
            ),
            .appended
        )

        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 3),
                kind: .screen(isComplete: true, presenterOverlayX: 1)
            ),
            .ignored
        )
        XCTAssertEqual(manualScheduler.pendingCount, 1)
        guard manualScheduler.pendingCount == 1 else { return }
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 4),
                kind: .screen(isComplete: true, presenterOverlayX: 1)
            ),
            .ignored
        )
        manualScheduler.runNext()
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 5),
                kind: .screen(isComplete: true, presenterOverlayX: 1)
            ),
            .appended
        )

        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 6),
                kind: .screen(isComplete: true, presenterOverlayX: .infinity)
            ),
            .ignored
        )
        XCTAssertEqual(manualScheduler.pendingCount, 1)
        guard manualScheduler.pendingCount == 1 else { return }
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 7),
                kind: .screen(isComplete: true, presenterOverlayX: .infinity)
            ),
            .ignored
        )
        manualScheduler.runNext()
        XCTAssertEqual(
            core.handleSample(
                from: stream,
                sampleBuffer: try presenterSample(index: 8),
                kind: .screen(isComplete: true, presenterOverlayX: .infinity)
            ),
            .appended
        )
        XCTAssertNotNil(core.handlePresenterStopped(from: stream))
        XCTAssertEqual(manualScheduler.delays, [1, 1, 1])
        XCTAssertTrue(appSource.contains("let presenterReadyScheduler = CapturePresenterReadyScheduler()"))
        XCTAssertTrue(engineSource.contains("presenterReadyScheduler.schedule(after: TimeInterval(poSafeDelay))"))
        XCTAssertFalse(session.stateSnapshot().isPresenterOn)
        XCTAssertTrue(session.stateSnapshot().presenterType == "OFF")
        XCTAssertEqual(sink.appendCount, 3)
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

    func testProductionCallbackAdapterForwardsMicrophoneAndStartFailure() throws {
        let stream = NSObject()
        let videoSink = TestVideoDestination()
        let microphoneSink = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: videoSink,
            microphoneInput: microphoneSink
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("stream should not stop") }
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
        XCTAssertEqual(adapter.handleMicrophone(for: session, sampleBuffer: sample), .appended)
        XCTAssertEqual(microphoneSink.appendCount, 1)

        let heldLease = store.acquire(session)
        var cleanedSessions = [UUID]()
        XCTAssertTrue(adapter.handleStartFailure(session) { failedSession in
            cleanedSessions.append(failedSession.id)
            store.release(failedSession)
        })
        XCTAssertTrue(cleanedSessions.isEmpty)
        heldLease?.release()
        XCTAssertEqual(cleanedSessions, [session.id])
    }

    func testExternalMicrophoneCallbackUsesInjectedRouteOffMain() throws {
        let stream = NSObject()
        let videoSink = TestVideoDestination()
        let microphoneSink = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let session = makeCaptureSession(
            stream: stream,
            mode: .transparent,
            sink: videoSink,
            microphoneInput: microphoneSink
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { _ in XCTFail("stream should not stop") }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))
        let callbackQueue = DispatchQueue(label: "WindowCapturePrivacyTests.external-microphone")
        let route = CaptureMicrophoneCallbackRoute(callbackQueue: callbackQueue)
        let results = LockedCaptureSampleResults()
        let forwarded = expectation(description: "off-main microphone sample forwarded")
        let rejectedAfterStop = expectation(description: "stopped route rejects microphone sample")

        XCTAssertTrue(store.install(session))
        XCTAssertEqual(
            adapter.handleSample(
                from: stream,
                sampleBuffer: sample,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended
        )
        XCTAssertTrue(Thread.isMainThread, "capture setup is expected to run on the main thread")
        route.configure(session: session, callbackAdapter: adapter)
        callbackQueue.async {
            XCTAssertFalse(Thread.isMainThread)
            results.append(route.handle(sample))
            forwarded.fulfill()
        }
        wait(for: [forwarded], timeout: 2)
        XCTAssertEqual(microphoneSink.appendCount, 1, "the injected route must forward to its exact session")

        route.drainAndClear()
        callbackQueue.async {
            results.append(route.handle(sample))
            rejectedAfterStop.fulfill()
        }
        wait(for: [rejectedAfterStop], timeout: 2)
        XCTAssertEqual(results.values, [.appended, .rejected])
        XCTAssertEqual(microphoneSink.appendCount, 1, "stop must clear the callback route")
    }

    func testExternalMicrophoneStopDrainsDelegateQueueBeforeRouteReuse() throws {
        let streamA = NSObject()
        let streamB = NSObject()
        let videoSinkA = TestVideoDestination()
        let videoSinkB = TestVideoDestination()
        let microphoneSinkA = TestVideoDestination()
        let microphoneSinkB = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let callbackQueue = DispatchQueue(label: "WindowCapturePrivacyTests.external-microphone-drain")
        let route = CaptureMicrophoneCallbackRoute(callbackQueue: callbackQueue)
        let stopReachedDrain = DispatchSemaphore(value: 0)
        let stopCompleted = DispatchSemaphore(value: 0)
        let configureBStarted = DispatchSemaphore(value: 0)
        let configureBCompleted = DispatchSemaphore(value: 0)
        let callbackAStarted = DispatchSemaphore(value: 0)
        let releaseCallbackA = DispatchSemaphore(value: 0)
        let callbackACompleted = DispatchSemaphore(value: 0)
        let lateACompleted = DispatchSemaphore(value: 0)
        let callbackBCompleted = DispatchSemaphore(value: 0)
        let results = LockedCaptureSampleResults()
        var core: CaptureOutputCore!
        core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { stoppedSession in
                stopReachedDrain.signal()
                route.drainAndClear()
                store.release(stoppedSession)
            }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)
        let sessionA = makeCaptureSession(
            stream: streamA,
            mode: .transparent,
            sink: videoSinkA,
            microphoneInput: microphoneSinkA
        )
        let sessionB = makeCaptureSession(
            stream: streamB,
            mode: .transparent,
            sink: videoSinkB,
            microphoneInput: microphoneSinkB
        )
        let sampleA = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))
        let sampleB = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[1]))

        XCTAssertTrue(store.install(sessionA))
        XCTAssertEqual(
            adapter.handleSample(
                from: streamA,
                sampleBuffer: sampleA,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended
        )
        route.configure(session: sessionA, callbackAdapter: adapter)
        callbackQueue.async {
            callbackAStarted.signal()
            _ = releaseCallbackA.wait(timeout: .now() + 2)
            results.append(route.handle(sampleA))
            callbackACompleted.signal()
        }
        XCTAssertEqual(callbackAStarted.wait(timeout: .now() + 2), .success)

        DispatchQueue(label: "WindowCapturePrivacyTests.external-microphone-stop").async {
            _ = adapter.handleStop(from: streamA)
            stopCompleted.signal()
        }
        XCTAssertEqual(stopReachedDrain.wait(timeout: .now() + 2), .success)
        DispatchQueue(label: "WindowCapturePrivacyTests.external-microphone-configure-b").async {
            configureBStarted.signal()
            route.configure(session: sessionB, callbackAdapter: adapter)
            configureBCompleted.signal()
        }
        XCTAssertEqual(configureBStarted.wait(timeout: .now() + 2), .success)

        let earlyStop = stopCompleted.wait(timeout: .now() + 0.1)
        let earlyBConfiguration = configureBCompleted.wait(timeout: .now() + 0.1)
        XCTAssertEqual(earlyStop, .timedOut, "Stop must wait for the exact delegate queue to drain")
        XCTAssertEqual(
            earlyBConfiguration,
            .timedOut,
            "B must not reconfigure the route while A remains queued"
        )

        releaseCallbackA.signal()
        XCTAssertEqual(callbackACompleted.wait(timeout: .now() + 2), .success)
        if earlyStop == .timedOut {
            XCTAssertEqual(stopCompleted.wait(timeout: .now() + 2), .success)
        }
        if earlyBConfiguration == .timedOut {
            XCTAssertEqual(configureBCompleted.wait(timeout: .now() + 2), .success)
        }
        route.drainAndClear()
        callbackQueue.async {
            results.append(route.handle(sampleA))
            lateACompleted.signal()
        }
        XCTAssertEqual(lateACompleted.wait(timeout: .now() + 2), .success)

        XCTAssertTrue(store.install(sessionB))
        XCTAssertEqual(
            adapter.handleSample(
                from: streamB,
                sampleBuffer: sampleB,
                kind: .screen(isComplete: true, presenterOverlayX: nil)
            ),
            .appended
        )
        route.configure(session: sessionB, callbackAdapter: adapter)
        callbackQueue.async {
            results.append(route.handle(sampleB))
            callbackBCompleted.signal()
        }
        XCTAssertEqual(callbackBCompleted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.values, [.rejected, .rejected, .appended])
        XCTAssertEqual(microphoneSinkA.appendCount, 0)
        XCTAssertEqual(microphoneSinkB.appendCount, 1)
    }

    func testMissingWriterFinalizationClearsOnlyItsFinishedJob() throws {
        let lifecycleSource = try projectSource("QuickRecorder/WindowCapturePrivacy.swift")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-writer-finalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let finishedA = try RecordingOutputJob.reserve(
            in: directory,
            preferredStem: "finished-a",
            layout: .single(fileExtension: "mov")
        )
        let newerB = try RecordingOutputJob.reserve(
            in: directory,
            preferredStem: "newer-b",
            layout: .single(fileExtension: "mov")
        )
        let lateA = try RecordingOutputJob.reserve(
            in: directory,
            preferredStem: "late-a",
            layout: .single(fileExtension: "mov")
        )
        defer {
            _ = newerB.discardOutputs(reason: .cancelled(stage: .first))
        }
        let sample = try makeSampleBuffer(imageBuffer: makeRoundedWindow(over: sentinels[0]))

        var currentA: RecordingOutputJob? = finishedA
        var firstFrameA: CMSampleBuffer? = sample
        CaptureMissingWriterFinalizer.discard(
            finishedA,
            currentJob: &currentA,
            firstFrame: &firstFrameA
        )
        XCTAssertNil(currentA, "a terminal job must not remain globally current")
        XCTAssertNil(firstFrameA, "the missing-writer exit must perform shared frame cleanup")
        XCTAssertEqual(finishedA.lifecycle, .terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedA.reservationURL.path))

        var currentB: RecordingOutputJob? = newerB
        var firstFrameB: CMSampleBuffer? = sample
        CaptureMissingWriterFinalizer.discard(
            lateA,
            currentJob: &currentB,
            firstFrame: &firstFrameB
        )
        XCTAssertTrue(currentB === newerB, "late cleanup for A must preserve newer job B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newerB.reservationURL.path))
        XCTAssertNil(firstFrameB, "the early return must clear retained frame state")
        let productionEntryStart = try XCTUnwrap(
            lifecycleSource.range(of: "final class CaptureProductionStopEntry")
        )
        let productionEntryEnd = try XCTUnwrap(
            lifecycleSource.range(
                of: "enum CaptureFinalizationPresentation",
                range: productionEntryStart.upperBound..<lifecycleSource.endIndex
            )
        )
        let productionEntrySource = lifecycleSource[
            productionEntryStart.lowerBound..<productionEntryEnd.lowerBound
        ]
        XCTAssertTrue(productionEntrySource.contains("finishedJob.discardOutputs(reason:"))
        XCTAssertTrue(productionEntrySource.contains("The recording writer is unavailable."))
    }

    func testCaptureDelegatesAndUIStopUseTheProductionCallbackAdapter() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")
        let privacySource = try projectSource("QuickRecorder/WindowCapturePrivacy.swift")

        XCTAssertTrue(engineSource.contains("captureStreamCallbackAdapter.handleSample("))
        XCTAssertTrue(engineSource.contains("captureStreamCallbackAdapter.handleStop(from: stream)"))
        XCTAssertTrue(privacySource.contains("session.releaseStandaloneAudioResources()"))
        XCTAssertEqual(
            engineSource.components(separatedBy: "captureStreamCallbackAdapter.handleMicrophone(").count - 1,
            2,
            "AEC and default-device microphone callbacks must use the owning delegate's adapter"
        )
        XCTAssertTrue(engineSource.contains("callbackAdapter: captureStreamCallbackAdapter"))
        XCTAssertTrue(engineSource.contains("callbackRoute.configure(session: session, callbackAdapter: callbackAdapter)"))
        XCTAssertTrue(engineSource.contains("_ = callbackRoute.handle(sampleBuffer)"))
        XCTAssertTrue(engineSource.contains("private let audioQueue: DispatchQueue"))
        XCTAssertTrue(engineSource.contains("CaptureMicrophoneCallbackRoute(callbackQueue: audioQueue)"))
        XCTAssertTrue(engineSource.contains("setSampleBufferDelegate(self, queue: audioQueue)"))
        XCTAssertTrue(engineSource.contains("setSampleBufferDelegate(nil, queue: nil)"))
        XCTAssertTrue(engineSource.contains("callbackRoute.drainAndClear()"))
        XCTAssertEqual(
            privacySource.components(separatedBy: "callbackQueue.sync {").count - 1,
            2,
            "configuration and teardown must cross the exact delegate queue"
        )
        XCTAssertTrue(privacySource.contains("dispatchPrecondition(condition: .onQueue(callbackQueue))"))
        XCTAssertTrue(privacySource.contains("dispatchPrecondition(condition: .notOnQueue(callbackQueue))"))
        let audioRecorderSource = try XCTUnwrap(
            engineSource.components(separatedBy: "class AudioRecorder").last?
                .components(separatedBy: "extension CMSampleBuffer").first
        )
        XCTAssertFalse(audioRecorderSource.contains("AppDelegate.shared"))
        let stopSource = try XCTUnwrap(
            audioRecorderSource.components(separatedBy: "func stop()").last?
                .components(separatedBy: "func captureOutput").first
        )
        let stopRunning = try XCTUnwrap(stopSource.range(of: "session.stopRunning()"))
        let detachDelegate = try XCTUnwrap(
            stopSource.range(of: "setSampleBufferDelegate(nil, queue: nil)")
        )
        let drainRoute = try XCTUnwrap(stopSource.range(of: "callbackRoute.drainAndClear()"))
        XCTAssertLessThan(stopRunning.lowerBound, detachDelegate.lowerBound)
        XCTAssertLessThan(detachDelegate.lowerBound, drainRoute.lowerBound)
        XCTAssertTrue(engineSource.contains("captureStreamCallbackAdapter.handleStartFailure("))
        XCTAssertTrue(contextSource.contains("captureStreamCallbackAdapter.handleStop(from: activeStream)"))
    }

    func testPreSessionAudioOutputFailureHasAnOwningCleanupBoundary() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        var preparedAudioResource: LifetimeProbe? = LifetimeProbe()
        let weakPreparedAudioResource = WeakReference(preparedAudioResource)
        var cleanupRan = false
        let owner = CapturePreparationOwner { _ in
            cleanupRan = true
            preparedAudioResource = nil
        }

        XCTAssertThrowsError(
            try CapturePreSessionSetup.addOutputs(owner: owner) {
                try injectedAddOutputFailure()
            }
        )

        XCTAssertTrue(cleanupRan, "addStreamOutput failure must invoke the preparation owner")
        XCTAssertNil(weakPreparedAudioResource.value, "prepared audio resources must close before outer cleanup")
        XCTAssertTrue(engineSource.contains("CapturePreparationOwner {"))
        XCTAssertTrue(engineSource.contains("CapturePreSessionSetup.addOutputs(owner: preparationOwner)"))
        XCTAssertTrue(engineSource.contains("PreparedAudioCaptureSnapshot.capture()"))
    }

    func testPreparationFailureKeepsReservationAndResourcesIsolatedThroughCleanup() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let store = CaptureOutputSessionStore()
        let coordinator = CapturePreparationFailureCoordinator(store: store)
        let sessionA = UUID()
        let sessionB = UUID()
        var globalResource: LifetimeProbe? = LifetimeProbe()
        let resourceA = globalResource
        let resourceB = LifetimeProbe()
        let cleanupStarted = expectation(description: "A cleanup started")
        let cleanupFinished = expectation(description: "A cleanup finished")
        let allowCleanup = DispatchSemaphore(value: 0)

        XCTAssertTrue(store.reserve(sessionA))
        DispatchQueue(label: "WindowCapturePrivacyTests.preparation-failure-order").async {
            coordinator.cleanup(sessionID: sessionA) {
                cleanupStarted.fulfill()
                _ = allowCleanup.wait(timeout: .now() + 2)
                CapturePreparationResourceSnapshot.clear(resourceA, from: &globalResource)
            }
            cleanupFinished.fulfill()
        }
        wait(for: [cleanupStarted], timeout: 2)

        let bReservedDuringACleanup = store.reserve(sessionB)
        if bReservedDuringACleanup { globalResource = resourceB }
        XCTAssertFalse(
            bReservedDuringACleanup,
            "B must not reserve while A's failed preparation still owns capture resources"
        )

        allowCleanup.signal()
        wait(for: [cleanupFinished], timeout: 2)
        if bReservedDuringACleanup {
            XCTAssertTrue(globalResource === resourceB, "A cleanup must never clear B's replacement resource")
        } else {
            XCTAssertNil(globalResource)
            XCTAssertTrue(store.reserve(sessionB), "B may reserve only after A cleanup completes")
        }
        XCTAssertTrue(engineSource.contains("CapturePreparationFailureCoordinator(store: captureOutputSessions)"))
        XCTAssertTrue(engineSource.contains("PreparedAudioCaptureSnapshot.capture()"))
        XCTAssertFalse(engineSource.contains("catch {\n            captureOutputSessions.cancelReservation(sessionID)"))
    }

    func testCaptureCallbackInfrastructureDoesNotUseUnsynchronizedLazyInitialization() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")

        XCTAssertFalse(appSource.contains("lazy var captureOutputCore"))
        XCTAssertFalse(appSource.contains("lazy var captureStreamCallbackAdapter"))
        XCTAssertTrue(appSource.contains("CaptureOutputInfrastructureProvider"))
    }

    func testConcurrentCallbackInfrastructureResolutionBuildsOneCoreAndAdapter() {
        let provider = CaptureOutputInfrastructureProvider()
        let observations = LockedInfrastructureObservations()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let infrastructure = provider.resolve {
                observations.recordBuild()
                let core = CaptureOutputCore(
                    store: CaptureOutputSessionStore(),
                    failureHandler: { _ in },
                    stopHandler: { _ in }
                )
                return CaptureOutputInfrastructure(
                    core: core,
                    adapter: CaptureStreamCallbackAdapter(core: core)
                )
            }
            observations.record(infrastructure)
        }

        XCTAssertEqual(observations.buildCount, 1)
        XCTAssertEqual(observations.coreCount, 1)
        XCTAssertEqual(observations.adapterCount, 1)
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

    func testEnabledMicrophoneStartupCannotCrashOrSilentlyContinue() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let privacySource = try projectSource("QuickRecorder/WindowCapturePrivacy.swift")
        let microphoneStartSource = try XCTUnwrap(
            engineSource.components(separatedBy: "func startMicRecording").last?
                .components(separatedBy: "func finishCaptureSession").first
        )
        let rollbackSource = try XCTUnwrap(
            engineSource.components(separatedBy: "private func discardPreparedCapture").last?
                .components(separatedBy: "func prepareAudioRecording").first
        )

        XCTAssertFalse(engineSource.contains("try! SCContext.audioEngine.start()"))
        XCTAssertFalse(engineSource.contains("try? SCContext.AECEngine.startAudioStream"))
        XCTAssertTrue(engineSource.contains("func startMicRecording(session: CaptureOutputSession) throws"))
        XCTAssertTrue(engineSource.contains("try startMicRecording(session: session)"))
        XCTAssertTrue(engineSource.contains("try CaptureMicrophoneStartup.start("))
        XCTAssertTrue(engineSource.contains("CaptureFailedStartCleanup.run("))
        XCTAssertTrue(engineSource.contains("deviceName: micDevice"))
        XCTAssertTrue(engineSource.contains("CaptureMicrophoneDeviceResolver.resolve("))
        XCTAssertTrue(engineSource.contains("inputFormat.sampleRate > 0, inputFormat.channelCount > 0"))
        XCTAssertFalse(microphoneStartSource.contains("SCContext.showNotification("))
        XCTAssertTrue(privacySource.contains("if stopsMicrophone { session.stopMicrophoneCapture() }"))
        XCTAssertTrue(rollbackSource.contains("CaptureFailedStartCleanup.run("))
        XCTAssertTrue(rollbackSource.contains("SCContext.outputJob === job"))
        XCTAssertTrue(rollbackSource.contains("CaptureFailedStartErrorPresenter.present("))
        XCTAssertFalse(rollbackSource.contains("SCContext.showNotification("))
    }

    func testDefaultMicrophoneStartFailureAfterTapInstallCleansJobAndAllowsRetry() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicrophoneStartupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = CaptureOutputSessionStore()
        let streamA = NSObject()
        let failedJob = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            preferredStem: "Issue 38 retry",
            layout: .single(fileExtension: "mp4", recordsMicrophone: true)
        )
        try Data("partial recording".utf8).write(to: failedJob.inputURL)
        let sidebandURL = failedJob.reservationURL.appendingPathComponent("capture-diagnostics.json")
        try Data("private diagnostics".utf8).write(to: sidebandURL)

        var tapInstalled = false
        var microphoneStopCount = 0
        var streamStopCount = 0
        var sharedResourcesCleared = false
        var visibleErrors = [String]()
        let failedSession = makeCaptureSession(
            stream: streamA,
            mode: .transparent,
            sink: TestVideoDestination(),
            microphoneInput: TestVideoDestination(),
            outputJob: failedJob,
            microphoneStopHandler: {
                microphoneStopCount += 1
                tapInstalled = false
            }
        )
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in XCTFail("sample processing should not fail") },
            stopHandler: { stoppedSession in
                stoppedSession.stopMicrophoneCapture()
                if let job = stoppedSession.outputJob {
                    _ = job.finishSingleOutput()
                }
                store.release(stoppedSession)
            }
        )
        let adapter = CaptureStreamCallbackAdapter(core: core)

        XCTAssertTrue(store.install(failedSession))
        var recordingError: RecordingExportError?
        XCTAssertThrowsError(
            try CaptureMicrophoneStartup.start(
                selection: .defaultDevice,
                session: failedSession,
                install: { tapInstalled = true },
                start: { throw InjectedCaptureSetupError.microphoneStartFailed }
            )
        ) { error in
            XCTAssertEqual(
                error as? CaptureMicrophoneStartupError,
                .unavailable(.defaultDevice)
            )
            recordingError = .preparation(stage: .first, message: error.localizedDescription)
        }
        XCTAssertFalse(tapInstalled, "the installed tap must be removed before rollback continues")
        XCTAssertEqual(microphoneStopCount, 1)

        let failure = try XCTUnwrap(recordingError)
        XCTAssertTrue(adapter.handleStartFailure(failedSession) { session in
            CaptureFailedStartCleanup.run(
                session: session,
                error: failure,
                stopsMicrophone: true,
                stopStream: { streamStopCount += 1 },
                clearSharedResources: { sharedResourcesCleared = true },
                notify: { visibleErrors.append($0) }
            )
            store.release(session)
        })

        XCTAssertEqual(microphoneStopCount, 1, "microphone rollback must be idempotent")
        XCTAssertEqual(streamStopCount, 1)
        XCTAssertTrue(sharedResourcesCleared)
        XCTAssertEqual(visibleErrors, [failure.localizedDescription])
        XCTAssertTrue(visibleErrors[0].contains("default microphone"))
        XCTAssertNil(store.activeSession())
        XCTAssertEqual(failedJob.lifecycle, .terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedJob.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedJob.reservationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedJob.inputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidebandURL.path))

        let retryStream = NSObject()
        let retryJob = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            preferredStem: "Issue 38 retry",
            layout: .single(fileExtension: "mp4", recordsMicrophone: true)
        )
        XCTAssertEqual(retryJob.finalURL, failedJob.finalURL, "failed output reservation must be reusable")
        try Data("complete recording".utf8).write(to: retryJob.inputURL)
        var retryTapInstalled = false
        var retryStarted = false
        let retrySession = makeCaptureSession(
            stream: retryStream,
            mode: .transparent,
            sink: TestVideoDestination(),
            microphoneInput: TestVideoDestination(),
            outputJob: retryJob,
            microphoneStopHandler: { retryTapInstalled = false }
        )

        XCTAssertTrue(store.install(retrySession))
        XCTAssertNoThrow(
            try CaptureMicrophoneStartup.start(
                selection: .defaultDevice,
                session: retrySession,
                install: { retryTapInstalled = true },
                start: { retryStarted = true }
            )
        )
        XCTAssertTrue(retryTapInstalled)
        XCTAssertTrue(retryStarted)
        XCTAssertTrue(adapter.handleStop(from: retryStream))
        XCTAssertNil(store.activeSession())
        XCTAssertEqual(retryJob.lifecycle, .terminal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retryJob.finalURL.path))
        XCTAssertEqual(try Data(contentsOf: retryJob.finalURL), Data("complete recording".utf8))
    }

    func testFailedMicrophoneStartPresentsOneInAppEnglishError() {
        let error = CaptureMicrophoneStartupError.unavailable(
            .named("Grab Rabbit Missing Microphone")
        )
        var presentations = [(title: String, message: String)]()
        var events = [String]()

        CaptureFailedStartErrorPresenter.present(
            message: error.localizedDescription,
            activateApp: { events.append("activate") },
            showAlert: { title, message in
                events.append("alert")
                presentations.append((title: title, message: message))
            }
        )

        XCTAssertEqual(events, ["activate", "alert"])
        XCTAssertEqual(presentations.count, 1)
        XCTAssertEqual(presentations[0].title, "Failed to Record")
        XCTAssertEqual(
            presentations[0].message,
            "The selected microphone “Grab Rabbit Missing Microphone” is unavailable. Reconnect it or choose another microphone, then try again."
        )
    }

    func testPersistedNamedMicrophoneDisappearanceFailsBeforeCaptureStarts() {
        let selection = CaptureMicrophoneSelection.named("Desk USB Mic")
        let availableDevices = [TestMicrophone(name: "Built-in Microphone")]
        var stopCount = 0
        var startCalled = false
        let session = makeCaptureSession(
            stream: NSObject(),
            mode: .transparent,
            sink: TestVideoDestination(),
            microphoneInput: TestVideoDestination(),
            microphoneStopHandler: { stopCount += 1 }
        )

        XCTAssertThrowsError(
            try CaptureMicrophoneStartup.start(
                selection: selection,
                session: session,
                install: {
                    _ = try CaptureMicrophoneDeviceResolver.resolve(
                        named: "Desk USB Mic",
                        from: availableDevices,
                        name: \.name
                    )
                },
                start: { startCalled = true }
            )
        ) { error in
            XCTAssertEqual(error as? CaptureMicrophoneStartupError, .unavailable(selection))
            XCTAssertEqual(
                error.localizedDescription,
                "The selected microphone \u{201c}Desk USB Mic\u{201d} is unavailable. Reconnect it or choose another microphone, then try again."
            )
        }
        XCTAssertFalse(startCalled)
        XCTAssertEqual(stopCount, 1)
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
        try makeRoundedWindow(
            width: width,
            height: height,
            cornerRadius: cornerRadius,
            over: sentinel
        )
    }

    private func makeRoundedWindow(
        width: Int,
        height: Int,
        cornerRadius: Int,
        over sentinel: WindowCaptureMatte
    ) throws -> CVPixelBuffer {
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
                if isExterior(
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    cornerRadius: cornerRadius
                ) {
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
        presentationTime: CMTime = .zero,
        duration: CMTime = CMTime(value: 1, timescale: 30)
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
            duration: duration,
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

    private func waitUntilReady(_ input: AVAssetWriterInput, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !input.isReadyForMoreMediaData, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        return input.isReadyForMoreMediaData
    }

    private func exteriorCornerAlphas(of buffer: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }
        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        return [(0, 0), (bufferWidth - 1, 0), (0, bufferHeight - 1), (bufferWidth - 1, bufferHeight - 1)].map { x, y in
            baseAddress
                .advanced(by: y * bytesPerRow + x * 4)
                .assumingMemoryBound(to: UInt8.self)[3]
        }
    }

    private func exteriorCornerBGRA(
        of buffer: CVPixelBuffer
    ) throws -> [(blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }
        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        return [(0, 0), (bufferWidth - 1, 0), (0, bufferHeight - 1), (bufferWidth - 1, bufferHeight - 1)].map { x, y in
            let pixel = baseAddress
                .advanced(by: y * bytesPerRow + x * 4)
                .assumingMemoryBound(to: UInt8.self)
            return (pixel[0], pixel[1], pixel[2], pixel[3])
        }
    }

    private func makeCaptureSession(
        stream: AnyObject,
        mode: WindowCaptureMode,
        sink: any CaptureVideoSampleDestination,
        microphoneInput: (any CaptureVideoSampleDestination)? = nil,
        outputJob: RecordingOutputJob? = nil,
        isAudioOnly: Bool = false,
        writerFinalizer: (any CaptureWriterFinalizing)? = nil,
        saveFrameHandler: ((CMSampleBuffer) -> Void)? = nil,
        firstFrameHandler: ((CMSampleBuffer) -> Void)? = nil,
        diagnostics: CaptureDiagnostics = CaptureDiagnostics(enabled: false),
        microphoneStopHandler: (() -> Void)? = nil
    ) -> CaptureOutputSession {
        CaptureOutputSession(
            stream: stream,
            outputJob: outputJob,
            writer: nil,
            writerFinalizer: writerFinalizer,
            videoInput: sink,
            systemAudioInput: nil,
            microphoneInput: microphoneInput,
            standaloneAudioFile: nil,
            configurationOwner: CaptureConfigurationOwner(windowMode: mode, fallbackBackgroundColor: nil),
            sampleQueue: DispatchQueue(label: "WindowCapturePrivacyTests.\(mode.rawValue)"),
            isAudioOnly: isAudioOnly,
            saveFrameHandler: saveFrameHandler,
            firstFrameHandler: firstFrameHandler,
            diagnostics: diagnostics,
            microphoneStopHandler: microphoneStopHandler
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

    private func injectedAddOutputFailure() throws {
        throw InjectedCaptureSetupError.addOutputFailed
    }

    private func presenterSample(index: Int) throws -> CMSampleBuffer {
        try makeSampleBuffer(
            imageBuffer: makeRoundedWindow(over: sentinels[index % sentinels.count]),
            presentationTime: CMTime(value: Int64(index), timescale: 30)
        )
    }

    private func inspectExterior(
        of buffer: CVPixelBuffer,
        mode: WindowCaptureMode,
        sentinel: WindowCaptureMatte
    ) throws -> (sentinelPixels: Int, invalidPixels: Int) {
        try inspectExterior(
            of: buffer,
            mode: mode,
            sentinel: sentinel,
            width: width,
            height: height,
            cornerRadius: cornerRadius
        )
    }

    private func inspectExterior(
        of buffer: CVPixelBuffer,
        mode: WindowCaptureMode,
        sentinel: WindowCaptureMatte,
        width: Int,
        height: Int,
        cornerRadius: Int
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
            for x in 0..<width where isExterior(
                x: x,
                y: y,
                width: width,
                height: height,
                cornerRadius: cornerRadius
            ) {
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
        isExterior(
            x: x,
            y: y,
            width: width,
            height: height,
            cornerRadius: cornerRadius
        )
    }

    private func isExterior(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        cornerRadius: Int
    ) -> Bool {
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
    var appendResult = true
    private(set) var appendCount = 0
    private(set) var lastSampleBuffer: CMSampleBuffer?

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        appendCount += 1
        if appendResult { lastSampleBuffer = sampleBuffer }
        return appendResult
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

private final class LockedCaptureSampleResults {
    private let lock = NSLock()
    private var storage = [CaptureSampleResult]()

    var values: [CaptureSampleResult] { lock.withLock { storage } }

    func append(_ result: CaptureSampleResult) {
        lock.withLock { storage.append(result) }
    }
}

private final class LifetimeProbe {}

private final class WeakReference<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}

private enum InjectedCaptureSetupError: Error {
    case addOutputFailed
    case microphoneStartFailed
}

private struct TestMicrophone {
    let name: String
}

private final class DelayedCaptureWriterFinalizer: CaptureWriterFinalizing {
    private var completion: ((Result<Void, RecordingExportError>) -> Void)?
    private(set) var finishCallCount = 0

    func finish(_ completion: @escaping (Result<Void, RecordingExportError>) -> Void) {
        finishCallCount += 1
        self.completion = completion
    }

    func complete(_ result: Result<Void, RecordingExportError>) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

private final class ImmediateCaptureWriterFinalizer: CaptureWriterFinalizing {
    private let result: Result<Void, RecordingExportError>
    private(set) var finishCallCount = 0

    init(result: Result<Void, RecordingExportError>) {
        self.result = result
    }

    func finish(_ completion: @escaping (Result<Void, RecordingExportError>) -> Void) {
        finishCallCount += 1
        completion(result)
    }
}

private final class TestCaptureDelegate {
    let store: CaptureOutputSessionStore
    let core: CaptureOutputCore
    let adapter: CaptureStreamCallbackAdapter

    init() {
        let store = CaptureOutputSessionStore()
        let core = CaptureOutputCore(
            store: store,
            failureHandler: { _ in },
            stopHandler: { store.release($0) }
        )
        self.store = store
        self.core = core
        adapter = CaptureStreamCallbackAdapter(core: core)
    }
}

private final class ManualActionScheduler {
    private var actions = [() -> Void]()
    private(set) var delays = [TimeInterval]()

    var pendingCount: Int { actions.count }

    func append(delay: TimeInterval, action: @escaping () -> Void) {
        delays.append(delay)
        actions.append(action)
    }

    func runNext() {
        actions.removeFirst()()
    }
}

private final class LockedInfrastructureObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var builds = 0
    private var cores = Set<ObjectIdentifier>()
    private var adapters = Set<ObjectIdentifier>()

    var buildCount: Int { lock.withLock { builds } }
    var coreCount: Int { lock.withLock { cores.count } }
    var adapterCount: Int { lock.withLock { adapters.count } }

    func recordBuild() {
        lock.withLock { builds += 1 }
    }

    func record(_ infrastructure: CaptureOutputInfrastructure) {
        lock.withLock {
            cores.insert(ObjectIdentifier(infrastructure.core))
            adapters.insert(ObjectIdentifier(infrastructure.adapter))
        }
    }
}

private final class LockedDelegateIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedIdentities = Set<ObjectIdentifier>()
    private var resolutionErrors = [Error]()

    var identities: Set<ObjectIdentifier> { lock.withLock { resolvedIdentities } }
    var errors: [Error] { lock.withLock { resolutionErrors } }

    func record(_ delegate: TestCaptureDelegate) {
        _ = lock.withLock { resolvedIdentities.insert(ObjectIdentifier(delegate)) }
    }

    func record(_ error: Error) {
        lock.withLock { resolutionErrors.append(error) }
    }
}
