import XCTest

final class WindowSelectorRefreshAdapterTests: XCTestCase {
    func testWindowSelectorUsesOneBoundedBatchPublicationWithoutMainQueueThumbnailCallbacks() throws {
        let selector = try projectSource("QuickRecorder/ViewModel/WinSelector.swift")
        let provider = try projectSource("QuickRecorder/WindowSelectorThumbnailProvider.swift")

        XCTAssertTrue(selector.contains("WindowSelectorRefreshAdapter<WindowSelectorRefreshSnapshot>"))
        XCTAssertTrue(selector.contains("self.windowThumbnails = snapshot.thumbnails"))
        XCTAssertEqual(selector.components(separatedBy: "self.windowThumbnails =").count - 1, 1)
        XCTAssertTrue(selector.contains("accessibilityIdentifier(\"window-refresh-error\")"))
        XCTAssertTrue(selector.contains(".disabled(viewModel.isRefreshing)"))
        XCTAssertFalse(selector.contains("windowThumbnails[d]"))
        XCTAssertFalse(selector.contains("sampleHandlerQueue: .main"))
        XCTAssertTrue(provider.contains("sampleHandlerQueue: stateQueue"))
        XCTAssertTrue(provider.contains("private let stateQueue = DispatchQueue("))
        XCTAssertTrue(provider.contains("@unchecked Sendable"))
        XCTAssertGreaterThanOrEqual(provider.components(separatedBy: "stateQueue.async").count - 1, 5)
    }

    func testRefreshProviderCannotStartRecordingOrCreatePermissionAndOutputResidue() throws {
        let refreshSources = try [
            projectSource("QuickRecorder/WindowSelectorRefreshAdapter.swift"),
            projectSource("QuickRecorder/WindowSelectorThumbnailProvider.swift")
        ].joined(separator: "\n")
        let forbiddenOperations = [
            "RecordingOutputJob",
            "prepRecord(",
            "createCountdownPanel",
            "outputJob",
            "FileManager",
            "CGRequestScreenCaptureAccess",
            "NSWorkspace.shared.open",
            "UserDefaults.standard.set"
        ]

        forbiddenOperations.forEach { operation in
            XCTAssertFalse(refreshSources.contains(operation), "Refresh must not invoke \(operation)")
        }
    }

    func testSlowMultiWindowProviderKeepsMainRunLoopResponsiveUntilOnePublication() {
        let published = expectation(description: "published")
        let adapter = WindowSelectorRefreshAdapter<[Int]>(timeout: 1)
        let heartbeatLock = NSLock()
        var heartbeatCount = 0
        var publications = [[Int]]()
        let heartbeat = DispatchSource.makeTimerSource(queue: .main)
        heartbeat.schedule(deadline: .now(), repeating: 0.01)
        heartbeat.setEventHandler {
            heartbeatLock.lock()
            heartbeatCount += 1
            heartbeatLock.unlock()
        }
        heartbeat.resume()

        DispatchQueue.main.async {
            XCTAssertEqual(
                adapter.refresh(using: { complete in
                    Thread.sleep(forTimeInterval: 0.2)
                    complete(.success(Array(0..<12)))
                    return {}
                }, publish: { result in
                    XCTAssertTrue(Thread.isMainThread)
                    if case .success(let windows) = result {
                        publications.append(windows)
                    }
                    published.fulfill()
                }),
                .started
            )
        }

        wait(for: [published], timeout: 1)
        heartbeat.cancel()
        heartbeatLock.lock()
        let observedHeartbeats = heartbeatCount
        heartbeatLock.unlock()

        XCTAssertGreaterThanOrEqual(observedHeartbeats, 5)
        XCTAssertEqual(publications, [Array(0..<12)])
    }

    func testRepeatedRefreshIsCoalescedWithoutDuplicateProviderWork() {
        let providerStarted = expectation(description: "provider started")
        let published = expectation(description: "published")
        let adapter = WindowSelectorRefreshAdapter<[Int]>(timeout: 1)
        let lock = NSLock()
        var providerCount = 0
        var finish: WindowSelectorRefreshAdapter<[Int]>.Completion?

        let first = adapter.refresh(using: { complete in
            lock.lock()
            providerCount += 1
            finish = complete
            lock.unlock()
            providerStarted.fulfill()
            return {}
        }, publish: { result in
            XCTAssertEqual(try? result.get(), [1, 2])
            published.fulfill()
        })

        wait(for: [providerStarted], timeout: 1)
        let second = adapter.refresh(using: { _ in
            XCTFail("Coalesced refresh must not invoke a second provider")
            return {}
        }, publish: { _ in
            XCTFail("Coalesced refresh must not publish")
        })

        lock.lock()
        let completion = finish
        let observedProviderCount = providerCount
        lock.unlock()
        completion?(.success([1, 2]))

        wait(for: [published], timeout: 1)
        XCTAssertEqual(first, .started)
        XCTAssertEqual(second, .coalesced)
        XCTAssertEqual(observedProviderCount, 1)
    }

    func testTimeoutCancelsOnceAndCorrectedSameProcessRetryIgnoresStaleCompletion() {
        let timedOut = expectation(description: "timed out")
        let retryPublished = expectation(description: "retry published")
        let adapter = WindowSelectorRefreshAdapter<[Int]>(timeout: 0.05)
        let lock = NSLock()
        var firstCompletion: WindowSelectorRefreshAdapter<[Int]>.Completion?
        var cancellationCount = 0
        var results = [Result<[Int], WindowSelectorRefreshError>]()

        XCTAssertEqual(
            adapter.refresh(using: { complete in
                firstCompletion = complete
                return {
                    lock.lock()
                    cancellationCount += 1
                    lock.unlock()
                }
            }, publish: { result in
                results.append(result)
                timedOut.fulfill()
            }),
            .started
        )

        wait(for: [timedOut], timeout: 1)
        XCTAssertEqual(results, [.failure(.timedOut)])
        XCTAssertEqual(WindowSelectorRefreshError.timedOut.userMessage, "Window refresh timed out. Please try again.")

        XCTAssertEqual(
            adapter.refresh(using: { complete in
                firstCompletion?(.success([-1]))
                complete(.success([7, 8, 9]))
                return {}
            }, publish: { result in
                results.append(result)
                retryPublished.fulfill()
            }),
            .started
        )

        wait(for: [retryPublished], timeout: 1)
        lock.lock()
        let observedCancellationCount = cancellationCount
        lock.unlock()
        XCTAssertEqual(observedCancellationCount, 1)
        XCTAssertEqual(results, [.failure(.timedOut), .success([7, 8, 9])])
    }

    func testExplicitCancellationRejectsStalePublicationAndAllowsRetry() {
        let providerStarted = expectation(description: "provider started")
        let cancelledPublication = expectation(description: "cancelled publication")
        cancelledPublication.isInverted = true
        let retryPublished = expectation(description: "retry published")
        let adapter = WindowSelectorRefreshAdapter<Int>(timeout: 1)
        let lock = NSLock()
        var staleCompletion: WindowSelectorRefreshAdapter<Int>.Completion?
        var cancellationCount = 0

        adapter.refresh(using: { completion in
            lock.lock()
            staleCompletion = completion
            lock.unlock()
            providerStarted.fulfill()
            return {
                lock.lock()
                cancellationCount += 1
                lock.unlock()
            }
        }, publish: { _ in
            cancelledPublication.fulfill()
        })
        wait(for: [providerStarted], timeout: 1)

        adapter.cancel()
        lock.lock()
        let completion = staleCompletion
        lock.unlock()
        completion?(.success(-1))
        XCTAssertEqual(
            adapter.refresh(using: { completion in
                completion(.success(42))
                return {}
            }, publish: { result in
                XCTAssertEqual(try? result.get(), 42)
                retryPublished.fulfill()
            }),
            .started
        )

        wait(for: [retryPublished, cancelledPublication], timeout: 0.2)
        lock.lock()
        let observedCancellationCount = cancellationCount
        lock.unlock()
        XCTAssertEqual(observedCancellationCount, 1)
        XCTAssertEqual(
            WindowSelectorRefreshError.unavailable("localized provider detail").userMessage,
            "Window refresh failed. Please try again."
        )
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectRoot = testsDirectory.deletingLastPathComponent()
        return try String(contentsOf: projectRoot.appendingPathComponent(relativePath))
    }
}
