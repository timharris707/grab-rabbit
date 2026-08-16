import XCTest

final class WindowSelectorRefreshAdapterTests: XCTestCase {
    func testWindowSelectorFetchChecksPreflightBeforeCallingTheProvider() throws {
        let context = try projectSource("QuickRecorder/SCContext.swift")
        guard let start = context.range(of: "static func fetchWindowSelectorContent"),
              let end = context.range(
                of: "static func applyWindowSelectorContent",
                range: start.upperBound..<context.endIndex
              ) else {
            return XCTFail("Window-selector fetch seam is missing")
        }
        let fetchSeam = String(context[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(fetchSeam.contains("CGPreflightScreenCaptureAccess()"))
        XCTAssertTrue(fetchSeam.contains("WindowSelectorContentAccessPolicy"))
    }

    func testRefreshNeverClearsSelectionAndUsesIdentityReconciliation() throws {
        let selector = try projectSource("QuickRecorder/ViewModel/WinSelector.swift")
        let adapter = try projectSource("QuickRecorder/WindowSelectorRefreshAdapter.swift")

        XCTAssertFalse(selector.contains("self.selected.removeAll()"))
        XCTAssertTrue(selector.contains("WindowSelectorRefreshTransaction.resolve"))
        XCTAssertTrue(adapter.contains("WindowSelectorSelectionReconciler.reconcile"))
        XCTAssertEqual(selector.components(separatedBy: "selectedWindows: selected").count - 1, 3)
        XCTAssertEqual(selector.components(separatedBy: "updateSelection: { selected = $0 }").count - 1, 3)
        XCTAssertTrue(selector.contains("if isReady && selected.isEmpty"))
    }

    func testDeniedPreflightReturnsTypedFailureWithoutCallingProvider() {
        var providerCount = 0
        var results = [Result<Int, ScreenRecordingContentError>]()

        WindowSelectorContentAccessPolicy().fetch(
            preflightAuthorized: false,
            provider: { completion in
                providerCount += 1
                completion(.success(1))
            },
            completion: { results.append($0) }
        )

        XCTAssertEqual(providerCount, 0)
        XCTAssertEqual(results, [.failure(.permissionDenied)])
        XCTAssertEqual(
            WindowSelectorRefreshError.permissionDenied.userMessage,
            "Screen recording access is required to refresh windows."
        )

        let failurePublished = expectation(description: "permission failure published")
        let adapter = WindowSelectorRefreshAdapter<Int>(timeout: 1)
        var messages = [String]()
        adapter.refresh(using: { completion in
            completion(.failure(.permissionDenied))
            return {}
        }, publish: { result in
            if case .failure(let error) = result {
                messages.append(error.userMessage)
            }
            failurePublished.fulfill()
        })
        wait(for: [failurePublished], timeout: 1)
        XCTAssertEqual(messages, ["Screen recording access is required to refresh windows."])
    }

    func testSelectionTransactionPreservesSameIdentityAndRejectsMissingTarget() {
        struct TestWindow: Equatable {
            let id: Int
            let revision: Int
        }
        struct TestChoices: Equatable {
            let microphone: String
            let systemAudio: Bool
            let codec: String
            let saveLocation: String
        }

        let priorWindow = TestWindow(id: 7, revision: 1)
        let priorChoices = TestChoices(
            microphone: "Desk Mic",
            systemAudio: true,
            codec: "HEVC",
            saveLocation: "~/Movies/GrabRabbit"
        )
        let currentChoices = priorChoices
        let accepted = WindowSelectorRefreshTransaction.resolve(
            currentModel: "prior snapshot",
            currentSelection: [priorWindow],
            candidateModel: "candidate snapshot",
            candidateItems: [TestWindow(id: 7, revision: 2), TestWindow(id: 8, revision: 1)],
            identifier: \.id
        )

        XCTAssertTrue(accepted.acceptedCandidate)
        XCTAssertEqual(accepted.model, "candidate snapshot")
        XCTAssertEqual(accepted.selection, [TestWindow(id: 7, revision: 2)])
        XCTAssertEqual(currentChoices, priorChoices)

        let rejected = WindowSelectorRefreshTransaction.resolve(
            currentModel: "prior snapshot",
            currentSelection: [priorWindow],
            candidateModel: "candidate snapshot",
            candidateItems: [TestWindow(id: 8, revision: 1)],
            identifier: \.id
        )

        XCTAssertFalse(rejected.acceptedCandidate)
        XCTAssertEqual(rejected.model, "prior snapshot")
        XCTAssertEqual(rejected.selection, [priorWindow])
        XCTAssertEqual(currentChoices, priorChoices)
        XCTAssertEqual(
            WindowSelectorRefreshError.selectedTargetUnavailable.userMessage,
            "The selected window is no longer available. Your previous selection was kept."
        )
    }

    func testRefreshTransactionSourceCannotMutateMediaCodecOrSaveChoices() throws {
        let selector = try projectSource("QuickRecorder/ViewModel/WinSelector.swift")
        guard let viewModelStart = selector.range(of: "class WindowSelectorViewModel") else {
            return XCTFail("WindowSelectorViewModel is missing")
        }
        let refreshSource = String(selector[viewModelStart.lowerBound...])
        let forbiddenMutations = [
            "recordMic =",
            "recordWinSound =",
            "encoder =",
            "videoFormat =",
            "savePath =",
            "outputJob =",
            "UserDefaults.standard.set"
        ]

        forbiddenMutations.forEach { mutation in
            XCTAssertFalse(refreshSource.contains(mutation), "Refresh must not mutate \(mutation)")
        }
    }

    func testWindowSelectorUsesOneBoundedBatchPublicationWithoutMainQueueThumbnailCallbacks() throws {
        let selector = try projectSource("QuickRecorder/ViewModel/WinSelector.swift")
        let provider = try projectSource("QuickRecorder/WindowSelectorThumbnailProvider.swift")

        XCTAssertTrue(selector.contains("WindowSelectorRefreshAdapter<WindowSelectorRefreshSnapshot>"))
        XCTAssertTrue(selector.contains("self.windowThumbnails = resolution.model"))
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

    func testQueuedOlderPublicationCannotOverwriteANewerGeneration() {
        let publicationQueue = DispatchQueue(label: "window-refresh-publication-test")
        let publicationQueueBlocked = DispatchSemaphore(value: 0)
        let releasePublicationQueue = DispatchSemaphore(value: 0)
        publicationQueue.async {
            publicationQueueBlocked.signal()
            releasePublicationQueue.wait()
        }
        XCTAssertEqual(publicationQueueBlocked.wait(timeout: .now() + 1), .success)

        let firstProviderFinished = expectation(description: "first provider finished")
        let secondPublished = expectation(description: "second published")
        let adapter = WindowSelectorRefreshAdapter<Int>(
            timeout: 1,
            publicationQueue: publicationQueue
        )
        let lock = NSLock()
        var publications = [Int]()

        XCTAssertEqual(
            adapter.refresh(using: { complete in
                complete(.success(1))
                firstProviderFinished.fulfill()
                return {}
            }, publish: { result in
                if case .success(let value) = result {
                    lock.lock()
                    publications.append(value)
                    lock.unlock()
                }
            }),
            .started
        )
        wait(for: [firstProviderFinished], timeout: 1)

        XCTAssertEqual(
            adapter.refresh(using: { complete in
                complete(.success(2))
                return {}
            }, publish: { result in
                if case .success(let value) = result {
                    lock.lock()
                    publications.append(value)
                    lock.unlock()
                }
                secondPublished.fulfill()
            }),
            .started
        )

        releasePublicationQueue.signal()
        wait(for: [secondPublished], timeout: 1)
        lock.lock()
        let observedPublications = publications
        lock.unlock()
        XCTAssertEqual(observedPublications, [2])
    }

    func testPublicationCallbackRunsAfterAdapterUnlock() throws {
        let adapter = try projectSource("QuickRecorder/WindowSelectorRefreshAdapter.swift")
        guard let methodStart = adapter.range(of: "private func publishIfCurrent"),
              let methodEnd = adapter.range(
                of: "deinit",
                range: methodStart.upperBound..<adapter.endIndex
              ) else {
            return XCTFail("Publication boundary is missing")
        }
        let publicationBoundary = String(adapter[methodStart.lowerBound..<methodEnd.lowerBound])
        guard let publish = publicationBoundary.range(of: "publish(result)") else {
            return XCTFail("Publication boundary must unlock and publish")
        }
        let afterPublish = publicationBoundary[publish.upperBound...]
        XCTAssertFalse(
            afterPublish.contains("lock.unlock()"),
            "External publication callbacks must never run while the adapter lock is held"
        )
    }

    func testPublicationCallbackCanSynchronouslyStartTheNextGeneration() {
        let publicationQueue = DispatchQueue(label: "window-refresh-reentrant-start-test")
        let adapter = WindowSelectorRefreshAdapter<Int>(
            timeout: 1,
            publicationQueue: publicationQueue
        )
        let secondPublished = expectation(description: "second generation published")
        let lock = NSLock()
        var publications = [Int]()

        XCTAssertEqual(
            adapter.refresh(using: { complete in
                complete(.success(1))
                return {}
            }, publish: { result in
                if case .success(let value) = result {
                    lock.lock()
                    publications.append(value)
                    lock.unlock()
                }
                XCTAssertEqual(
                    adapter.refresh(using: { complete in
                        complete(.success(2))
                        return {}
                    }, publish: { result in
                        if case .success(let value) = result {
                            lock.lock()
                            publications.append(value)
                            lock.unlock()
                        }
                        secondPublished.fulfill()
                    }),
                    .started
                )
            }),
            .started
        )

        wait(for: [secondPublished], timeout: 1)
        lock.lock()
        let observedPublications = publications
        lock.unlock()
        XCTAssertEqual(observedPublications, [1, 2])
    }

    func testPublicationCallbackCanSynchronouslyCancelWithoutDeadlock() {
        let publicationQueue = DispatchQueue(label: "window-refresh-reentrant-cancel-test")
        let adapter = WindowSelectorRefreshAdapter<Int>(
            timeout: 1,
            publicationQueue: publicationQueue
        )
        let published = expectation(description: "callback cancelled adapter")

        XCTAssertEqual(
            adapter.refresh(using: { complete in
                complete(.success(1))
                return {}
            }, publish: { _ in
                adapter.cancel()
                published.fulfill()
            }),
            .started
        )

        wait(for: [published], timeout: 1)
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectRoot = testsDirectory.deletingLastPathComponent()
        return try String(contentsOf: projectRoot.appendingPathComponent(relativePath))
    }
}
