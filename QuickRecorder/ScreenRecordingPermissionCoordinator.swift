import Foundation

enum ScreenRecordingContentError: Error, Equatable {
    case permissionDenied
    case unavailable(String)
}

final class ScreenRecordingContentState<Content> {
    typealias ContentResult = Result<Content, ScreenRecordingContentError>

    private let lock = NSLock()
    private let readinessChanged: (Bool) -> Void
    private var storedContent: Content?
    private var storedReadiness = false

    init(readinessChanged: @escaping (Bool) -> Void = { _ in }) {
        self.readinessChanged = readinessChanged
    }

    var content: Content? {
        lock.lock()
        defer { lock.unlock() }
        return storedContent
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedReadiness
    }

    func apply(_ result: ContentResult) {
        let isReady: Bool
        lock.lock()
        switch result {
        case .success(let content):
            storedContent = content
            storedReadiness = true
            isReady = true
        case .failure:
            storedContent = nil
            storedReadiness = false
            isReady = false
        }
        lock.unlock()
        readinessChanged(isReady)
    }
}

struct ScreenRecordingStartupPolicy {
    func start(
        preflightAuthorized: Bool,
        refresh: () -> Void,
        makeRecoveryActionReachable: () -> Void
    ) {
        if preflightAuthorized {
            refresh()
        } else {
            makeRecoveryActionReachable()
        }
    }
}

final class ScreenRecordingPermissionCoordinator<Content> {
    typealias ContentResult = Result<Content, ScreenRecordingContentError>
    typealias Fetch = (@escaping (ContentResult) -> Void) -> Void
    typealias RecoveryPresenter = (@escaping () -> Void) -> Void

    private enum State {
        case idle
        case requesting
        case recoveryVisible
    }

    private let lock = NSLock()
    private let presentRecovery: RecoveryPresenter
    private var state = State.idle
    private var completions = [(ContentResult) -> Void]()
    private var requestGeneration: UInt64 = 0
    private var activeRequestGeneration: UInt64?

    init(presentRecovery: @escaping RecoveryPresenter) {
        self.presentRecovery = presentRecovery
    }

    func refresh(using fetch: @escaping Fetch, completion: @escaping (ContentResult) -> Void) {
        lock.lock()
        switch state {
        case .idle:
            state = .requesting
            completions.append(completion)
            requestGeneration += 1
            let generation = requestGeneration
            activeRequestGeneration = generation
            lock.unlock()
            fetch { [weak self] result in
                self?.finish(result, generation: generation)
            }
        case .requesting:
            completions.append(completion)
            lock.unlock()
        case .recoveryVisible:
            lock.unlock()
            completion(.failure(.permissionDenied))
        }
    }

    func presentRecoveryIfNeeded() {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return
        }
        state = .recoveryVisible
        lock.unlock()

        presentRecovery { [weak self] in
            self?.dismissRecovery()
        }
    }

    private func finish(_ result: ContentResult, generation: UInt64) {
        lock.lock()
        guard state == .requesting, activeRequestGeneration == generation else {
            lock.unlock()
            return
        }

        activeRequestGeneration = nil
        let waitingCompletions = completions
        completions.removeAll()
        let needsRecovery: Bool
        if case .failure(.permissionDenied) = result {
            state = .recoveryVisible
            needsRecovery = true
        } else {
            state = .idle
            needsRecovery = false
        }
        lock.unlock()

        waitingCompletions.forEach { $0(result) }
        if needsRecovery {
            presentRecovery { [weak self] in
                self?.dismissRecovery()
            }
        }
    }

    private func dismissRecovery() {
        lock.lock()
        if state == .recoveryVisible {
            state = .idle
        }
        lock.unlock()
    }
}

enum PermissionCopy {
    static let microphoneFormat = "%@ needs permission to record your microphone."
    static let screenRecordingFormat = "%@ needs screen recording permission, even if you only intend to record audio."
    static let cameraFormat = "%@ needs permission to record your camera or mobile device."

    static func microphone(productName: String, localizedFormat: String? = nil) -> String {
        String(format: localizedFormat ?? microphoneFormat, productName)
    }

    static func screenRecording(productName: String, localizedFormat: String? = nil) -> String {
        String(format: localizedFormat ?? screenRecordingFormat, productName)
    }

    static func camera(productName: String, localizedFormat: String? = nil) -> String {
        String(format: localizedFormat ?? cameraFormat, productName)
    }
}
