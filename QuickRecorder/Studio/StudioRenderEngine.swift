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
    // Another render was still in flight. Kept separate from the rate guard so a
    // later telemetry pass can tell contention apart from ordinary early triggers.
    case skippedOverlap
    case rejectedTimestamp
    case skippedWriterNotReady
    case stopped(StudioStopReason)
}

enum StudioAudioOutcome: Equatable {
    case appended(CMTime)
    case skippedPaused
    case skippedStopped
    case invalidSample
    // Another buffer on this same track was still in flight.
    case skippedOverlap
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
    private var isVideoRenderInFlight = false
    private var tracksInFlight = Set<StudioAudioTrack>()

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
    /// Drive this from one serial queue. That is the intended shape and the only one
    /// the compositor is written for, since it is not required to be reentrant.
    ///
    /// The in-flight guard is the backstop for when that is not honoured. A render
    /// holds a reservation from admission until it appends or gives up, and a second
    /// call arriving in that window is refused with `skippedOverlap` rather than
    /// being allowed to reserve on top of it. Without that refusal a slow composite
    /// could be overtaken by a later frame and then roll the guard state back to its
    /// own stale values on the way out, which would both write frames out of order
    /// and disarm the rate and monotonic guards for everything after.
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
        commit(reservation)
        return .appended(presentationTime)
    }

    // The admission guards, the state they advance, and the in-flight flag move
    // together under one lock. The reservation carries both the state to put back if
    // this frame never gets appended and the values this call wrote, so the rollback
    // can tell whether it is still the owner of that state.
    private struct StudioVideoReservation {
        let previousSeconds: Double
        let previousNanoseconds: UInt64?
        let committedSeconds: Double
        let committedNanoseconds: UInt64
    }

    private enum StudioVideoAdmission {
        case reserved(StudioVideoReservation)
        case refused(StudioRenderOutcome)
    }

    private enum StudioAudioAdmission {
        case reserved(previousSeconds: Double)
        case refused(StudioAudioOutcome)
    }

    private func reserveVideoAdmission(
        seconds: Double,
        at now: UInt64
    ) -> StudioVideoAdmission {
        stateLock.withLock {
            guard !isVideoRenderInFlight else { return .refused(.skippedOverlap) }
            if let lastVideoNanoseconds,
               now >= lastVideoNanoseconds,
               Double(now - lastVideoNanoseconds) / 1_000_000_000
                   < configuration.frameInterval * Self.rateGuardFraction {
                return .refused(.skippedRateGuard)
            }
            guard seconds > lastVideoSeconds else { return .refused(.rejectedTimestamp) }
            let reservation = StudioVideoReservation(
                previousSeconds: lastVideoSeconds,
                previousNanoseconds: lastVideoNanoseconds,
                committedSeconds: seconds,
                committedNanoseconds: now
            )
            lastVideoSeconds = seconds
            lastVideoNanoseconds = now
            isVideoRenderInFlight = true
            return .reserved(reservation)
        }
    }

    private func commit(_ reservation: StudioVideoReservation) {
        stateLock.withLock { isVideoRenderInFlight = false }
    }

    // Defense in depth: only put the old values back if this call's values are still
    // the ones on record, so a rollback can never undo somebody else's frame.
    private func release(
        _ reservation: StudioVideoReservation,
        returning outcome: StudioRenderOutcome
    ) -> StudioRenderOutcome {
        stateLock.withLock {
            isVideoRenderInFlight = false
            guard lastVideoSeconds == reservation.committedSeconds,
                  lastVideoNanoseconds == reservation.committedNanoseconds else { return }
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

        // The per-track guard is reserved the same way the video guard is, including
        // the in-flight refusal. Audio needs it more than video does: there is no
        // rate guard here, so nothing else would keep two callbacks on one track from
        // interleaving.
        let seconds = timeline.activeElapsedSeconds(at: timeline.nowNanoseconds)
        let admission = stateLock.withLock { () -> StudioAudioAdmission in
            guard !tracksInFlight.contains(track) else { return .refused(.skippedOverlap) }
            let previous = lastAudioSeconds[track] ?? -.infinity
            guard seconds > previous else { return .refused(.rejectedTimestamp) }
            lastAudioSeconds[track] = seconds
            tracksInFlight.insert(track)
            return .reserved(previousSeconds: previous)
        }
        let previousSeconds: Double
        switch admission {
        case .refused(let outcome): return outcome
        case .reserved(let previous): previousSeconds = previous
        }

        func release(_ outcome: StudioAudioOutcome) -> StudioAudioOutcome {
            stateLock.withLock {
                tracksInFlight.remove(track)
                guard lastAudioSeconds[track] == seconds else { return }
                lastAudioSeconds[track] = previousSeconds
            }
            return outcome
        }
        func commit() {
            stateLock.withLock { tracksInFlight.remove(track) }
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
        commit()
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
