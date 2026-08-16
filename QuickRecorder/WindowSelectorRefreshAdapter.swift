import Foundation

enum WindowSelectorRefreshError: Error, Equatable {
    case timedOut
    case unavailable(String)

    var userMessage: String {
        switch self {
        case .timedOut:
            return "Window refresh timed out. Please try again."
        case .unavailable:
            return "Window refresh failed. Please try again."
        }
    }
}

enum WindowSelectorRefreshDisposition: Equatable {
    case started
    case coalesced
}

final class WindowSelectorRefreshAdapter<Output> {
    typealias Completion = (Result<Output, WindowSelectorRefreshError>) -> Void
    typealias Cancellation = () -> Void
    typealias Provider = (@escaping Completion) -> Cancellation

    private struct ActiveRefresh {
        let generation: UInt64
        let timeout: DispatchWorkItem
        var cancellation: Cancellation?
    }

    private let lock = NSLock()
    private let workerQueue: DispatchQueue
    private let publicationQueue: DispatchQueue
    private let timeoutQueue: DispatchQueue
    private let timeout: TimeInterval
    private var generation: UInt64 = 0
    private var activeRefresh: ActiveRefresh?

    init(
        timeout: TimeInterval = 10,
        workerQueue: DispatchQueue = DispatchQueue(label: "dev.clickai.grabrabbit.window-refresh", qos: .userInitiated),
        publicationQueue: DispatchQueue = .main,
        timeoutQueue: DispatchQueue = DispatchQueue(label: "dev.clickai.grabrabbit.window-refresh-timeout")
    ) {
        self.timeout = timeout
        self.workerQueue = workerQueue
        self.publicationQueue = publicationQueue
        self.timeoutQueue = timeoutQueue
    }

    @discardableResult
    func refresh(
        using provider: @escaping Provider,
        publish: @escaping Completion
    ) -> WindowSelectorRefreshDisposition {
        lock.lock()
        guard activeRefresh == nil else {
            lock.unlock()
            return .coalesced
        }

        generation += 1
        let currentGeneration = generation
        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timedOut), generation: currentGeneration, publish: publish)
        }
        activeRefresh = ActiveRefresh(
            generation: currentGeneration,
            timeout: timeoutWork,
            cancellation: nil
        )
        lock.unlock()

        timeoutQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        workerQueue.async { [weak self] in
            guard let self, self.isActive(generation: currentGeneration) else { return }
            let cancellation = provider { [weak self] result in
                self?.finish(result, generation: currentGeneration, publish: publish)
            }
            self.install(cancellation: cancellation, generation: currentGeneration)
        }
        return .started
    }

    private func isActive(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRefresh?.generation == generation
    }

    func cancel() {
        lock.lock()
        guard let activeRefresh else {
            lock.unlock()
            return
        }
        self.activeRefresh = nil
        lock.unlock()

        activeRefresh.timeout.cancel()
        activeRefresh.cancellation?()
    }

    private func install(cancellation: @escaping Cancellation, generation: UInt64) {
        lock.lock()
        guard var activeRefresh, activeRefresh.generation == generation else {
            lock.unlock()
            cancellation()
            return
        }
        activeRefresh.cancellation = cancellation
        self.activeRefresh = activeRefresh
        lock.unlock()
    }

    private func finish(
        _ result: Result<Output, WindowSelectorRefreshError>,
        generation: UInt64,
        publish: @escaping Completion
    ) {
        lock.lock()
        guard let activeRefresh, activeRefresh.generation == generation else {
            lock.unlock()
            return
        }
        self.activeRefresh = nil
        lock.unlock()

        activeRefresh.timeout.cancel()
        activeRefresh.cancellation?()
        publicationQueue.async {
            publish(result)
        }
    }

    deinit {
        cancel()
    }
}
