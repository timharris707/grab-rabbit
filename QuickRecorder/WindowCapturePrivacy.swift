import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum WindowCaptureMode: String, CaseIterable {
    case transparent
    case opaque

    var title: String {
        switch self {
        case .transparent: "Transparent"
        case .opaque: "Compatible"
        }
    }

    var tradeoff: String {
        switch self {
        case .transparent:
            "Transparent corners · ProRes 4444 MOV · larger files"
        case .opaque:
            "Opaque privacy matte · selected H.264/H.265 format · smaller files"
        }
    }
}

struct WindowCaptureMatte: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct WindowCaptureOutputProfile: Equatable {
    let fileExtension: String
    let fileType: AVFileType
    let codec: AVVideoCodecType
    let preservesAlpha: Bool
}

enum WindowCapturePrivacyError: Error {
    case unsupportedPixelFormat(OSType)
    case unavailableBaseAddress
}

enum WindowCapturePrivacy {
    // Opaque window capture uses one fixed sRGB black privacy matte so no desktop
    // color can enter the compatibility encode path.
    static let opaqueMatte = WindowCaptureMatte(red: 0, green: 0, blue: 0)

    static func outputProfile(
        mode: WindowCaptureMode,
        compatibilityFileType: AVFileType,
        compatibilityCodec: AVVideoCodecType
    ) -> WindowCaptureOutputProfile {
        switch mode {
        case .transparent:
            WindowCaptureOutputProfile(
                fileExtension: "mov",
                fileType: .mov,
                codec: .proRes4444,
                preservesAlpha: true
            )
        case .opaque:
            WindowCaptureOutputProfile(
                fileExtension: compatibilityFileType == .mp4 ? "mp4" : "mov",
                fileType: compatibilityFileType,
                codec: compatibilityCodec,
                preservesAlpha: false
            )
        }
    }

    static func pixelDimensions(
        contentRect: CGRect,
        pointPixelScale: CGFloat,
        highResolution: Bool
    ) -> (width: Int, height: Int) {
        let scale = highResolution ? pointPixelScale : 1
        return (
            width: max(1, Int((contentRect.width * scale).rounded())),
            height: max(1, Int((contentRect.height * scale).rounded()))
        )
    }

    static func backgroundColor(
        mode: WindowCaptureMode,
        matte: WindowCaptureMatte
    ) -> CGColor {
        switch mode {
        case .transparent:
            CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        case .opaque:
            CGColor(
                red: CGFloat(matte.red) / 255,
                green: CGFloat(matte.green) / 255,
                blue: CGFloat(matte.blue) / 255,
                alpha: 1
            )
        }
    }

    static func videoSettings(
        profile: WindowCaptureOutputProfile,
        width: Int,
        height: Int,
        compressionProperties: [String: Any]
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: profile.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if profile.codec != .proRes4444 {
            settings[AVVideoCompressionPropertiesKey] = compressionProperties
        }
        return settings
    }

    static func sanitize(
        _ pixelBuffer: CVPixelBuffer,
        mode: WindowCaptureMode,
        matte: WindowCaptureMatte
    ) throws {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA else {
            throw WindowCapturePrivacyError.unsupportedPixelFormat(pixelFormat)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let scanDepth = min(64, max(1, min(width, height) / 2))

        for y in 0..<height {
            guard y < scanDepth || y >= height - scanDepth else { continue }
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where x < scanDepth || x >= width - scanDepth {
                sanitizePixel(row.advanced(by: x * 4), mode: mode, matte: matte)
            }
        }
    }

    private static func sanitizePixel(
        _ pixel: UnsafeMutablePointer<UInt8>,
        mode: WindowCaptureMode,
        matte: WindowCaptureMatte
    ) {
        let alpha = pixel[3]
        guard alpha < 255 else { return }

        switch mode {
        case .transparent:
            if alpha == 0 {
                pixel[0] = 0
                pixel[1] = 0
                pixel[2] = 0
            }
        case .opaque:
            if alpha == 0 {
                pixel[0] = matte.blue
                pixel[1] = matte.green
                pixel[2] = matte.red
            } else {
                let inverseAlpha = 255 - Int(alpha)
                pixel[0] = composite(pixel[0], over: matte.blue, inverseAlpha: inverseAlpha)
                pixel[1] = composite(pixel[1], over: matte.green, inverseAlpha: inverseAlpha)
                pixel[2] = composite(pixel[2], over: matte.red, inverseAlpha: inverseAlpha)
            }
            pixel[3] = 255
        }
    }

    private static func composite(_ source: UInt8, over matte: UInt8, inverseAlpha: Int) -> UInt8 {
        UInt8(min(255, Int(source) + (Int(matte) * inverseAlpha + 127) / 255))
    }
}

protocol CaptureVideoSampleDestination: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    @discardableResult func append(_ sampleBuffer: CMSampleBuffer) -> Bool
}

extension AVAssetWriterInput: CaptureVideoSampleDestination {}

final class WindowCaptureFrameSanitizer {
    let mode: WindowCaptureMode
    let matte: WindowCaptureMatte
    let backgroundColor: CGColor

    init(mode: WindowCaptureMode, matte: WindowCaptureMatte) {
        self.mode = mode
        self.matte = matte
        backgroundColor = WindowCapturePrivacy.backgroundColor(mode: mode, matte: matte)
    }

    func sanitize(_ sampleBuffer: CMSampleBuffer) throws {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        try WindowCapturePrivacy.sanitize(pixelBuffer, mode: mode, matte: matte)
    }
}

final class CaptureConfigurationOwner {
    let windowSanitizer: WindowCaptureFrameSanitizer?
    let backgroundColor: CGColor?

    init(windowMode: WindowCaptureMode?, fallbackBackgroundColor: CGColor?) {
        windowSanitizer = windowMode.map {
            WindowCaptureFrameSanitizer(mode: $0, matte: WindowCapturePrivacy.opaqueMatte)
        }
        backgroundColor = windowSanitizer?.backgroundColor ?? fallbackBackgroundColor
    }

    func apply(to configuration: SCStreamConfiguration) {
        if let backgroundColor { configuration.backgroundColor = backgroundColor }
    }
}

enum CaptureStreamConstruction {
    static func build<Owner: AnyObject, Stream>(
        retaining owner: Owner,
        _ builder: () -> Stream
    ) -> Stream {
        withExtendedLifetime(owner) { builder() }
    }
}

enum CaptureSampleKind {
    case screen(isComplete: Bool, presenterOverlayX: CGFloat?)
    case audio
}

enum CaptureSampleResult: Equatable {
    case rejected
    case ignored
    case appended
    case appendFailed
    case failed
}

struct CaptureSessionStateSnapshot: Equatable {
    let isPaused: Bool
    let startTime: Date?
    let elapsedTime: TimeInterval
    let lastPTS: CMTime?
    let frameCount: Int
    let presenterType: String
    let isPresenterOn: Bool
    let isCameraReady: Bool
    let saveFrameRequested: Bool
}

final class CaptureSessionLease {
    let session: CaptureOutputSession
    private let lock = NSLock()
    private var releaseHandler: (() -> Void)?

    fileprivate init(session: CaptureOutputSession, releaseHandler: @escaping () -> Void) {
        self.session = session
        self.releaseHandler = releaseHandler
    }

    func release() {
        let handler = lock.withLock { () -> (() -> Void)? in
            defer { releaseHandler = nil }
            return releaseHandler
        }
        handler?()
    }

    deinit { release() }
}

final class CaptureOutputSession {
    let id: UUID
    let outputJob: RecordingOutputJob?
    let writer: AVAssetWriter?
    let videoInput: (any CaptureVideoSampleDestination)?
    let systemAudioInput: (any CaptureVideoSampleDestination)?
    let microphoneInput: (any CaptureVideoSampleDestination)?
    let configurationOwner: CaptureConfigurationOwner
    let sampleQueue: DispatchQueue
    let isAudioOnly: Bool

    private let streamIdentifier: ObjectIdentifier
    private let lifecycleLock = NSLock()
    private let callbackLock = NSLock()
    private var isAcceptingCallbacks = true
    private var inFlightCallbacks = 0
    private var drainHandler: (() -> Void)?
    private var isPaused = false
    private var isResumePending = false
    private var lastPTS: CMTime?
    private var timeOffset = CMTime.zero
    private var startTime: Date?
    private var pausedAt: Date?
    private var accumulatedPauseDuration: TimeInterval = 0
    private var framePTS = [CMTime]()
    private var presenterType = "OFF"
    private var isPresenterOn = false
    private var isCameraReady = false
    private var saveFrameRequested = false
    private var firstFrame: CMSampleBuffer?
    private var standaloneAudioFileStorage: AVAudioFile?
    private var standaloneAudioAppender: ((CMSampleBuffer) throws -> Void)?
    private var standaloneAudioReleaseHandler: ((AVAudioFile) -> Void)?
    private let saveFrameHandler: ((CMSampleBuffer) -> Void)?
    private var microphoneStopHandler: (() -> Void)?

    init(
        id: UUID = UUID(),
        stream: AnyObject,
        outputJob: RecordingOutputJob?,
        writer: AVAssetWriter?,
        videoInput: (any CaptureVideoSampleDestination)?,
        systemAudioInput: (any CaptureVideoSampleDestination)?,
        microphoneInput: (any CaptureVideoSampleDestination)? = nil,
        standaloneAudioFile: AVAudioFile?,
        configurationOwner: CaptureConfigurationOwner,
        sampleQueue: DispatchQueue,
        isAudioOnly: Bool,
        standaloneAudioAppender: ((CMSampleBuffer) throws -> Void)? = nil,
        standaloneAudioReleaseHandler: ((AVAudioFile) -> Void)? = nil,
        saveFrameHandler: ((CMSampleBuffer) -> Void)? = nil,
        microphoneStopHandler: (() -> Void)? = nil
    ) {
        self.id = id
        streamIdentifier = ObjectIdentifier(stream)
        self.outputJob = outputJob
        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
        standaloneAudioFileStorage = standaloneAudioFile
        self.configurationOwner = configurationOwner
        self.sampleQueue = sampleQueue
        self.isAudioOnly = isAudioOnly
        self.standaloneAudioAppender = standaloneAudioAppender
        self.standaloneAudioReleaseHandler = standaloneAudioReleaseHandler
        self.saveFrameHandler = saveFrameHandler
        self.microphoneStopHandler = microphoneStopHandler
    }

    func owns(stream: AnyObject) -> Bool {
        streamIdentifier == ObjectIdentifier(stream)
    }

    fileprivate func acquire() -> CaptureSessionLease? {
        lifecycleLock.withLock {
            guard isAcceptingCallbacks else { return nil }
            inFlightCallbacks += 1
            return CaptureSessionLease(session: self) { [weak self] in self?.releaseLease() }
        }
    }

    fileprivate func beginDraining(_ completion: @escaping () -> Void) -> Bool {
        lifecycleLock.withLock {
            guard isAcceptingCallbacks else { return false }
            isAcceptingCallbacks = false
            if inFlightCallbacks == 0 {
                return true
            }
            drainHandler = completion
            return false
        }
    }

    private func releaseLease() {
        let completion = lifecycleLock.withLock { () -> (() -> Void)? in
            precondition(inFlightCallbacks > 0)
            inFlightCallbacks -= 1
            guard !isAcceptingCallbacks, inFlightCallbacks == 0 else { return nil }
            defer { drainHandler = nil }
            return drainHandler
        }
        completion?()
    }

    fileprivate func process(
        _ sampleBuffer: CMSampleBuffer,
        kind: CaptureSampleKind,
        now: Date = Date()
    ) -> (result: CaptureSampleResult, needsPresenterReady: Bool) {
        callbackLock.withLock {
            guard sampleBuffer.isValid else { return (.ignored, false) }

            switch kind {
            case .screen(let isComplete, let presenterOverlayX):
                guard !isAudioOnly, isComplete, sampleBuffer.imageBuffer != nil else {
                    return (.ignored, false)
                }
                var adjustedSample = sampleBuffer
                do {
                    try configurationOwner.windowSanitizer?.sanitize(adjustedSample)
                } catch {
                    return (.failed, false)
                }
                if saveFrameRequested {
                    saveFrameRequested = false
                    saveFrameHandler?(adjustedSample)
                }
                guard !isPaused else { return (.ignored, false) }
                if isResumePending {
                    isResumePending = false
                    guard let lastPTS else { return (.ignored, false) }
                    var pts = CMSampleBufferGetPresentationTimeStamp(adjustedSample)
                    if timeOffset.flags.contains(.valid) { pts = CMTimeSubtract(pts, timeOffset) }
                    if lastPTS.flags.contains(.valid) {
                        let offset = CMTimeSubtract(pts, lastPTS)
                        timeOffset = timeOffset == .zero ? offset : CMTimeAdd(timeOffset, offset)
                    }
                }
                startWriterIfNeeded(sampleBuffer: adjustedSample, now: now)
                if timeOffset > .zero {
                    adjustedSample = Self.adjustTime(sample: adjustedSample, by: timeOffset) ?? adjustedSample
                }
                var pts = CMSampleBufferGetPresentationTimeStamp(adjustedSample)
                let duration = CMSampleBufferGetDuration(adjustedSample)
                if duration > .zero { pts = CMTimeAdd(pts, duration) }
                guard !framePTS.contains(where: { $0 >= pts }) else { return (.ignored, false) }
                framePTS.append(pts)
                if framePTS.count > 20 { framePTS.removeFirst(framePTS.count - 20) }
                lastPTS = pts

                var needsPresenterReady = false
                if let presenterOverlayX {
                    let newType = presenterOverlayX == .infinity ? "OFF" : (presenterOverlayX == 0 ? "Small" : "Big")
                    if newType != presenterType {
                        presenterType = newType
                        isCameraReady = false
                        needsPresenterReady = true
                    }
                }
                guard !isPresenterOn || isCameraReady else { return (.ignored, needsPresenterReady) }
                guard let videoInput, videoInput.isReadyForMoreMediaData else {
                    return (.ignored, needsPresenterReady)
                }
                if firstFrame == nil { firstFrame = adjustedSample }
                return (videoInput.append(adjustedSample) ? .appended : .appendFailed, needsPresenterReady)

            case .audio:
                guard !isPaused else { return (.ignored, false) }
                let adjustedSample = sampleBuffer
                if isResumePending {
                    isResumePending = false
                    guard let lastPTS else { return (.ignored, false) }
                    var pts = CMSampleBufferGetPresentationTimeStamp(adjustedSample)
                    if timeOffset.flags.contains(.valid) { pts = CMTimeSubtract(pts, timeOffset) }
                    if lastPTS.flags.contains(.valid) {
                        let offset = CMTimeSubtract(pts, lastPTS)
                        timeOffset = timeOffset == .zero ? offset : CMTimeAdd(timeOffset, offset)
                    }
                }
                if isAudioOnly {
                    startWriterIfNeeded(sampleBuffer: adjustedSample, now: now)
                    do {
                        try standaloneAudioAppender?(adjustedSample)
                        return (.appended, false)
                    } catch {
                        return (.failed, false)
                    }
                }
                guard lastPTS != nil,
                      let systemAudioInput,
                      systemAudioInput.isReadyForMoreMediaData else { return (.ignored, false) }
                return (systemAudioInput.append(adjustedSample) ? .appended : .appendFailed, false)
            }
        }
    }

    func processMicrophone(_ sampleBuffer: CMSampleBuffer) -> CaptureSampleResult {
        callbackLock.withLock {
            guard !isPaused, startTime != nil,
                  let microphoneInput,
                  microphoneInput.isReadyForMoreMediaData else { return .ignored }
            return microphoneInput.append(sampleBuffer) ? .appended : .appendFailed
        }
    }

    func stopMicrophoneCapture() {
        let handler = lifecycleLock.withLock { () -> (() -> Void)? in
            defer { microphoneStopHandler = nil }
            return microphoneStopHandler
        }
        handler?()
    }

    var standaloneAudioFile: AVAudioFile? {
        callbackLock.withLock { standaloneAudioFileStorage }
    }

    func releaseStandaloneAudioResources() {
        callbackLock.withLock {
            if let standaloneAudioFileStorage {
                standaloneAudioReleaseHandler?(standaloneAudioFileStorage)
            }
            standaloneAudioReleaseHandler = nil
            standaloneAudioAppender = nil
            standaloneAudioFileStorage = nil
        }
    }

    func requestSaveFrame() {
        callbackLock.withLock { saveFrameRequested = true }
    }

    func togglePause(now: Date = Date()) -> Bool {
        callbackLock.withLock {
            isPaused.toggle()
            if isPaused {
                pausedAt = now
            } else {
                isResumePending = true
                if let pausedAt {
                    accumulatedPauseDuration += max(0, now.timeIntervalSince(pausedAt))
                    self.pausedAt = nil
                }
            }
            return isPaused
        }
    }

    fileprivate func presenterDidStart() {
        callbackLock.withLock {
            isPresenterOn = true
            isCameraReady = false
        }
    }

    fileprivate func presenterDidStop() {
        callbackLock.withLock {
            presenterType = "OFF"
            isPresenterOn = false
            isCameraReady = false
        }
    }

    fileprivate func markPresenterReady() {
        callbackLock.withLock { isCameraReady = true }
    }

    func stateSnapshot(now: Date = Date()) -> CaptureSessionStateSnapshot {
        callbackLock.withLock {
            CaptureSessionStateSnapshot(
                isPaused: isPaused,
                startTime: startTime,
                elapsedTime: elapsedTime(now: now),
                lastPTS: lastPTS,
                frameCount: framePTS.count,
                presenterType: presenterType,
                isPresenterOn: isPresenterOn,
                isCameraReady: isCameraReady,
                saveFrameRequested: saveFrameRequested
            )
        }
    }

    private func elapsedTime(now: Date) -> TimeInterval {
        guard let startTime else { return 0 }
        let endpoint = pausedAt ?? now
        return max(0, endpoint.timeIntervalSince(startTime) - accumulatedPauseDuration)
    }

    func capturedFirstFrame() -> CMSampleBuffer? {
        callbackLock.withLock { firstFrame }
    }

    private func startWriterIfNeeded(sampleBuffer: CMSampleBuffer, now: Date) {
        guard startTime == nil else { return }
        if let writer, writer.status == .writing {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        startTime = now
    }

    private static func adjustTime(sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferGetFormatDescription(sample) != nil else { return nil }
        var timing = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(),
            count: Int(CMSampleBufferGetNumSamples(sample))
        )
        CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: timing.count,
            arrayToFill: &timing,
            entriesNeededOut: nil
        )
        for index in timing.indices {
            timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, offset)
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, offset)
        }
        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjusted
        )
        return adjusted
    }
}

final class CaptureOutputSessionStore {
    enum StopMatch {
        case active(CaptureSessionLease)
        case draining
        case unmatched
    }

    private let lock = NSLock()
    private var currentSession: CaptureOutputSession?
    private var retiredSessions = [UUID: CaptureOutputSession]()
    private var pendingSessionID: UUID?

    @discardableResult
    func reserve(_ sessionID: UUID) -> Bool {
        lock.withLock {
            guard currentSession == nil, retiredSessions.isEmpty, pendingSessionID == nil else {
                return false
            }
            pendingSessionID = sessionID
            return true
        }
    }

    func cancelReservation(_ sessionID: UUID) {
        lock.withLock {
            if pendingSessionID == sessionID { pendingSessionID = nil }
        }
    }

    @discardableResult
    func install(_ session: CaptureOutputSession) -> Bool {
        lock.withLock {
            guard currentSession == nil, retiredSessions.isEmpty else { return false }
            if let pendingSessionID, pendingSessionID != session.id { return false }
            pendingSessionID = nil
            currentSession = session
            return true
        }
    }

    func session(for stream: AnyObject) -> CaptureOutputSession? {
        lock.withLock {
            guard currentSession?.owns(stream: stream) == true else { return nil }
            return currentSession
        }
    }

    func activeSession() -> CaptureOutputSession? {
        lock.withLock { currentSession }
    }

    func acquire(for stream: AnyObject) -> CaptureSessionLease? {
        lock.withLock {
            guard currentSession?.owns(stream: stream) == true else { return nil }
            return currentSession?.acquire()
        }
    }

    func acquire(_ session: CaptureOutputSession) -> CaptureSessionLease? {
        lock.withLock {
            guard currentSession === session else { return nil }
            return session.acquire()
        }
    }

    func matchForStop(from stream: AnyObject) -> StopMatch {
        lock.withLock {
            if currentSession?.owns(stream: stream) == true,
               let lease = currentSession?.acquire() {
                return .active(lease)
            }
            if retiredSessions.values.contains(where: { $0.owns(stream: stream) }) {
                return .draining
            }
            return .unmatched
        }
    }

    @discardableResult
    func deactivate(
        _ session: CaptureOutputSession,
        onDrained: @escaping () -> Void = {}
    ) -> Bool {
        let shouldComplete = lock.withLock { () -> Bool? in
            guard currentSession === session else { return nil }
            retiredSessions[session.id] = session
            currentSession = nil
            return session.beginDraining(onDrained)
        }
        guard let shouldComplete else { return false }
        if shouldComplete { onDrained() }
        return true
    }

    func release(_ session: CaptureOutputSession) {
        lock.withLock { retiredSessions[session.id] = nil }
    }
}

final class CaptureOutputCore {
    typealias SessionHandler = (CaptureOutputSession) -> Void

    private let store: CaptureOutputSessionStore
    private let failureHandler: SessionHandler
    private let stopHandler: SessionHandler
    private let presenterReadyHandler: SessionHandler

    init(
        store: CaptureOutputSessionStore,
        failureHandler: @escaping SessionHandler,
        stopHandler: @escaping SessionHandler,
        presenterReadyHandler: @escaping SessionHandler = { _ in }
    ) {
        self.store = store
        self.failureHandler = failureHandler
        self.stopHandler = stopHandler
        self.presenterReadyHandler = presenterReadyHandler
    }

    func handleSample(
        from stream: AnyObject,
        sampleBuffer: CMSampleBuffer,
        kind: CaptureSampleKind,
        now: Date = Date(),
        afterLeaseAcquired: () -> Void = {}
    ) -> CaptureSampleResult {
        guard let lease = store.acquire(for: stream) else { return .rejected }
        defer { lease.release() }
        afterLeaseAcquired()
        let outcome = lease.session.process(sampleBuffer, kind: kind, now: now)
        if outcome.needsPresenterReady { presenterReadyHandler(lease.session) }
        if outcome.result == .failed {
            _ = store.deactivate(lease.session) { [failureHandler] in
                lease.session.releaseStandaloneAudioResources()
                failureHandler(lease.session)
            }
        }
        return outcome.result
    }

    func handleStop(
        from stream: AnyObject,
        afterLeaseAcquired: () -> Void = {}
    ) -> Bool {
        switch store.matchForStop(from: stream) {
        case .draining:
            return true
        case .unmatched:
            return false
        case .active(let lease):
            defer { lease.release() }
            afterLeaseAcquired()
            return store.deactivate(lease.session) { [stopHandler] in
                lease.session.releaseStandaloneAudioResources()
                stopHandler(lease.session)
            }
        }
    }

    func handleStartFailure(
        _ session: CaptureOutputSession,
        onDrained: @escaping SessionHandler
    ) -> Bool {
        store.deactivate(session) {
            session.releaseStandaloneAudioResources()
            onDrained(session)
        }
    }

    func handlePresenterStarted(from stream: AnyObject) -> CaptureOutputSession? {
        guard let lease = store.acquire(for: stream) else { return nil }
        defer { lease.release() }
        lease.session.presenterDidStart()
        return lease.session
    }

    func handlePresenterStopped(from stream: AnyObject) -> CaptureOutputSession? {
        guard let lease = store.acquire(for: stream) else { return nil }
        defer { lease.release() }
        lease.session.presenterDidStop()
        return lease.session
    }

    func markPresenterReady(_ session: CaptureOutputSession) {
        guard let lease = store.acquire(session) else { return }
        defer { lease.release() }
        session.markPresenterReady()
    }
}

final class CaptureStreamCallbackAdapter {
    private let core: CaptureOutputCore

    init(core: CaptureOutputCore) {
        self.core = core
    }

    func handleSample(
        from stream: AnyObject,
        sampleBuffer: CMSampleBuffer,
        kind: CaptureSampleKind
    ) -> CaptureSampleResult {
        core.handleSample(from: stream, sampleBuffer: sampleBuffer, kind: kind)
    }

    func handleStop(from stream: AnyObject) -> Bool {
        core.handleStop(from: stream)
    }
}
