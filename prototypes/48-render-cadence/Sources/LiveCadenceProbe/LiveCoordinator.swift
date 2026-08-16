import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import LiveProbeCore
import Metal

final class LiveStatistics {
    private let lock = NSLock()
    private(set) var events = [LiveEvent]()
    private(set) var cameraCallbackTimes = [UInt64]()
    private(set) var windowCallbackTimes = [UInt64]()
    private(set) var outputTimes = [UInt64]()
    private(set) var cameraLatenciesMilliseconds = [Double]()
    private(set) var browserAgesMilliseconds = [Double]()
    private(set) var videoFramesAppended = 0
    private(set) var videoFramesDroppedNotReady = 0
    private(set) var videoAppendFailures = 0
    private(set) var cameraCallbacks = 0
    private(set) var windowCallbacks = 0
    private(set) var systemAudioCallbacks = 0
    private(set) var microphoneCallbacks = 0
    private(set) var audioDropsNotReady = 0
    private(set) var timestampRejections = 0
    private(set) var duplicateCameraFrames = 0
    private(set) var duplicateWindowFrames = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var selectedCameraDisconnected = false
    private(set) var privacySentinelPixelsAtCacheIngress = 0
    private(set) var privacySentinelPixelsRendered = 0
    private(set) var privacyUnsanitizedExteriorPixelsAtCacheIngress = 0
    private(set) var lastVideoPTS: Double?
    private(set) var lastSystemAudioPTS: Double?
    private(set) var lastMicrophonePTS: Double?

    func event(_ kind: String, pts: Double? = nil, value: Double? = nil, detail: String? = nil) {
        lock.lock()
        events.append(LiveEvent(
            kind: kind,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            outputPTSSeconds: pts,
            value: value,
            detail: detail
        ))
        lock.unlock()
    }

    func cameraCallback(at time: UInt64) {
        lock.lock(); cameraCallbacks += 1; cameraCallbackTimes.append(time); lock.unlock()
    }

    func windowCallback(at time: UInt64) {
        lock.lock(); windowCallbacks += 1; windowCallbackTimes.append(time); lock.unlock()
    }

    func audioCallback(system: Bool) {
        lock.lock()
        if system { systemAudioCallbacks += 1 } else { microphoneCallbacks += 1 }
        lock.unlock()
    }

    func recordPrivacyIngress(sentinel: Int, nonOpaqueExterior: Int) {
        lock.lock()
        privacySentinelPixelsAtCacheIngress += max(0, sentinel)
        privacyUnsanitizedExteriorPixelsAtCacheIngress += max(0, nonOpaqueExterior)
        lock.unlock()
    }

    func outputAppended(
        time: UInt64,
        pts: Double,
        cameraLatency: Double,
        browserAge: Double?,
        duplicateCamera: Bool,
        duplicateWindow: Bool,
        renderedSentinels: Int
    ) {
        lock.lock()
        videoFramesAppended += 1
        outputTimes.append(time)
        lastVideoPTS = pts
        cameraLatenciesMilliseconds.append(cameraLatency)
        if let browserAge { browserAgesMilliseconds.append(browserAge) }
        if duplicateCamera { duplicateCameraFrames += 1 }
        if duplicateWindow { duplicateWindowFrames += 1 }
        privacySentinelPixelsRendered += max(0, renderedSentinels)
        lock.unlock()
    }

    func videoNotReady() { lock.lock(); videoFramesDroppedNotReady += 1; lock.unlock() }
    func videoAppendFailed() { lock.lock(); videoAppendFailures += 1; lock.unlock() }
    func audioNotReady() { lock.lock(); audioDropsNotReady += 1; lock.unlock() }
    func timestampRejected() { lock.lock(); timestampRejections += 1; lock.unlock() }
    func paused() { lock.lock(); pauseCount += 1; lock.unlock() }
    func resumed() { lock.lock(); resumeCount += 1; lock.unlock() }
    func disconnected() { lock.lock(); selectedCameraDisconnected = true; lock.unlock() }
    func audioAppended(system: Bool, pts: Double) {
        lock.lock()
        if system { lastSystemAudioPTS = pts } else { lastMicrophonePTS = pts }
        lock.unlock()
    }

    func writeEvents(to url: URL) throws {
        lock.lock()
        let captured = events
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = try captured.map { event -> String in
            String(decoding: try encoder.encode(event), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func summary() -> StatisticsSummary {
        lock.lock()
        defer { lock.unlock() }
        return StatisticsSummary(
            events: events,
            cameraCallbackTimes: cameraCallbackTimes,
            windowCallbackTimes: windowCallbackTimes,
            outputTimes: outputTimes,
            cameraLatenciesMilliseconds: cameraLatenciesMilliseconds,
            browserAgesMilliseconds: browserAgesMilliseconds,
            videoFramesAppended: videoFramesAppended,
            videoFramesDroppedNotReady: videoFramesDroppedNotReady,
            videoAppendFailures: videoAppendFailures,
            cameraCallbacks: cameraCallbacks,
            windowCallbacks: windowCallbacks,
            systemAudioCallbacks: systemAudioCallbacks,
            microphoneCallbacks: microphoneCallbacks,
            audioDropsNotReady: audioDropsNotReady,
            timestampRejections: timestampRejections,
            duplicateCameraFrames: duplicateCameraFrames,
            duplicateWindowFrames: duplicateWindowFrames,
            pauseCount: pauseCount,
            resumeCount: resumeCount,
            selectedCameraDisconnected: selectedCameraDisconnected,
            privacySentinelPixelsAtCacheIngress: privacySentinelPixelsAtCacheIngress,
            privacySentinelPixelsRendered: privacySentinelPixelsRendered,
            privacyUnsanitizedExteriorPixelsAtCacheIngress: privacyUnsanitizedExteriorPixelsAtCacheIngress,
            lastVideoPTS: lastVideoPTS,
            lastSystemAudioPTS: lastSystemAudioPTS,
            lastMicrophonePTS: lastMicrophonePTS
        )
    }
}

struct StatisticsSummary {
    let events: [LiveEvent]
    let cameraCallbackTimes: [UInt64]
    let windowCallbackTimes: [UInt64]
    let outputTimes: [UInt64]
    let cameraLatenciesMilliseconds: [Double]
    let browserAgesMilliseconds: [Double]
    let videoFramesAppended: Int
    let videoFramesDroppedNotReady: Int
    let videoAppendFailures: Int
    let cameraCallbacks: Int
    let windowCallbacks: Int
    let systemAudioCallbacks: Int
    let microphoneCallbacks: Int
    let audioDropsNotReady: Int
    let timestampRejections: Int
    let duplicateCameraFrames: Int
    let duplicateWindowFrames: Int
    let pauseCount: Int
    let resumeCount: Int
    let selectedCameraDisconnected: Bool
    let privacySentinelPixelsAtCacheIngress: Int
    let privacySentinelPixelsRendered: Int
    let privacyUnsanitizedExteriorPixelsAtCacheIngress: Int
    let lastVideoPTS: Double?
    let lastSystemAudioPTS: Double?
    let lastMicrophonePTS: Double?
}

final class LiveCaptureCoordinator {
    let sampleQueue = DispatchQueue(label: "dev.clickai.grabrabbit.prototype.live.samples")
    let renderQueue = DispatchQueue(label: "dev.clickai.grabrabbit.prototype.live.render")
    let statistics = LiveStatistics()

    private let candidate: LiveCandidate
    private let canvas: LiveCanvas
    private let fps: Int
    private let requiresWindow: Bool
    private let cache = LiveFrameCache()
    private let cameraCopier = PixelBufferCopier()
    private let windowCopier = PixelBufferCopier()
    private let stateLock = NSLock()
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let ciContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let startUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var accumulatedPauseNanoseconds: UInt64 = 0
    private var pauseStartedNanoseconds: UInt64?
    private var paused = false
    private var stopReason: String?
    private var fixedTimer: DispatchSourceTimer?
    private var cameraSequence = 0
    private var windowSequence = 0
    private var lastOutputPTS = -Double.infinity
    private var lastOutputUptime: UInt64?
    private var lastCameraSequence: Int?
    private var lastWindowSequence: Int?
    private var lastSystemAudioPTS = -Double.infinity
    private var lastMicrophonePTS = -Double.infinity

    init(
        candidate: LiveCandidate,
        canvas: LiveCanvas,
        fps: Int,
        requiresWindow: Bool,
        outputURL: URL,
        includeSystemAudio: Bool,
        includeMicrophone: Bool
    ) throws {
        self.candidate = candidate
        self.canvas = canvas
        self.fps = fps
        self.requiresWindow = requiresWindow
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        let dimensions = canvas.dimensions
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        func makeAudioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        systemAudioInput = includeSystemAudio ? makeAudioInput() : nil
        microphoneInput = includeMicrophone ? makeAudioInput() : nil
        guard writer.canAdd(videoInput) else { throw LiveProbeError.writer("cannot add video input") }
        writer.add(videoInput)
        for input in [systemAudioInput, microphoneInput].compactMap({ $0 }) {
            guard writer.canAdd(input) else { throw LiveProbeError.writer("cannot add requested audio input") }
            writer.add(input)
        }
        guard let metal = MTLCreateSystemDefaultDevice() else {
            throw LiveProbeError.capture("Metal device unavailable")
        }
        ciContext = CIContext(mtlDevice: metal)
        guard writer.startWriting() else {
            throw LiveProbeError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        statistics.event("writer-started")
    }

    func startFixedClockIfNeeded() {
        guard candidate == .fixedClock else { return }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.render(trigger: "fixed-clock") }
        fixedTimer = timer
        timer.resume()
        statistics.event("fixed-clock-started", value: Double(fps))
    }

    func receiveCamera(_ sampleBuffer: CMSampleBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        statistics.cameraCallback(at: now)
        guard sampleBuffer.isValid, let image = sampleBuffer.imageBuffer else { return }
        do {
            let copied = try cameraCopier.copy(image)
            let sequence = cameraSequence
            cameraSequence += 1
            cache.storeCamera(LiveCameraFrame(
                pixelBuffer: copied,
                sourcePTS: sampleBuffer.presentationTimeStamp,
                arrivalUptimeNanoseconds: now,
                sequence: sequence
            ))
            if candidate == .cameraDriven {
                renderQueue.async { [weak self] in self?.render(trigger: "camera") }
            }
        } catch {
            requestStop(reason: "camera-frame-copy-failed: \(error)")
        }
    }

    func receiveWindow(_ sampleBuffer: CMSampleBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        statistics.windowCallback(at: now)
        do {
            let frame = try SanitizedWindowFrameFactory.make(
                from: sampleBuffer,
                copier: windowCopier,
                sequence: windowSequence
            )
            windowSequence += 1
            let sentinel = SanitizedWindowFrameFactory.countSentinelPixels(frame.pixelBuffer)
            let nonOpaque = SanitizedWindowFrameFactory.countNonOpaqueExteriorPixels(frame.pixelBuffer)
            statistics.recordPrivacyIngress(sentinel: sentinel, nonOpaqueExterior: nonOpaque)
            guard sentinel == 0, nonOpaque == 0 else {
                requestStop(reason: "privacy-boundary-failed")
                return
            }
            cache.storeWindow(frame)
        } catch {
            requestStop(reason: "window-sanitize-failed: \(error)")
        }
    }

    func receiveAudio(_ sampleBuffer: CMSampleBuffer, system: Bool) {
        statistics.audioCallback(system: system)
        guard !isPaused else { return }
        let input = system ? systemAudioInput : microphoneInput
        guard let input else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let pts = activeElapsedSeconds(at: now)
        guard pts >= 0 else { return }
        if system {
            guard pts > lastSystemAudioPTS else { statistics.timestampRejected(); return }
        } else {
            guard pts > lastMicrophonePTS else { statistics.timestampRejected(); return }
        }
        guard input.isReadyForMoreMediaData else { statistics.audioNotReady(); return }
        guard let adjusted = retime(sampleBuffer, to: pts), input.append(adjusted) else {
            statistics.audioNotReady()
            return
        }
        if system { lastSystemAudioPTS = pts } else { lastMicrophonePTS = pts }
        statistics.audioAppended(system: system, pts: pts)
    }

    func setPaused(_ shouldPause: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard paused != shouldPause else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        paused = shouldPause
        if shouldPause {
            pauseStartedNanoseconds = now
            statistics.paused()
            statistics.event("paused")
        } else {
            if let started = pauseStartedNanoseconds { accumulatedPauseNanoseconds += now - started }
            pauseStartedNanoseconds = nil
            statistics.resumed()
            statistics.event("resumed")
        }
    }

    var isPaused: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return paused
    }

    func selectedCameraDisconnected(uniqueID: String) {
        statistics.disconnected()
        statistics.event("selected-camera-disconnected", detail: uniqueID)
        requestStop(reason: "selected-camera-disconnected")
    }

    func requestStop(reason: String) {
        stateLock.lock()
        if stopReason == nil { stopReason = reason }
        stateLock.unlock()
        statistics.event("stop-requested", detail: reason)
    }

    var requestedStopReason: String? {
        stateLock.lock(); defer { stateLock.unlock() }; return stopReason
    }

    func finish(defaultReason: String) async throws -> String {
        fixedTimer?.cancel()
        fixedTimer = nil
        sampleQueue.sync {}
        renderQueue.sync {}
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LiveProbeError.writer(writer.error?.localizedDescription ?? "finish status \(writer.status.rawValue)")
        }
        statistics.event("writer-finished")
        return requestedStopReason ?? defaultReason
    }

    private func render(trigger: String) {
        guard !isPaused, requestedStopReason == nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let snapshot = cache.snapshot()
        guard let camera = snapshot.camera else { return }
        guard !requiresWindow || snapshot.window != nil else { return }
        let pts = activeElapsedSeconds(at: now)
        let minimumInterval = 1.0 / Double(fps)
        if let lastOutputUptime,
           Double(now - lastOutputUptime) / 1_000_000_000 < minimumInterval * 0.75 {
            return
        }
        guard pts > lastOutputPTS else { statistics.timestampRejected(); return }
        guard videoInput.isReadyForMoreMediaData else { statistics.videoNotReady(); return }
        guard let pool = videoAdaptor.pixelBufferPool else {
            requestStop(reason: "writer-pixel-buffer-pool-unavailable")
            return
        }
        var outputBuffer: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        guard allocation == kCVReturnSuccess, let outputBuffer else {
            requestStop(reason: "writer-pixel-buffer-allocation-\(allocation)")
            return
        }
        compose(camera: camera.pixelBuffer, window: snapshot.window?.pixelBuffer, into: outputBuffer)
        let renderedSentinels = SanitizedWindowFrameFactory.countSentinelPixels(outputBuffer)
        guard renderedSentinels == 0 else {
            requestStop(reason: "privacy-sentinel-rendered")
            return
        }
        let presentationTime = CMTime(seconds: pts, preferredTimescale: 60_000)
        guard videoAdaptor.append(outputBuffer, withPresentationTime: presentationTime) else {
            statistics.videoAppendFailed()
            requestStop(reason: "video-append-failed: \(writer.error?.localizedDescription ?? "unknown")")
            return
        }
        let cameraLatency = Double(now - camera.arrivalUptimeNanoseconds) / 1_000_000
        let browserAge = snapshot.window.map { Double(now - $0.arrivalUptimeNanoseconds) / 1_000_000 }
        statistics.outputAppended(
            time: now,
            pts: pts,
            cameraLatency: cameraLatency,
            browserAge: browserAge,
            duplicateCamera: lastCameraSequence == camera.sequence,
            duplicateWindow: snapshot.window.map { lastWindowSequence == $0.sequence } ?? false,
            renderedSentinels: renderedSentinels
        )
        lastOutputPTS = pts
        lastOutputUptime = now
        lastCameraSequence = camera.sequence
        lastWindowSequence = snapshot.window?.sequence
        statistics.event("video-appended", pts: pts, detail: trigger)
    }

    private func compose(camera: CVPixelBuffer, window: CVPixelBuffer?, into output: CVPixelBuffer) {
        let dimensions = canvas.dimensions
        let canvasRect = CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height)
        var image = CIImage(color: CIColor.black).cropped(to: canvasRect)
        if let window {
            image = aspectFit(CIImage(cvPixelBuffer: window), in: canvasRect).composited(over: image)
            let pipRect = CGRect(
                x: CGFloat(dimensions.width) * 0.70,
                y: CGFloat(dimensions.height) * 0.05,
                width: CGFloat(dimensions.width) * 0.25,
                height: CGFloat(dimensions.height) * 0.25
            )
            image = aspectFit(CIImage(cvPixelBuffer: camera), in: pipRect).composited(over: image)
        } else {
            image = aspectFit(CIImage(cvPixelBuffer: camera), in: canvasRect).composited(over: image)
        }
        ciContext.render(image, to: output, bounds: canvasRect, colorSpace: colorSpace)
    }

    private func aspectFit(_ image: CIImage, in target: CGRect) -> CIImage {
        let extent = image.extent
        let scale = min(target.width / extent.width, target.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translated = scaled.transformed(by: CGAffineTransform(
            translationX: target.midX - scaled.extent.midX,
            y: target.midY - scaled.extent.midY
        ))
        return translated.cropped(to: target)
    }

    private func activeElapsedSeconds(at now: UInt64) -> Double {
        stateLock.lock()
        let currentPause = pauseStartedNanoseconds.map { now - $0 } ?? 0
        let pausedDuration = accumulatedPauseNanoseconds + currentPause
        stateLock.unlock()
        return Double(now - startUptimeNanoseconds - pausedDuration) / 1_000_000_000
    }

    private func retime(_ sample: CMSampleBuffer, to seconds: Double) -> CMSampleBuffer? {
        let count = Int(CMSampleBufferGetNumSamples(sample))
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        var needed = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: count,
            arrayToFill: &timing,
            entriesNeededOut: &needed
        ) == noErr else { return nil }
        let firstPTS = timing[0].presentationTimeStamp
        let target = CMTime(seconds: seconds, preferredTimescale: 60_000)
        for index in timing.indices {
            timing[index].presentationTimeStamp = target + (timing[index].presentationTimeStamp - firstPTS)
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = target + (timing[index].decodeTimeStamp - firstPTS)
            }
        }
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjusted
        ) == noErr else { return nil }
        return adjusted
    }
}

final class CameraSampleDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let coordinator: LiveCaptureCoordinator
    weak var videoOutput: AVCaptureVideoDataOutput?

    init(coordinator: LiveCaptureCoordinator) {
        self.coordinator = coordinator
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput { coordinator.receiveCamera(sampleBuffer) }
        else { coordinator.receiveAudio(sampleBuffer, system: false) }
    }
}
