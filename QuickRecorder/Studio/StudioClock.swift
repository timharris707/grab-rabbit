import CoreMedia
import Foundation

// The studio render engine reads elapsed time only through this seam so tests can
// advance the clock directly instead of sleeping on the wall clock.
protocol StudioClock: AnyObject {
    var nowNanoseconds: UInt64 { get }
}

final class StudioMonotonicClock: StudioClock {
    var nowNanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }
}

// One monotonic wall clock stamps every studio track. Paused time is accumulated
// and subtracted, so a pause never reaches an output presentation timestamp and
// the timeline never moves backwards across a pause/resume pair.
final class StudioTimeline {
    static let timescale: CMTimeScale = 60_000

    private let clock: StudioClock
    private let lock = NSLock()
    private let startNanoseconds: UInt64
    private var accumulatedPauseNanoseconds: UInt64 = 0
    private var pauseStartedNanoseconds: UInt64?

    init(clock: StudioClock) {
        self.clock = clock
        startNanoseconds = clock.nowNanoseconds
    }

    var isPaused: Bool {
        lock.withLock { pauseStartedNanoseconds != nil }
    }

    var nowNanoseconds: UInt64 { clock.nowNanoseconds }

    // Returns true when the pause state actually changed.
    @discardableResult
    func setPaused(_ shouldPause: Bool) -> Bool {
        let now = clock.nowNanoseconds
        return lock.withLock {
            guard shouldPause != (pauseStartedNanoseconds != nil) else { return false }
            if shouldPause {
                pauseStartedNanoseconds = now
            } else {
                if let started = pauseStartedNanoseconds, now > started {
                    accumulatedPauseNanoseconds += now - started
                }
                pauseStartedNanoseconds = nil
            }
            return true
        }
    }

    func activeElapsedSeconds(at now: UInt64) -> Double {
        let pausedNanoseconds = lock.withLock { () -> UInt64 in
            let current = pauseStartedNanoseconds.map { now > $0 ? now - $0 : 0 } ?? 0
            return accumulatedPauseNanoseconds + current
        }
        guard now > startNanoseconds else { return 0 }
        let elapsed = now - startNanoseconds
        guard elapsed > pausedNanoseconds else { return 0 }
        return Double(elapsed - pausedNanoseconds) / 1_000_000_000
    }

    func activeElapsedSeconds() -> Double {
        activeElapsedSeconds(at: clock.nowNanoseconds)
    }

    static func presentationTime(seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }
}
