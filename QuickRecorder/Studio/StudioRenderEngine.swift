import CoreMedia
import CoreVideo
import Foundation

struct StudioRenderConfiguration: Equatable {
    let canvas: StudioCanvas
    let framesPerSecond: Int
    let requiresWindow: Bool

    init(canvas: StudioCanvas, framesPerSecond: Int, requiresWindow: Bool) {
        self.canvas = canvas
        self.framesPerSecond = max(1, framesPerSecond)
        self.requiresWindow = requiresWindow
    }

    var frameInterval: TimeInterval {
        StudioFixedClockSchedule.interval(framesPerSecond: framesPerSecond)
    }
}

enum StudioStopReason: Equatable {
    case cameraIngressFailed(String)
    case windowIngressFailed(String)
    case privacySentinelRendered(pixels: Int)
    case writerBufferUnavailable(String)
    case videoAppendFailed
    case requested(String)
}

enum StudioRenderOutcome: Equatable {
    case appended(CMTime)
    case skippedPaused
    case skippedStopped
    case skippedMissingCamera
    case skippedMissingWindow
    case skippedRateGuard
    case rejectedTimestamp
    case skippedWriterNotReady
    case stopped(StudioStopReason)
}

enum StudioAudioOutcome: Equatable {
    case appended(CMTime)
    case skippedPaused
    case skippedStopped
    case invalidSample
    case rejectedTimestamp
    case retimeFailed
    case skippedWriterNotReady
    case appendFailed
}

// The fixed-clock render engine ruled on in issue #48. A repeating trigger drives
// every output frame; camera and window callbacks only refresh a latest-frame cache.
// The engine is self-contained: it owns its timeline, cache, compositor, and writer
// surface, and no existing recording path calls into it.
final class StudioRenderEngine {
    // A trigger that fires early by more than a quarter of the frame interval is
    // dropped, which keeps a coalesced timer burst from doubling up output frames.
    static let rateGuardFraction = 0.75

    let configuration: StudioRenderConfiguration
    let timeline: StudioTimeline

    private let cache: StudioFrameCache
    private let ingress: StudioFrameIngress
    private let compositor: StudioCompositing
    private let writerSurface: StudioWriterSurface
    private let triggerSource: StudioRenderTriggerSource

    private let stateLock = NSLock()
    private var storedStopReason: StudioStopReason?
    private var lastVideoSeconds = -Double.infinity
    private var lastVideoNanoseconds: UInt64?
    private var lastAudioSeconds: [StudioAudioTrack: Double] = [:]

    init(
        configuration: StudioRenderConfiguration,
        clock: StudioClock,
        compositor: StudioCompositing,
        writerSurface: StudioWriterSurface,
        triggerSource: StudioRenderTriggerSource,
        cache: StudioFrameCache = StudioFrameCache(),
        ingress: StudioFrameIngress = StudioFrameIngress()
    ) {
        self.configuration = configuration
        timeline = StudioTimeline(clock: clock)
        self.compositor = compositor
        self.writerSurface = writerSurface
        self.triggerSource = triggerSource
        self.cache = cache
        self.ingress = ingress
        for track in StudioAudioTrack.allCases { lastAudioSeconds[track] = -.infinity }
    }

    var stopReason: StudioStopReason? {
        stateLock.withLock { storedStopReason }
    }

    var isPaused: Bool { timeline.isPaused }

    func start() {
        triggerSource.start(interval: configuration.frameInterval) { [weak self] in
            _ = self?.renderOnce()
        }
    }

    func stop(reason: StudioStopReason? = nil) {
        triggerSource.stop()
        if let reason { requestStop(reason) }
    }

    func setPaused(_ shouldPause: Bool) {
        timeline.setPaused(shouldPause)
    }

    // MARK: - Ingress

    func receiveCamera(_ sample: CMSampleBuffer) {
        guard stopReason == nil, sample.isValid else { return }
        do {
            let frame = try ingress.makeCameraFrame(
                from: sample,
                arrivalNanoseconds: timeline.nowNanoseconds
            )
            cache.storeCamera(frame)
        } catch {
            requestStop(.cameraIngressFailed(String(describing: error)))
        }
    }

    func receiveWindow(_ sample: CMSampleBuffer) {
        guard stopReason == nil, sample.isValid else { return }
        do {
            let frame = try ingress.makeWindowFrame(
                from: sample,
                arrivalNanoseconds: timeline.nowNanoseconds
            )
            cache.storeWindow(frame)
        } catch {
            requestStop(.windowIngressFailed(String(describing: error)))
        }
    }

    // MARK: - Render

    /// Composites and writes one frame.
    ///
    /// Admission, meaning the rate guard and the monotonic timestamp guard, is
    /// checked and reserved in one locked step before the composite, and rolled back
    /// under the same lock on any path that does not append. Two overlapping calls
    /// therefore cannot both pass admission and reach the writer out of order.
    /// Driving this from one serial queue is still the intended shape, because the
    /// compositor is not required to be reentrant.
    @discardableResult
    func renderOnce() -> StudioRenderOutcome {
        guard stopReason == nil else { return .skippedStopped }
        guard !timeline.isPaused else { return .skippedPaused }

        let now = timeline.nowNanoseconds
        let snapshot = cache.snapshot()
        guard let camera = snapshot.camera else { return .skippedMissingCamera }
        guard !configuration.requiresWindow || snapshot.window != nil else {
            return .skippedMissingWindow
        }

        let seconds = timeline.activeElapsedSeconds(at: now)
        let reservation: StudioVideoReservation
        switch reserveVideoAdmission(seconds: seconds, at: now) {
        case .refused(let outcome): return outcome
        case .reserved(let reserved): reservation = reserved
        }

        guard writerSurface.isReadyForVideo else {
            return release(reservation, returning: .skippedWriterNotReady)
        }

        let outputBuffer: CVPixelBuffer
        do {
            outputBuffer = try writerSurface.makeOutputPixelBuffer()
        } catch {
            return release(
                reservation,
                returning: stopAndReport(.writerBufferUnavailable(String(describing: error)))
            )
        }

        compositor.compose(
            camera: camera.pixelBuffer,
            window: snapshot.window?.pixelBuffer,
            into: outputBuffer
        )

        // Fail closed a second time: the sanitizer runs at ingress, and the frame
        // that is actually about to be written is scanned again before it leaves.
        let renderedMarkers = StudioPrivacySentinel.countMarkerPixels(in: outputBuffer)
        guard renderedMarkers == 0 else {
            return release(
                reservation,
                returning: stopAndReport(.privacySentinelRendered(pixels: renderedMarkers))
            )
        }

        let presentationTime = StudioTimeline.presentationTime(seconds: seconds)
        guard writerSurface.appendVideo(outputBuffer, at: presentationTime) else {
            return release(reservation, returning: stopAndReport(.videoAppendFailed))
        }
        return .appended(presentationTime)
    }

    // The admission guards and the state they advance are one step, so a second
    // caller cannot slip past the guards while the first is still compositing. The
    // reservation carries the state to put back if this frame never gets appended.
    private struct StudioVideoReservation {
        let previousSeconds: Double
        let previousNanoseconds: UInt64?
    }

    private enum StudioVideoAdmission {
        case reserved(StudioVideoReservation)
        case refused(StudioRenderOutcome)
    }

    private func reserveVideoAdmission(
        seconds: Double,
        at now: UInt64
    ) -> StudioVideoAdmission {
        stateLock.withLock {
            if let lastVideoNanoseconds,
               now >= lastVideoNanoseconds,
               Double(now - lastVideoNanoseconds) / 1_000_000_000
                   < configuration.frameInterval * Self.rateGuardFraction {
                return .refused(.skippedRateGuard)
            }
            guard seconds > lastVideoSeconds else { return .refused(.rejectedTimestamp) }
            let reservation = StudioVideoReservation(
                previousSeconds: lastVideoSeconds,
                previousNanoseconds: lastVideoNanoseconds
            )
            lastVideoSeconds = seconds
            lastVideoNanoseconds = now
            return .reserved(reservation)
        }
    }

    private func release(
        _ reservation: StudioVideoReservation,
        returning outcome: StudioRenderOutcome
    ) -> StudioRenderOutcome {
        stateLock.withLock {
            lastVideoSeconds = reservation.previousSeconds
            lastVideoNanoseconds = reservation.previousNanoseconds
        }
        return outcome
    }

    // MARK: - Audio

    @discardableResult
    func receiveAudio(_ sample: CMSampleBuffer, track: StudioAudioTrack) -> StudioAudioOutcome {
        guard stopReason == nil else { return .skippedStopped }
        guard !timeline.isPaused else { return .skippedPaused }
        guard sample.isValid else { return .invalidSample }

        // The per-track guard is reserved the same way the video guard is, so two
        // callbacks on one track cannot both be admitted at the same instant.
        let seconds = timeline.activeElapsedSeconds(at: timeline.nowNanoseconds)
        let previousSeconds = stateLock.withLock { () -> Double? in
            let previous = lastAudioSeconds[track] ?? -.infinity
            guard seconds > previous else { return nil }
            lastAudioSeconds[track] = seconds
            return previous
        }
        guard let previousSeconds else { return .rejectedTimestamp }
        func release(_ outcome: StudioAudioOutcome) -> StudioAudioOutcome {
            stateLock.withLock { lastAudioSeconds[track] = previousSeconds }
            return outcome
        }
        guard writerSurface.isReady(for: track) else {
            return release(.skippedWriterNotReady)
        }
        guard let retimed = StudioAudioRetimer.retime(sample, toSeconds: seconds) else {
            return release(.retimeFailed)
        }
        guard writerSurface.appendAudio(retimed, to: track) else {
            return release(.appendFailed)
        }
        return .appended(retimed.presentationTimeStamp)
    }

    // MARK: - Stop

    private func requestStop(_ reason: StudioStopReason) {
        stateLock.withLock {
            if storedStopReason == nil { storedStopReason = reason }
        }
        triggerSource.stop()
    }

    private func stopAndReport(_ reason: StudioStopReason) -> StudioRenderOutcome {
        requestStop(reason)
        return .stopped(stateLock.withLock { storedStopReason } ?? reason)
    }
}
