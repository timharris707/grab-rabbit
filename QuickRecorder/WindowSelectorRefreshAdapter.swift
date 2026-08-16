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
        completion: @escaping (Result<Content, ScreenRecordingContentError>) -> Void
    ) {
        guard preflightAuthorized else {
            completion(.failure(.permissionDenied))
            return
        }
        provider(completion)
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
        publish: @escaping (Result<Publication, WindowSelectorRefreshError>) -> Void
    ) -> WindowSelectorRefreshDisposition {
        adapter.refresh(using: provider) { [candidateModel, candidateItems, identifier] result in
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

final class WindowSelectorThumbnailStartRegistry<Stream: AnyObject>: @unchecked Sendable {
    typealias Start = (Stream) async throws -> Void
    typealias Stop = (Stream) -> Void

    private let lock = NSLock()
    private let startOperation: Start
    private let stopOperation: Stop
    private var tasks = [ObjectIdentifier: Task<Void, Never>]()
    private var isCancelled = false

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
        guard !isCancelled else {
            lock.unlock()
            stopOperation(stream)
            return
        }
        let task = Task { [self, stream] in
            do {
                try Task.checkCancellation()
                try await startOperation(stream)
                finish(stream, identifier: identifier, error: nil, failure: failure)
            } catch {
                finish(stream, identifier: identifier, error: error, failure: failure)
            }
        }
        tasks[identifier] = task
        lock.unlock()
    }

    func cancelAll(_ streams: [Stream]) {
        lock.lock()
        isCancelled = true
        let activeTasks = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()

        activeTasks.forEach { $0.cancel() }
        streams.forEach(stopOperation)
    }

    private func finish(
        _ stream: Stream,
        identifier: ObjectIdentifier,
        error: Error?,
        failure: @escaping (Error) -> Void
    ) {
        lock.lock()
        tasks[identifier] = nil
        let wasCancelled = isCancelled
        lock.unlock()

        if wasCancelled {
            stopOperation(stream)
        } else if let error {
            failure(error)
        }
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
            using: providerFactory(request)
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
                    isReady: !isModelEmpty(currentModel()),
                    isRefreshing: false,
                    errorMessage: error.userMessage
                ))
            }
        }

        if disposition == .started {
            publishStatus(WindowSelectorRefreshStatus(
                isReady: false,
                isRefreshing: true,
                errorMessage: nil
            ))
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
    typealias Cancellation = () -> Void
    typealias Provider = (@escaping Completion) -> Cancellation

    private enum Phase {
        case providing
        case publishing
    }

    private struct ActiveRefresh {
        let generation: UInt64
        let timeout: DispatchWorkItem
        var phase: Phase
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
        if activeRefresh != nil {
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
            phase: .providing,
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
        return activeRefresh?.generation == generation && activeRefresh?.phase == .providing
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
        guard var activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .providing else {
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
        guard var activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .providing else {
            lock.unlock()
            return
        }
        let cancellation = activeRefresh.cancellation
        activeRefresh.cancellation = nil
        activeRefresh.phase = .publishing
        self.activeRefresh = activeRefresh
        lock.unlock()

        activeRefresh.timeout.cancel()
        cancellation?()
        publicationQueue.async { [weak self] in
            self?.publishIfCurrent(result, generation: generation, publish: publish)
        }
    }

    private func publishIfCurrent(
        _ result: Result<Output, WindowSelectorRefreshError>,
        generation: UInt64,
        publish: Completion
    ) {
        lock.lock()
        guard let activeRefresh,
              activeRefresh.generation == generation,
              activeRefresh.phase == .publishing else {
            lock.unlock()
            return
        }
        lock.unlock()

        publish(result)

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
