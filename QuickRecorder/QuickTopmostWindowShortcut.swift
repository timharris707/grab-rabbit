import Foundation

enum QuickTopmostWindowShortcutFailure: Equatable {
    case contentUnavailable
    case permissionDenied
    case topmostWindowUnavailable
}

final class QuickTopmostWindowShortcutAdapter<Content, Target> {
    typealias ContentResult = Result<Content, ScreenRecordingContentError>
    typealias RefreshContent = (@escaping (ContentResult) -> Void) -> Void
    typealias Schedule = (@escaping () -> Void) -> Void

    private let maximumAttempts: Int
    private let refreshContent: RefreshContent
    private let selectCurrentTarget: (Content) -> Target?
    private let scheduleRetry: Schedule
    private let scheduleAttemptTimeout: Schedule
    private let startCapture: (Content, Target) -> Void
    private let showFailure: (QuickTopmostWindowShortcutFailure) -> Void

    private var isResolving = false
    private var attemptsMade = 0
    private var attemptGeneration: UInt64 = 0
    private var activeAttemptGeneration: UInt64?

    init(
        maximumAttempts: Int,
        refreshContent: @escaping RefreshContent,
        selectCurrentTarget: @escaping (Content) -> Target?,
        scheduleRetry: @escaping Schedule,
        scheduleAttemptTimeout: @escaping Schedule,
        startCapture: @escaping (Content, Target) -> Void,
        showFailure: @escaping (QuickTopmostWindowShortcutFailure) -> Void
    ) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
        self.refreshContent = refreshContent
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
        showFailure(failure)
        isResolving = false
    }
}
