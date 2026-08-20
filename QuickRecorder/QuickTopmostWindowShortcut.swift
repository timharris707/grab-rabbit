import CoreGraphics
import Foundation

enum QuickTopmostWindowShortcutFailure: Equatable {
    case contentUnavailable
    case permissionDenied
    case topmostWindowUnavailable
}

enum QuickTopmostContentAttemptOutcome<Content> {
    case completed(Result<Content, ScreenRecordingContentError>)
    case timedOut
}

enum QuickTopmostWindowZOrder {
    static func frontToBackWindowIDs() -> [CGWindowID] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }
}

struct QuickTopmostWindowResolver {
    static func resolve<Item, ProcessID: Equatable, WindowID: Hashable>(
        frontmostProcessID: ProcessID,
        frontToBackWindowIDs: [WindowID],
        candidates: [Item],
        processID: (Item) -> ProcessID?,
        windowID: (Item) -> WindowID
    ) -> Item? {
        let candidatesByID = Dictionary(
            candidates.compactMap { candidate -> (WindowID, Item)? in
                guard processID(candidate) == frontmostProcessID else { return nil }
                return (windowID(candidate), candidate)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return frontToBackWindowIDs.lazy.compactMap { candidatesByID[$0] }.first
    }
}

struct QuickTopmostContentPreflightPolicy {
    func refresh<Content>(
        preflightAuthorized: Bool,
        fetch: (@escaping (Result<Content, ScreenRecordingContentError>) -> Void) -> Void,
        completion: @escaping (Result<Content, ScreenRecordingContentError>) -> Void
    ) {
        guard preflightAuthorized else {
            completion(.failure(.permissionDenied))
            return
        }
        fetch(completion)
    }
}

struct QuickTopmostWindowFailurePresenter {
    private let activateApplication: () -> Void
    private let showAlert: (_ title: String, _ message: String) -> Void

    init(
        activateApplication: @escaping () -> Void,
        showAlert: @escaping (_ title: String, _ message: String) -> Void
    ) {
        self.activateApplication = activateApplication
        self.showAlert = showAlert
    }

    func present(_ failure: QuickTopmostWindowShortcutFailure) {
        let message: String
        switch failure {
        case .contentUnavailable:
            message = "Grab Rabbit could not load the available windows. Make sure the display is awake, then try Quick Topmost Window again."
        case .permissionDenied:
            message = "Screen recording access is unavailable. Grant Grab Rabbit access in System Settings, then try Quick Topmost Window again."
        case .topmostWindowUnavailable:
            message = "Grab Rabbit could not find an eligible window in the current frontmost app. Bring the window forward, then try again."
        }
        activateApplication()
        showAlert("Quick Topmost Window Unavailable", message)
    }
}

struct QuickTopmostWindowFailureHandler {
    private let captureStateIsIdle: () -> Bool
    private let clearStaleTargets: () -> Void
    private let presenter: QuickTopmostWindowFailurePresenter

    init(
        captureStateIsIdle: @escaping () -> Bool,
        clearStaleTargets: @escaping () -> Void,
        presenter: QuickTopmostWindowFailurePresenter
    ) {
        self.captureStateIsIdle = captureStateIsIdle
        self.clearStaleTargets = clearStaleTargets
        self.presenter = presenter
    }

    func handle(_ failure: QuickTopmostWindowShortcutFailure) {
        if captureStateIsIdle() {
            clearStaleTargets()
        }
        presenter.present(failure)
    }
}

final class QuickTopmostWindowShortcutAdapter<Content, Target> {
    typealias ContentResult = Result<Content, ScreenRecordingContentError>
    typealias AttemptOutcome = QuickTopmostContentAttemptOutcome<Content>
    typealias RefreshContent = (@escaping (ContentResult) -> Void) -> Void
    typealias Schedule = (@escaping () -> Void) -> Void

    private let maximumAttempts: Int
    private let refreshContent: RefreshContent
    private let acceptAttemptOutcome: (AttemptOutcome) -> Void
    private let selectCurrentTarget: (Content) -> Target?
    private let scheduleRetry: Schedule
    private let scheduleAttemptTimeout: Schedule
    private let startCapture: (Content, Target) -> Void
    private let showFailure: (QuickTopmostWindowShortcutFailure) -> Void

    // Not thread-safe by design: every entry point (trigger, refresh completion,
    // retry, attempt timeout) must arrive on the main thread as a serial,
    // non-reentrant callback. Production wiring satisfies this by hopping each
    // callback onto the main queue before it reaches the adapter.
    private var isResolving = false
    private var attemptsMade = 0
    private var attemptGeneration: UInt64 = 0
    private var activeAttemptGeneration: UInt64?

    init(
        maximumAttempts: Int,
        refreshContent: @escaping RefreshContent,
        acceptAttemptOutcome: @escaping (AttemptOutcome) -> Void,
        selectCurrentTarget: @escaping (Content) -> Target?,
        scheduleRetry: @escaping Schedule,
        scheduleAttemptTimeout: @escaping Schedule,
        startCapture: @escaping (Content, Target) -> Void,
        showFailure: @escaping (QuickTopmostWindowShortcutFailure) -> Void
    ) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
        self.refreshContent = refreshContent
        self.acceptAttemptOutcome = acceptAttemptOutcome
        self.selectCurrentTarget = selectCurrentTarget
        self.scheduleRetry = scheduleRetry
        self.scheduleAttemptTimeout = scheduleAttemptTimeout
        self.startCapture = startCapture
        self.showFailure = showFailure
    }

    func trigger() {
        guard !isResolving else { return }
        isResolving = true
        attemptsMade = 0
        beginAttempt()
    }

    private func beginAttempt() {
        attemptsMade += 1
        attemptGeneration += 1
        let generation = attemptGeneration
        activeAttemptGeneration = generation

        scheduleAttemptTimeout { [weak self] in
            self?.handleAttemptTimeout(generation: generation)
        }
        refreshContent { [weak self] result in
            self?.handle(result, generation: generation)
        }
    }

    private func handle(_ result: ContentResult, generation: UInt64) {
        guard isResolving, activeAttemptGeneration == generation else { return }
        activeAttemptGeneration = nil
        acceptAttemptOutcome(.completed(result))

        switch result {
        case .success(let content):
            guard let target = selectCurrentTarget(content) else {
                retryOrFinish(with: .topmostWindowUnavailable)
                return
            }
            isResolving = false
            startCapture(content, target)
        case .failure(.permissionDenied):
            finish(with: .permissionDenied)
        case .failure(.unavailable):
            retryOrFinish(with: .contentUnavailable)
        }
    }

    private func handleAttemptTimeout(generation: UInt64) {
        guard isResolving, activeAttemptGeneration == generation else { return }
        activeAttemptGeneration = nil
        acceptAttemptOutcome(.timedOut)
        retryOrFinish(with: .contentUnavailable)
    }

    private func retryOrFinish(with failure: QuickTopmostWindowShortcutFailure) {
        guard attemptsMade < maximumAttempts else {
            finish(with: failure)
            return
        }
        scheduleRetry { [weak self] in
            guard let self, self.isResolving, self.activeAttemptGeneration == nil else { return }
            self.beginAttempt()
        }
    }

    private func finish(with failure: QuickTopmostWindowShortcutFailure) {
        activeAttemptGeneration = nil
        // Release the resolving latch before presenting, because production's
        // showFailure ends in NSAlert.runModal() and would otherwise hold the
        // adapter busy for as long as the alert is on screen.
        isResolving = false
        showFailure(failure)
    }
}
