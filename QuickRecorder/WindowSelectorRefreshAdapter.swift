import Foundation

enum WindowSelectorRefreshError: Error, Equatable {
    case timedOut
    case permissionDenied
    case selectedTargetUnavailable
    case unavailable(String)

    var userMessage: String {
        switch self {
        case .timedOut:
            return "Window refresh timed out. Please try again."
        case .permissionDenied:
            return "Screen recording access is required to refresh windows."
        case .selectedTargetUnavailable:
            return "The selected window is no longer available. Select a window and try again."
        case .unavailable:
            return "Window refresh failed. Please try again."
        }
    }
}

struct WindowSelectorContentAccessPolicy {
    func fetch<Content>(
        preflightAuthorized: Bool,
        provider: (@escaping (Result<Content, ScreenRecordingContentError>) -> Void) -> Void,
        permissionDenied: @escaping () -> Void = {},
        completion: @escaping (Result<Content, ScreenRecordingContentError>) -> Void
    ) {
        guard preflightAuthorized else {
            permissionDenied()
            completion(.failure(.permissionDenied))
            return
        }
        provider { result in
            if case .failure(.permissionDenied) = result {
                permissionDenied()
            }
            completion(result)
        }
    }
}

struct WindowSelectorThumbnailCapturePlan<Item> {
    let captured: [Item]
    let placeholders: [Item]

    static func make(
        windows: [Item],
        captureThumbnails: Bool,
        maximumCaptures: Int
    ) -> Self {
        guard captureThumbnails else {
            return Self(captured: [], placeholders: windows)
        }
        let captureCount = min(max(0, maximumCaptures), windows.count)
        return Self(
            captured: Array(windows.prefix(captureCount)),
            placeholders: Array(windows.dropFirst(captureCount))
        )
    }
}

struct WindowSelectorThumbnailCapturePolicy {
    private static let maximumConcurrentCaptures = 12

    static func plan<Item>(windows: [Item], captureThumbnails: Bool) -> WindowSelectorThumbnailCapturePlan<Item> {
        WindowSelectorThumbnailCapturePlan.make(
            windows: windows,
            captureThumbnails: captureThumbnails,
            maximumCaptures: maximumConcurrentCaptures
        )
    }
}

enum WindowSelectorThumbnailBatchResolution<Value> {
    case pending
    case complete([Value])
}

enum WindowSelectorThumbnailOutcome<Value> {
    case thumbnail(Value)
    case placeholder(Value)

    var value: Value {
        switch self {
        case .thumbnail(let value), .placeholder(let value):
            return value
        }
    }
}

struct WindowSelectorThumbnailBatch<Identifier: Hashable, Value> {
    private var pending = Set<Identifier>()
    private var values = [Value]()

    mutating func register(_ identifier: Identifier) {
        pending.insert(identifier)
    }

    mutating func append(_ value: Value) {
        values.append(value)
    }

    mutating func resolve(
        _ identifier: Identifier,
        outcome: WindowSelectorThumbnailOutcome<Value>
    ) -> WindowSelectorThumbnailBatchResolution<Value>? {
        guard pending.remove(identifier) != nil else { return nil }
        values.append(outcome.value)
        return pending.isEmpty ? .complete(values) : .pending
    }

    func completedValues() -> [Value]? {
        pending.isEmpty ? values : nil
    }

    mutating func removeAll() {
        pending.removeAll()
        values.removeAll()
    }
}

struct WindowSelectorSelectionReconciler {
    static func reconcile<Item, Identifier: Hashable>(
        selected: [Item],
        available: [Item],
        identifier: (Item) -> Identifier
    ) -> [Item]? {
        let availableByIdentifier = Dictionary(
            available.map { (identifier($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var reconciled = [Item]()
        reconciled.reserveCapacity(selected.count)
        for priorSelection in selected {
            guard let current = availableByIdentifier[identifier(priorSelection)] else {
                return nil
            }
            reconciled.append(current)
        }
        return reconciled
    }
}

struct WindowSelectorRefreshResolution<Model, Item> {
    let model: Model
    let selection: [Item]
    let acceptedCandidate: Bool
}

struct WindowSelectorRefreshTransaction {
    static func resolve<Model, Item, Identifier: Hashable>(
        currentModel: Model,
        currentSelection: () -> [Item],
        candidateModel: Model,
        candidateItems: [Item],
        identifier: (Item) -> Identifier
    ) -> WindowSelectorRefreshResolution<Model, Item> {
        let liveSelection = currentSelection()
        guard let reconciledSelection = WindowSelectorSelectionReconciler.reconcile(
            selected: liveSelection,
            available: candidateItems,
            identifier: identifier
        ) else {
            return WindowSelectorRefreshResolution(
                model: candidateModel,
                selection: [],
                acceptedCandidate: false
            )
        }
        return WindowSelectorRefreshResolution(
            model: candidateModel,
            selection: reconciledSelection,
            acceptedCandidate: true
        )
    }
}

struct WindowSelectorRefreshPublication<Snapshot, Model, Item> {
    let snapshot: Snapshot
    let resolution: WindowSelectorRefreshResolution<Model, Item>
}

final class WindowSelectorRefreshPipeline<Snapshot, Model, Item, Identifier: Hashable> {
    typealias Publication = WindowSelectorRefreshPublication<Snapshot, Model, Item>
    typealias Provider = WindowSelectorRefreshAdapter<Snapshot>.Provider

    private let adapter: WindowSelectorRefreshAdapter<Snapshot>
    private let candidateModel: (Snapshot) -> Model
    private let candidateItems: (Snapshot) -> [Item]
    private let identifier: (Item) -> Identifier

    init(
        timeout: TimeInterval = 10,
        workerQueue: DispatchQueue = DispatchQueue(
            label: "dev.clickai.grabrabbit.window-refresh",
            qos: .userInitiated
        ),
        publicationQueue: DispatchQueue = .main,
        timeoutQueue: DispatchQueue = DispatchQueue(
            label: "dev.clickai.grabrabbit.window-refresh-timeout"
        ),
        candidateModel: @escaping (Snapshot) -> Model,
        candidateItems: @escaping (Snapshot) -> [Item],
        identifier: @escaping (Item) -> Identifier
    ) {
        adapter = WindowSelectorRefreshAdapter(
            timeout: timeout,
            workerQueue: workerQueue,
            publicationQueue: publicationQueue,
            timeoutQueue: timeoutQueue
        )
        self.candidateModel = candidateModel
        self.candidateItems = candidateItems
        self.identifier = identifier
    }

    @discardableResult
    func refresh(
        currentModel: @escaping () -> Model,
        currentSelection: @escaping () -> [Item],
        using provider: @escaping Provider,
        started: @escaping () -> Void = {},
        teardownCompletion: @escaping (WindowSelectorRefreshError) -> Void = { _ in },
        publish: @escaping (Result<Publication, WindowSelectorRefreshError>) -> Void
    ) -> WindowSelectorRefreshDisposition {
        adapter.refresh(
            using: provider,
            started: started,
            teardownCompletion: teardownCompletion
        ) { [candidateModel, candidateItems, identifier] result in
            publish(result.map { snapshot in
                let resolution = WindowSelectorRefreshTransaction.resolve(
                    currentModel: currentModel(),
                    currentSelection: currentSelection,
                    candidateModel: candidateModel(snapshot),
                    candidateItems: candidateItems(snapshot),
                    identifier: identifier
                )
                return Publication(snapshot: snapshot, resolution: resolution)
            })
        }
    }

    func cancel() {
        adapter.cancel()
    }
}

struct WindowSelectorRefreshRequest: Equatable {
    let filterUntitledWindows: Bool
    let captureThumbnails: Bool
}

struct WindowSelectorRefreshStatus: Equatable {
    let isReady: Bool
    let isRefreshing: Bool
    let errorMessage: String?
}

struct WindowSelectorControlAvailability: Equatable {
    let canStart: Bool
    let canRefresh: Bool
    let canChangeSelectorOptions: Bool

    init(canStart: Bool, canRefresh: Bool, canChangeSelectorOptions: Bool) {
        self.canStart = canStart
        self.canRefresh = canRefresh
        self.canChangeSelectorOptions = canChangeSelectorOptions
    }

    init(hasSelection: Bool, status: WindowSelectorRefreshStatus) {
        canStart = hasSelection
            && status.isReady
            && !status.isRefreshing
            && status.errorMessage == nil
        canRefresh = !status.isRefreshing
        canChangeSelectorOptions = !status.isRefreshing
    }
}

final class WindowSelectorThumbnailStartRegistry<Stream: AnyObject>: @unchecked Sendable {
    typealias Start = (Stream) async throws -> Void
    typealias Stop = (Stream) async throws -> Void

    private enum Phase: Equatable {
        case starting
        case started
        case stopping
        case stopFailed
    }

    private struct Entry {
        let stream: Stream
        var phase: Phase
        var stopRequested: Bool
    }

    private let lock = NSLock()
    private let startOperation: Start
    private let stopOperation: Stop
    private var entries = [ObjectIdentifier: Entry]()
    private var isStopping = false
    private var stopFailure: Error?
    private var stopFailureObservers = [(Error) -> Void]()
    private var stopCompletions = [() -> Void]()

    init(
        start: @escaping Start,
        stop: @escaping Stop
    ) {
        startOperation = start
        stopOperation = stop
    }

    func start(
        _ stream: Stream,
        failure: @escaping (Error) -> Void
    ) {
        let identifier = ObjectIdentifier(stream)
        lock.lock()
        guard !isStopping, entries[identifier] == nil else {
            lock.unlock()
            return
        }
        entries[identifier] = Entry(
            stream: stream,
            phase: .starting,
            stopRequested: false
        )
        lock.unlock()

        Task { [self, stream] in
            do {
                try await startOperation(stream)
                startFinished(stream, identifier: identifier, error: nil, failure: failure)
            } catch {
                startFinished(stream, identifier: identifier, error: error, failure: failure)
            }
        }
    }

    func stop(_ stream: Stream) {
        let streamToStop: Stream?
        lock.lock()
        streamToStop = requestStopLocked(identifier: ObjectIdentifier(stream))
        lock.unlock()
        if let streamToStop {
            performStop(streamToStop)
        }
    }

    func stopAll(
        onFailure: @escaping (Error) -> Void,
        completion: @escaping () -> Void
    ) {
        var streamsToStop = [Stream]()
        var existingFailure: Error?
        var completions = [() -> Void]()

        lock.lock()
        isStopping = true
        stopFailureObservers.append(onFailure)
        stopCompletions.append(completion)
        existingFailure = stopFailure
        for identifier in Array(entries.keys) {
            if let stream = requestStopLocked(identifier: identifier) {
                streamsToStop.append(stream)
            }
        }
        if entries.isEmpty {
            completions = stopCompletions
            stopCompletions.removeAll()
            stopFailureObservers.removeAll()
        }
        lock.unlock()

        if let existingFailure {
            onFailure(existingFailure)
        }
        streamsToStop.forEach(performStop)
        completions.forEach { $0() }
    }

    func confirmStopped(_ stream: Stream) {
        var completions = [() -> Void]()
        lock.lock()
        entries[ObjectIdentifier(stream)] = nil
        if isStopping, entries.isEmpty {
            completions = stopCompletions
            stopCompletions.removeAll()
            stopFailureObservers.removeAll()
        }
        lock.unlock()
        completions.forEach { $0() }
    }

    var ownedStreamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func startFinished(
        _ stream: Stream,
        identifier: ObjectIdentifier,
        error: Error?,
        failure: @escaping (Error) -> Void
    ) {
        var streamToStop: Stream?
        var completions = [() -> Void]()
        var shouldReportFailure = false
        lock.lock()
        guard var entry = entries[identifier], entry.phase == .starting else {
            lock.unlock()
            return
        }

        if let error {
            entries[identifier] = nil
            if isStopping, entries.isEmpty {
                completions = stopCompletions
                stopCompletions.removeAll()
                stopFailureObservers.removeAll()
            }
            shouldReportFailure = !isStopping
            lock.unlock()
            if shouldReportFailure {
                failure(error)
            }
            completions.forEach { $0() }
            return
        }

        entry.phase = .started
        entries[identifier] = entry
        if entry.stopRequested || isStopping {
            streamToStop = requestStopLocked(identifier: identifier)
        }
        lock.unlock()

        if let streamToStop {
            performStop(streamToStop)
        }
    }

    private func requestStopLocked(identifier: ObjectIdentifier) -> Stream? {
        guard var entry = entries[identifier] else { return nil }
        switch entry.phase {
        case .starting:
            entry.stopRequested = true
            entries[identifier] = entry
            return nil
        case .started:
            entry.phase = .stopping
            entries[identifier] = entry
            return entry.stream
        case .stopping, .stopFailed:
            return nil
        }
    }

    private func performStop(_ stream: Stream) {
        Task { [self, stream] in
            do {
                try await stopOperation(stream)
                confirmStopped(stream)
            } catch {
                stopFailed(stream, error: error)
            }
        }
    }

    private func stopFailed(_ stream: Stream, error: Error) {
        let observers: [(Error) -> Void]
        lock.lock()
        let identifier = ObjectIdentifier(stream)
        guard var entry = entries[identifier], entry.phase == .stopping else {
            lock.unlock()
            return
        }
        entry.phase = .stopFailed
        entries[identifier] = entry
        if stopFailure == nil {
            stopFailure = error
        }
        observers = stopFailureObservers
        lock.unlock()

        observers.forEach { $0(error) }
    }
}

final class WindowSelectorRefreshCoordinator<Request, Snapshot, Model, Item, Identifier: Hashable> {
    typealias Publication = WindowSelectorRefreshPublication<Snapshot, Model, Item>
    typealias Provider = WindowSelectorRefreshAdapter<Snapshot>.Provider
    typealias ProviderFactory = (Request) -> Provider

    private let pipeline: WindowSelectorRefreshPipeline<Snapshot, Model, Item, Identifier>
    private let providerFactory: ProviderFactory
    private let isModelEmpty: (Model) -> Bool

    init(
        timeout: TimeInterval = 10,
        workerQueue: DispatchQueue = DispatchQueue(
            label: "dev.clickai.grabrabbit.window-refresh",
            qos: .userInitiated
        ),
        publicationQueue: DispatchQueue = .main,
        timeoutQueue: DispatchQueue = DispatchQueue(
            label: "dev.clickai.grabrabbit.window-refresh-timeout"
        ),
        candidateModel: @escaping (Snapshot) -> Model,
        candidateItems: @escaping (Snapshot) -> [Item],
        identifier: @escaping (Item) -> Identifier,
        isModelEmpty: @escaping (Model) -> Bool,
        providerFactory: @escaping ProviderFactory
    ) {
        pipeline = WindowSelectorRefreshPipeline(
            timeout: timeout,
            workerQueue: workerQueue,
            publicationQueue: publicationQueue,
            timeoutQueue: timeoutQueue,
            candidateModel: candidateModel,
            candidateItems: candidateItems,
            identifier: identifier
        )
        self.providerFactory = providerFactory
        self.isModelEmpty = isModelEmpty
    }

    @discardableResult
    func refresh(
        request: Request,
        currentModel: @escaping () -> Model,
        currentSelection: @escaping () -> [Item],
        applySnapshot: @escaping (Snapshot) -> Void,
        applyModel: @escaping (Model) -> Void,
        updateSelection: @escaping ([Item]) -> Void,
        publishStatus: @escaping (WindowSelectorRefreshStatus) -> Void
    ) -> WindowSelectorRefreshDisposition {
        let disposition = pipeline.refresh(
            currentModel: currentModel,
            currentSelection: currentSelection,
            using: providerFactory(request),
            started: {
                publishStatus(WindowSelectorRefreshStatus(
                    isReady: false,
                    isRefreshing: true,
                    errorMessage: nil
                ))
            },
            teardownCompletion: { [isModelEmpty] error in
                publishStatus(WindowSelectorRefreshStatus(
                    isReady: !isModelEmpty(currentModel()),
                    isRefreshing: false,
                    errorMessage: error.userMessage
                ))
            }
        ) { [isModelEmpty] result in
            switch result {
            case .success(let publication):
                let resolution = publication.resolution
                applySnapshot(publication.snapshot)
                applyModel(resolution.model)
                updateSelection(resolution.selection)
                publishStatus(WindowSelectorRefreshStatus(
                    isReady: !isModelEmpty(resolution.model),
                    isRefreshing: false,
                    errorMessage: resolution.acceptedCandidate
                        ? nil
                        : WindowSelectorRefreshError.selectedTargetUnavailable.userMessage
                ))
            case .failure(let error):
                publishStatus(WindowSelectorRefreshStatus(
                    isReady: false,
                    isRefreshing: true,
                    errorMessage: error.userMessage
                ))
            }
        }

        return disposition
    }

    func cancel() {
        pipeline.cancel()
    }
}

enum WindowSelectorRefreshDisposition: Equatable {
    case started
    case coalesced
}

final class WindowSelectorRefreshAdapter<Output> {
    typealias Completion = (Result<Output, WindowSelectorRefreshError>) -> Void
    typealias Cancellation = (@escaping () -> Void) -> Void
    typealias Provider = (@escaping Completion) -> Cancellation
    typealias Started = () -> Void
    typealias TeardownCompletion = (WindowSelectorRefreshError) -> Void

    private enum Phase {
        case providing
        case tearingDown
        case publishing
    }

    private struct ActiveRefresh {
        let generation: UInt64
        let timeout: DispatchWorkItem
        let publish: Completion
        let teardownCompletion: TeardownCompletion
        var phase: Phase
        var providerStarted: Bool
        var cancellation: Cancellation?
        var cleanupStarted: Bool
        var cleanupAcknowledged: Bool
        var result: Result<Output, WindowSelectorRefreshError>?
        var failurePublicationFinished: Bool
    }

    private let lock = NSLock()
    private let workerQueue: DispatchQueue
    private let publicationQueue: DispatchQueue
    private let publicationQueueKey = DispatchSpecificKey<Void>()
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
        publicationQueue.setSpecific(key: publicationQueueKey, value: ())
    }

    @discardableResult
    func refresh(
        using provider: @escaping Provider,
        started: @escaping Started = {},
        teardownCompletion: @escaping TeardownCompletion = { _ in },
        publish: @escaping Completion
    ) -> WindowSelectorRefreshDisposition {
        lock.lock()
        if activeRefresh != nil {
            lock.unlock()
            return .coalesced
        }

        generation += 1
        let currentGeneration = generation
        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timedOut), generation: currentGeneration)
        }
        activeRefresh = ActiveRefresh(
            generation: currentGeneration,
            timeout: timeoutWork,
            publish: publish,
            teardownCompletion: teardownCompletion,
            phase: .providing,
            providerStarted: false,
            cancellation: nil,
            cleanupStarted: false,
            cleanupAcknowledged: false,
            result: nil,
            failurePublicationFinished: false
        )
        lock.unlock()

        if DispatchQueue.getSpecific(key: publicationQueueKey) != nil {
            startProviderIfCurrent(provider, started: started, generation: currentGeneration)
        } else {
            publicationQueue.async { [weak self] in
                self?.startProviderIfCurrent(
                    provider,
                    started: started,
                    generation: currentGeneration
                )
            }
        }
        return .started
    }

    private func startProviderIfCurrent(
        _ provider: @escaping Provider,
        started: Started,
        generation: UInt64
    ) {
        lock.lock()
        guard let activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .providing else {
            lock.unlock()
            return
        }
        lock.unlock()

        started()

        lock.lock()
        guard let current = self.activeRefresh,
              current.generation == generation,
              current.phase == .providing else {
            lock.unlock()
            return
        }
        let timeoutWork = current.timeout
        lock.unlock()

        timeoutQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        workerQueue.async { [weak self] in
            guard let self, self.beginProvider(generation: generation) else { return }
            let cancellation = provider { [weak self] result in
                self?.finish(result, generation: generation)
            }
            self.install(cancellation: cancellation, generation: generation)
        }
    }

    private func beginProvider(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .providing else { return false }
        activeRefresh.providerStarted = true
        self.activeRefresh = activeRefresh
        return true
    }

    func cancel() {
        var cancellation: Cancellation?
        var completeWithoutProvider = false
        lock.lock()
        guard var activeRefresh else {
            lock.unlock()
            return
        }
        activeRefresh.timeout.cancel()
        switch activeRefresh.phase {
        case .publishing:
            self.activeRefresh = nil
        case .providing, .tearingDown:
            activeRefresh.phase = .tearingDown
            activeRefresh.result = nil
            if !activeRefresh.cleanupStarted {
                if let installedCancellation = activeRefresh.cancellation {
                    activeRefresh.cleanupStarted = true
                    cancellation = installedCancellation
                } else if !activeRefresh.providerStarted {
                    activeRefresh.cleanupStarted = true
                    activeRefresh.cleanupAcknowledged = true
                    completeWithoutProvider = true
                }
            }
            self.activeRefresh = activeRefresh
        }
        lock.unlock()

        if let cancellation {
            cancellation { [weak self] in
                self?.cleanupFinished(generation: activeRefresh.generation)
            }
        } else if completeWithoutProvider {
            cleanupFinished(generation: activeRefresh.generation)
        }
    }

    private func install(cancellation: @escaping Cancellation, generation: UInt64) {
        var cleanup: Cancellation?
        var isStale = false
        lock.lock()
        guard var activeRefresh, activeRefresh.generation == generation else {
            isStale = true
            lock.unlock()
            cancellation {}
            return
        }
        switch activeRefresh.phase {
        case .providing:
            activeRefresh.cancellation = cancellation
        case .tearingDown:
            activeRefresh.cancellation = cancellation
            if !activeRefresh.cleanupStarted {
                activeRefresh.cleanupStarted = true
                cleanup = cancellation
            }
        case .publishing:
            isStale = true
        }
        self.activeRefresh = activeRefresh
        lock.unlock()

        if let cleanup {
            cleanup { [weak self] in
                self?.cleanupFinished(generation: generation)
            }
        } else if isStale {
            cancellation {}
        }
    }

    private func finish(
        _ result: Result<Output, WindowSelectorRefreshError>,
        generation: UInt64
    ) {
        var cancellation: Cancellation?
        var publishFailure = false
        var completeWithoutProvider = false
        lock.lock()
        guard var activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .providing else {
            lock.unlock()
            return
        }
        activeRefresh.phase = .tearingDown
        activeRefresh.result = result
        if case .failure = result {
            publishFailure = true
        }
        if let installedCancellation = activeRefresh.cancellation {
            activeRefresh.cleanupStarted = true
            cancellation = installedCancellation
        } else if !activeRefresh.providerStarted {
            activeRefresh.cleanupStarted = true
            activeRefresh.cleanupAcknowledged = true
            completeWithoutProvider = true
        }
        self.activeRefresh = activeRefresh
        lock.unlock()

        activeRefresh.timeout.cancel()
        if publishFailure {
            publicationQueue.async { [weak self] in
                self?.publishFailureIfCurrent(generation: generation)
            }
        }
        if let cancellation {
            cancellation { [weak self] in
                self?.cleanupFinished(generation: generation)
            }
        } else if completeWithoutProvider {
            cleanupFinished(generation: generation)
        }
    }

    private func publishFailureIfCurrent(generation: UInt64) {
        let error: WindowSelectorRefreshError
        let publish: Completion
        lock.lock()
        guard let activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .tearingDown,
              case .failure(let currentError) = activeRefresh.result,
              !activeRefresh.failurePublicationFinished else {
            lock.unlock()
            return
        }
        error = currentError
        publish = activeRefresh.publish
        lock.unlock()

        publish(.failure(error))

        lock.lock()
        guard var current = self.activeRefresh,
              current.generation == generation,
              current.phase == .tearingDown,
              case .failure = current.result else {
            lock.unlock()
            return
        }
        current.failurePublicationFinished = true
        self.activeRefresh = current
        lock.unlock()
        advanceAfterTeardown(generation: generation)
    }

    private func cleanupFinished(generation: UInt64) {
        lock.lock()
        guard var activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .tearingDown,
              !activeRefresh.cleanupAcknowledged else {
            lock.unlock()
            return
        }
        activeRefresh.cleanupAcknowledged = true
        activeRefresh.cancellation = nil
        self.activeRefresh = activeRefresh
        lock.unlock()
        advanceAfterTeardown(generation: generation)
    }

    private func advanceAfterTeardown(generation: UInt64) {
        var success: Result<Output, WindowSelectorRefreshError>?
        var completeFailure = false
        lock.lock()
        guard var activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .tearingDown,
              activeRefresh.cleanupAcknowledged else {
            lock.unlock()
            return
        }
        switch activeRefresh.result {
        case .success:
            success = activeRefresh.result
            activeRefresh.phase = .publishing
        case .failure:
            guard activeRefresh.failurePublicationFinished else {
                lock.unlock()
                return
            }
            completeFailure = true
            activeRefresh.phase = .publishing
        case nil:
            self.activeRefresh = nil
            lock.unlock()
            return
        }
        self.activeRefresh = activeRefresh
        lock.unlock()

        if let success {
            publicationQueue.async { [weak self] in
                self?.publishSuccessIfCurrent(success, generation: generation)
            }
        } else if completeFailure {
            publicationQueue.async { [weak self] in
                self?.finishFailureTeardownIfCurrent(generation: generation)
            }
        }
    }

    private func publishSuccessIfCurrent(
        _ result: Result<Output, WindowSelectorRefreshError>,
        generation: UInt64
    ) {
        let publish: Completion
        lock.lock()
        guard let activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .publishing else {
            lock.unlock()
            return
        }
        publish = activeRefresh.publish
        lock.unlock()

        publish(result)

        lock.lock()
        if self.activeRefresh?.generation == generation {
            self.activeRefresh = nil
        }
        lock.unlock()
    }

    private func finishFailureTeardownIfCurrent(generation: UInt64) {
        let error: WindowSelectorRefreshError
        let teardownCompletion: TeardownCompletion
        lock.lock()
        guard let activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .publishing,
              case .failure(let currentError) = activeRefresh.result else {
            lock.unlock()
            return
        }
        error = currentError
        teardownCompletion = activeRefresh.teardownCompletion
        lock.unlock()

        teardownCompletion(error)

        lock.lock()
        if self.activeRefresh?.generation == generation {
            self.activeRefresh = nil
        }
        lock.unlock()
    }

    deinit {
        cancel()
    }
}
