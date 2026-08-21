import Foundation

// The fixed-clock cadence ruled on in issue #48: the render loop is driven by a
// repeating timer, never by camera or window callbacks.
enum StudioFixedClockSchedule {
    // A single millisecond of slack lets the kernel coalesce the timer without
    // letting the cadence drift away from the requested frame rate.
    static let leeway = DispatchTimeInterval.milliseconds(1)

    static func interval(framesPerSecond: Int) -> TimeInterval {
        1.0 / Double(max(1, framesPerSecond))
    }
}

// The render engine's trigger seam. Production drives it from a dispatch timer;
// tests drive it by hand so cadence assertions need no wall-clock sleeps.
protocol StudioRenderTriggerSource: AnyObject {
    func start(interval: TimeInterval, handler: @escaping () -> Void)
    func stop()
}

final class StudioFixedClockTriggerSource: StudioRenderTriggerSource {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(interval: TimeInterval, handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: interval,
            leeway: StudioFixedClockSchedule.leeway
        )
        timer.setEventHandler(handler: handler)
        let previous = lock.withLock { () -> DispatchSourceTimer? in
            defer { self.timer = timer }
            return self.timer
        }
        previous?.cancel()
        timer.resume()
    }

    func stop() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
    }

    deinit { stop() }
}
