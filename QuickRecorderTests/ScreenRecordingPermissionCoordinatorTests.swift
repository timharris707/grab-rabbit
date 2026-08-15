import XCTest

final class ScreenRecordingPermissionCoordinatorTests: XCTestCase {
    func testPreflightDeniedStartupExposesOneReachableRecoveryWithoutFetching() {
        var fetchCount = 0
        var reachableActionCount = 0
        var recoveryCount = 0
        var recoveryAction: (() -> Void)?
        var dismissRecovery: (() -> Void)?
        let coordinator = ScreenRecordingPermissionCoordinator<Int> { dismiss in
            recoveryCount += 1
            dismissRecovery = dismiss
        }

        ScreenRecordingStartupPolicy().start(
            preflightAuthorized: false,
            refresh: { fetchCount += 1 },
            makeRecoveryActionReachable: {
                reachableActionCount += 1
                recoveryAction = { coordinator.presentRecoveryIfNeeded() }
            }
        )

        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(reachableActionCount, 1)
        XCTAssertNotNil(recoveryAction)
        XCTAssertEqual(recoveryCount, 0)

        recoveryAction?()
        recoveryAction?()

        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(recoveryCount, 1)

        dismissRecovery?()
        XCTAssertEqual(recoveryCount, 1)
    }

    func testDeniedRefreshMakesOneRequestAndOneRecoveryFlow() {
        var fetchCount = 0
        var recoveryCount = 0
        var finishRequest: ((Result<Int, ScreenRecordingContentError>) -> Void)?
        var dismissRecovery: (() -> Void)?
        var results = [Result<Int, ScreenRecordingContentError>]()
        let coordinator = ScreenRecordingPermissionCoordinator<Int> { dismiss in
            recoveryCount += 1
            dismissRecovery = dismiss
        }
        let fetch: ScreenRecordingPermissionCoordinator<Int>.Fetch = { finish in
            fetchCount += 1
            finishRequest = finish
        }

        coordinator.refresh(using: fetch) { results.append($0) }
        coordinator.refresh(using: fetch) { results.append($0) }

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(recoveryCount, 0)

        finishRequest?(.failure(.permissionDenied))

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(results, [.failure(.permissionDenied), .failure(.permissionDenied)])

        coordinator.refresh(using: fetch) { results.append($0) }

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(results.last, .failure(.permissionDenied))

        dismissRecovery?()
        coordinator.refresh(using: fetch) { results.append($0) }

        XCTAssertEqual(fetchCount, 2)
    }

    func testSuccessfulRefreshPreservesContentWithoutRecovery() {
        var recoveryCount = 0
        var result: Result<String, ScreenRecordingContentError>?
        var finishRequest: ((Result<String, ScreenRecordingContentError>) -> Void)?
        var readinessChanges = [Bool]()
        let contentState = ScreenRecordingContentState<String> {
            readinessChanges.append($0)
        }
        let coordinator = ScreenRecordingPermissionCoordinator<String> { _ in
            recoveryCount += 1
        }

        coordinator.refresh(using: { finishRequest = $0 }) {
            result = $0
            contentState.apply($0)
        }

        XCTAssertNil(result)
        XCTAssertFalse(contentState.isReady)
        XCTAssertNil(contentState.content)

        finishRequest?(.success("content"))

        XCTAssertEqual(result, .success("content"))
        XCTAssertTrue(contentState.isReady)
        XCTAssertEqual(contentState.content, "content")
        XCTAssertEqual(readinessChanges, [true])
        XCTAssertEqual(recoveryCount, 0)

        contentState.apply(.failure(.unavailable("No displays")))

        XCTAssertFalse(contentState.isReady)
        XCTAssertNil(contentState.content)
        XCTAssertEqual(readinessChanges, [true, false])
    }

    func testProviderCannotCompleteTheSameRequestTwice() {
        var completionCount = 0
        var finishRequest: ((Result<Int, ScreenRecordingContentError>) -> Void)?
        let coordinator = ScreenRecordingPermissionCoordinator<Int> { dismiss in dismiss() }

        coordinator.refresh(using: { finishRequest = $0 }) { _ in
            completionCount += 1
        }
        finishRequest?(.failure(.unavailable("first")))
        finishRequest?(.failure(.permissionDenied))

        XCTAssertEqual(completionCount, 1)
    }

    func testStaleCompletionCannotConsumeANewerRequest() {
        var recoveryCount = 0
        var requestCompletions = [((Result<Int, ScreenRecordingContentError>) -> Void)]()
        var results = [Result<Int, ScreenRecordingContentError>]()
        let coordinator = ScreenRecordingPermissionCoordinator<Int> { _ in
            recoveryCount += 1
        }
        let fetch: ScreenRecordingPermissionCoordinator<Int>.Fetch = { finish in
            requestCompletions.append(finish)
        }

        coordinator.refresh(using: fetch) { results.append($0) }
        requestCompletions[0](.failure(.unavailable("first")))

        coordinator.refresh(using: fetch) { results.append($0) }
        requestCompletions[0](.failure(.permissionDenied))
        requestCompletions[1](.success(42))

        XCTAssertEqual(requestCompletions.count, 2)
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(results, [.failure(.unavailable("first")), .success(42)])
    }

    func testPermissionCopyUsesTheCurrentProductName() {
        let messages = [
            PermissionCopy.microphone(productName: "Grab Rabbit"),
            PermissionCopy.screenRecording(productName: "Grab Rabbit"),
            PermissionCopy.camera(productName: "Grab Rabbit")
        ]

        XCTAssertTrue(messages.allSatisfy { $0.contains("Grab Rabbit") })
        XCTAssertTrue(messages.allSatisfy { !$0.contains("QuickRecorder") })
    }
}
