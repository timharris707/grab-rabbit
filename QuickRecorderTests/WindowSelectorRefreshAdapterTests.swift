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

    func testRefreshClearsKnownUnavailableSelectionAndUsesIdentityReconciliation() throws {
        let selector = try projectSource("QuickRecorder/ViewModel/WinSelector.swift")
        let adapter = try projectSource("QuickRecorder/WindowSelectorRefreshAdapter.swift")

        XCTAssertTrue(selector.contains("WindowSelectorRefreshCoordinator<"))
        XCTAssertTrue(adapter.contains("WindowSelectorSelectionReconciler.reconcile"))
        XCTAssertFalse(selector.contains("selectedWindows: selected"))
        XCTAssertEqual(selector.components(separatedBy: "currentSelection: { selected }").count - 1, 3)
        XCTAssertEqual(selector.components(separatedBy: "updateSelection: { selected = $0 }").count - 1, 3)
        XCTAssertTrue(selector.contains("updateSelection: updateSelection"))
        XCTAssertTrue(selector.contains("currentSelection: @escaping () -> [SCWindow]"))
        XCTAssertEqual(selector.components(separatedBy: ".disabled(viewModel.isRefreshing)").count - 1, 1)
        XCTAssertTrue(selector.contains("dispatchPrecondition(condition: .onQueue(DispatchQueue.main))"))
        XCTAssertTrue(adapter.contains("let liveSelection = currentSelection()"))
        XCTAssertTrue(adapter.contains("selection: []"))
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
            currentSelection: { [priorWindow] },
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
            currentSelection: { [priorWindow] },
            candidateModel: "candidate snapshot",
            candidateItems: [TestWindow(id: 8, revision: 1)],
            identifier: \.id
        )

        XCTAssertFalse(rejected.acceptedCandidate)
        XCTAssertEqual(rejected.model, "candidate snapshot")
        XCTAssertEqual(rejected.selection, [])
        XCTAssertEqual(currentChoices, priorChoices)
        XCTAssertEqual(
            WindowSelectorRefreshError.selectedTargetUnavailable.userMessage,
            "The selected window is no longer available. Select a window and try again."
        )
    }

    func testSlowRefreshReconcilesCandidateAgainstLiveSelectionAtPublicationTime() {
        struct TestWindow: Equatable {
            let id: Int
            let revision: Int
        }
        struct TestSnapshot {
            let model: String
            let windows: [TestWindow]
        }

        let providerStarted = expectation(description: "slow provider started")
        let published = expectation(description: "slow refresh published")
        let adapter = WindowSelectorRefreshAdapter<TestSnapshot>(timeout: 1)
        let stateLock = NSLock()
        var providerCompletion: WindowSelectorRefreshAdapter<TestSnapshot>.Completion?
        var liveSelection = [TestWindow(id: 7, revision: 1)]
        var observedResolution: WindowSelectorRefreshResolution<String, TestWindow>?

        XCTAssertEqual(
            adapter.refresh(using: { completion in
                stateLock.lock()
                providerCompletion = completion
                stateLock.unlock()
                providerStarted.fulfill()
                return {}
            }, publish: { result in
                XCTAssertTrue(Thread.isMainThread)
                guard case .success(let snapshot) = result else {
                    return XCTFail("Slow refresh unexpectedly failed")
                }
                observedResolution = WindowSelectorRefreshTransaction.resolve(
                    currentModel: "prior snapshot",
                    currentSelection: { liveSelection },
                    candidateModel: snapshot.model,
                    candidateItems: snapshot.windows,
                    identifier: \.id
                )
                published.fulfill()
            }),
            .started
        )
        wait(for: [providerStarted], timeout: 1)

        liveSelection = [TestWindow(id: 8, revision: 1)]
        stateLock.lock()
        let completion = providerCompletion
        stateLock.unlock()
        completion?(.success(TestSnapshot(
            model: "candidate snapshot",
            windows: [TestWindow(id: 7, revision: 2), TestWindow(id: 8, revision: 2)]
        )))

        wait(for: [published], timeout: 1)
        XCTAssertEqual(observedResolution?.model, "candidate snapshot")
        XCTAssertEqual(observedResolution?.selection, [TestWindow(id: 8, revision: 2)])
        XCTAssertEqual(observedResolution?.acceptedCandidate, true)
    }

    func testProductionCoordinatorPublishesFreshModelWhenSelectionDisappears() {
        struct TestWindow: Equatable {
            let id: Int
            let revision: Int
        }
        struct TestSnapshot {
            let model: String
            let windows: [TestWindow]
        }

        let providerStarted = expectation(description: "slow provider started")
        let published = expectation(description: "missing target published")
        let stateLock = NSLock()
        var providerCompletion: WindowSelectorRefreshAdapter<TestSnapshot>.Completion?
        var liveSelection = [TestWindow(id: 7, revision: 1)]
        var visibleModel = "prior snapshot"
        var visibleSelection = liveSelection
        var appliedSnapshotModels = [String]()
        var statuses = [WindowSelectorRefreshStatus]()
        let coordinator = WindowSelectorRefreshCoordinator<Int, TestSnapshot, String, TestWindow, Int>(
            timeout: 1,
            candidateModel: { $0.model },
            candidateItems: { $0.windows },
            identifier: \.id,
            isModelEmpty: { $0.isEmpty },
            providerFactory: { _ in
                { completion in
                    stateLock.lock()
                    providerCompletion = completion
                    stateLock.unlock()
                    providerStarted.fulfill()
                    return {}
                }
            }
        )

        XCTAssertEqual(
            coordinator.refresh(
                request: 0,
                currentModel: { "prior snapshot" },
                currentSelection: { liveSelection },
                applySnapshot: { snapshot in
                    XCTAssertTrue(Thread.isMainThread)
                    appliedSnapshotModels.append(snapshot.model)
                },
                applyModel: { visibleModel = $0 },
                updateSelection: { visibleSelection = $0 },
                publishStatus: { status in
                    statuses.append(status)
                    if !status.isRefreshing { published.fulfill() }
                }
            ),
            .started
        )
        wait(for: [providerStarted], timeout: 1)

        liveSelection = [TestWindow(id: 9, revision: 1)]
        stateLock.lock()
        let completion = providerCompletion
        stateLock.unlock()
        completion?(.success(TestSnapshot(
            model: "candidate snapshot",
            windows: [TestWindow(id: 7, revision: 2), TestWindow(id: 8, revision: 2)]
        )))

        wait(for: [published], timeout: 1)
        XCTAssertEqual(appliedSnapshotModels, ["candidate snapshot"])
        XCTAssertEqual(visibleModel, "candidate snapshot")
        XCTAssertEqual(visibleSelection, [])
        XCTAssertEqual(statuses, [
            WindowSelectorRefreshStatus(isReady: false, isRefreshing: true, errorMessage: nil),
            WindowSelectorRefreshStatus(
                isReady: true,
                isRefreshing: false,
                errorMessage: "The selected window is no longer available. Select a window and try again."
            ),
        ])
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

        XCTAssertTrue(selector.contains("WindowSelectorRefreshCoordinator<"))
        XCTAssertTrue(selector.contains("refreshCoordinator.refresh("))
        XCTAssertTrue(selector.contains("self?.windowThumbnails = model"))
        XCTAssertEqual(selector.components(separatedBy: "self?.windowThumbnails =").count - 1, 1)
        XCTAssertTrue(selector.contains("accessibilityIdentifier(\"window-refresh-error\")"))
        XCTAssertTrue(selector.contains(".disabled(viewModel.isRefreshing)"))
        XCTAssertFalse(selector.contains("windowThumbnails[d]"))
        XCTAssertFalse(selector.contains("sampleHandlerQueue: .main"))
        XCTAssertTrue(provider.contains("sampleHandlerQueue: stateQueue"))
        XCTAssertTrue(provider.contains("private let stateQueue = DispatchQueue("))
        XCTAssertTrue(provider.contains("startRegistry.start(stream)"))
        XCTAssertFalse(provider.contains("Task { [weak self]"))
        XCTAssertTrue(provider.contains("@unchecked Sendable"))
        XCTAssertGreaterThanOrEqual(provider.components(separatedBy: "stateQueue.async").count - 1, 4)
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

    func testProductionRefreshCoordinatorKeepsMainRunLoopResponsiveUntilOnePublication() {
        struct TestWindow: Equatable {
            let id: Int
            let revision: Int
        }
        struct TestSnapshot {
            let windows: [TestWindow]
        }

        let published = expectation(description: "published")
        let heartbeatLock = NSLock()
        let providerLock = NSLock()
        var heartbeatCount = 0
        var providerRanOnMainThread: Bool?
        var appliedSnapshotCount = 0
        var publishedModel = [Int]()
        var publishedSelection = [TestWindow]()
        var statuses = [WindowSelectorRefreshStatus]()
        let coordinator = WindowSelectorRefreshCoordinator<Int, TestSnapshot, [Int], TestWindow, Int>(
            timeout: 1,
            candidateModel: { $0.windows.map(\.id) },
            candidateItems: { $0.windows },
            identifier: \.id,
            isModelEmpty: { $0.isEmpty },
            providerFactory: { _ in
                { complete in
                    providerLock.lock()
                    providerRanOnMainThread = Thread.isMainThread
                    providerLock.unlock()
                    Thread.sleep(forTimeInterval: 0.2)
                    complete(.success(TestSnapshot(windows: (0..<12).map {
                        TestWindow(id: $0, revision: 1)
                    })))
                    return {}
                }
            }
        )
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
                coordinator.refresh(
                    request: 0,
                    currentModel: { [-1] },
                    currentSelection: { [TestWindow(id: 5, revision: 0)] },
                    applySnapshot: { _ in
                        XCTAssertTrue(Thread.isMainThread)
                        appliedSnapshotCount += 1
                    },
                    applyModel: { publishedModel = $0 },
                    updateSelection: { publishedSelection = $0 },
                    publishStatus: { status in
                        statuses.append(status)
                        if !status.isRefreshing { published.fulfill() }
                    }
                ),
                .started
            )
        }

        wait(for: [published], timeout: 1)
        heartbeat.cancel()
        heartbeatLock.lock()
        let observedHeartbeats = heartbeatCount
        heartbeatLock.unlock()
        providerLock.lock()
        let observedProviderRanOnMainThread = providerRanOnMainThread
        providerLock.unlock()

        XCTAssertGreaterThanOrEqual(observedHeartbeats, 5)
        XCTAssertEqual(observedProviderRanOnMainThread, false)
        XCTAssertEqual(appliedSnapshotCount, 1)
        XCTAssertEqual(publishedModel, Array(0..<12))
        XCTAssertEqual(publishedSelection, [TestWindow(id: 5, revision: 1)])
        XCTAssertEqual(statuses, [
            WindowSelectorRefreshStatus(isReady: false, isRefreshing: true, errorMessage: nil),
            WindowSelectorRefreshStatus(isReady: true, isRefreshing: false, errorMessage: nil),
        ])
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

    func testTimeoutCancelsProductionCoordinatorProviderBeforeVisibleFailure() {
        struct TestSnapshot {
            let windows: [Int]
        }

        let timedOut = expectation(description: "timed out")
        let cancelled = expectation(description: "provider cancelled")
        let quietPeriodElapsed = expectation(description: "quiet period elapsed")
        let workQueue = DispatchQueue(label: "window-refresh-cancellable-work-test")
        let workTimer = DispatchSource.makeTimerSource(queue: workQueue)
        let workLock = NSLock()
        var workCount = 0
        var cancellationCount = 0
        let coordinator = WindowSelectorRefreshCoordinator<Int, TestSnapshot, [Int], Int, Int>(
            timeout: 0.08,
            candidateModel: { $0.windows },
            candidateItems: { $0.windows },
            identifier: { $0 },
            isModelEmpty: { $0.isEmpty },
            providerFactory: { _ in
                { _ in
                    workTimer.schedule(deadline: .now(), repeating: 0.01)
                    workTimer.setEventHandler {
                        workLock.lock()
                        workCount += 1
                        workLock.unlock()
                    }
                    workTimer.resume()
                    return {
                        workLock.lock()
                        cancellationCount += 1
                        workLock.unlock()
                        workTimer.cancel()
                        cancelled.fulfill()
                    }
                }
            }
        )

        XCTAssertEqual(
            coordinator.refresh(
                request: 0,
                currentModel: { [] },
                currentSelection: { [] },
                applySnapshot: { _ in
                    XCTFail("Timed-out provider must not apply a snapshot")
                },
                applyModel: { _ in
                    XCTFail("Timed-out provider must not replace the model")
                },
                updateSelection: { _ in
                    XCTFail("Timed-out provider must not change the selection")
                },
                publishStatus: { status in
                    if status.errorMessage == WindowSelectorRefreshError.timedOut.userMessage {
                        workLock.lock()
                        let cleanupFinishedBeforePublication = cancellationCount == 1
                        workLock.unlock()
                        XCTAssertTrue(cleanupFinishedBeforePublication)
                        timedOut.fulfill()
                    }
                }
            ),
            .started
        )

        wait(for: [timedOut, cancelled], timeout: 1)
        workQueue.sync {}
        workLock.lock()
        let workAtCancellation = workCount
        workLock.unlock()
        workQueue.asyncAfter(deadline: .now() + 0.1) {
            quietPeriodElapsed.fulfill()
        }
        wait(for: [quietPeriodElapsed], timeout: 1)
        workQueue.sync {}
        workLock.lock()
        let workAfterQuietPeriod = workCount
        let observedCancellationCount = cancellationCount
        workLock.unlock()

        XCTAssertGreaterThan(workAtCancellation, 0)
        XCTAssertEqual(workAfterQuietPeriod, workAtCancellation)
        XCTAssertEqual(observedCancellationCount, 1)
    }

    func testShippingThumbnailStartRegistryStopsACaptureThatFinishesStartingAfterCancellation() {
        final class TestStream {}

        let startEntered = expectation(description: "start entered")
        let stopped = expectation(description: "stream stopped before and after late start")
        stopped.expectedFulfillmentCount = 2
        let releaseStart = WindowSelectorTestAsyncGate()
        let activity = WindowSelectorTestCaptureActivity()
        let stream = TestStream()
        let registry = WindowSelectorThumbnailStartRegistry<TestStream>(
            start: { _ in
                startEntered.fulfill()
                await releaseStart.wait()
                activity.start()
            },
            stop: { _ in
                activity.stop()
                stopped.fulfill()
            }
        )

        registry.start(stream) { error in
            activity.fail(error)
        }
        wait(for: [startEntered], timeout: 1)

        registry.cancelAll([stream])
        let stateAtCancellationReturn = activity.snapshot()
        XCTAssertFalse(stateAtCancellationReturn.0)
        XCTAssertEqual(stateAtCancellationReturn.1, 1)

        releaseStart.open()
        wait(for: [stopped], timeout: 1)
        let finalState = activity.snapshot()
        XCTAssertFalse(finalState.0)
        XCTAssertEqual(finalState.1, 2)
        XCTAssertTrue(finalState.2.isEmpty)
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

    func testRefreshDuringQueuedPublicationIsCoalescedWithoutDuplicateProviderWork() {
        let publicationQueue = DispatchQueue(label: "window-refresh-publication-test")
        let publicationQueueBlocked = DispatchSemaphore(value: 0)
        let releasePublicationQueue = DispatchSemaphore(value: 0)
        publicationQueue.async {
            publicationQueueBlocked.signal()
            releasePublicationQueue.wait()
        }
        XCTAssertEqual(publicationQueueBlocked.wait(timeout: .now() + 1), .success)

        let firstProviderFinished = expectation(description: "first provider finished")
        let firstPublished = expectation(description: "first published")
        let postPublicationRefreshPublished = expectation(description: "post-publication refresh published")
        let adapter = WindowSelectorRefreshAdapter<Int>(
            timeout: 1,
            publicationQueue: publicationQueue
        )
        let lock = NSLock()
        var providerCount = 0
        var publications = [Int]()

        XCTAssertEqual(
            adapter.refresh(using: { complete in
                lock.lock()
                providerCount += 1
                lock.unlock()
                complete(.success(1))
                firstProviderFinished.fulfill()
                return {}
            }, publish: { result in
                if case .success(let value) = result {
                    lock.lock()
                    publications.append(value)
                    lock.unlock()
                }
                firstPublished.fulfill()
            }),
            .started
        )
        wait(for: [firstProviderFinished], timeout: 1)

        XCTAssertEqual(
            adapter.refresh(using: { _ in
                XCTFail("A refresh awaiting publication must not start another provider")
                return {}
            }, publish: { _ in
                XCTFail("A coalesced refresh must not publish")
            }),
            .coalesced
        )

        releasePublicationQueue.signal()
        wait(for: [firstPublished], timeout: 1)

        XCTAssertEqual(
            adapter.refresh(using: { complete in
                lock.lock()
                providerCount += 1
                lock.unlock()
                complete(.success(3))
                return {}
            }, publish: { result in
                if case .success(let value) = result {
                    lock.lock()
                    publications.append(value)
                    lock.unlock()
                }
                postPublicationRefreshPublished.fulfill()
            }),
            .started
        )

        wait(for: [postPublicationRefreshPublished], timeout: 1)
        lock.lock()
        let observedPublications = publications
        let observedProviderCount = providerCount
        lock.unlock()
        XCTAssertEqual(observedProviderCount, 2)
        XCTAssertEqual(observedPublications, [1, 3])
    }

    func testQueuedPublicationUsesLatestLiveSelectionWhileRefreshIsCoalesced() {
        struct TestWindow: Equatable {
            let id: Int
            let revision: Int
        }
        struct TestSnapshot {
            let generation: Int
            let windows: [TestWindow]
        }

        let publicationQueue = DispatchQueue(label: "window-refresh-live-selection-generation-test")
        let publicationQueueBlocked = DispatchSemaphore(value: 0)
        let releasePublicationQueue = DispatchSemaphore(value: 0)
        publicationQueue.async {
            publicationQueueBlocked.signal()
            releasePublicationQueue.wait()
        }
        XCTAssertEqual(publicationQueueBlocked.wait(timeout: .now() + 1), .success)

        let firstProviderFinished = expectation(description: "first provider finished")
        let firstPublished = expectation(description: "first generation published")
        let pipeline = WindowSelectorRefreshPipeline<TestSnapshot, Int, TestWindow, Int>(
            timeout: 1,
            publicationQueue: publicationQueue,
            candidateModel: { $0.generation },
            candidateItems: { $0.windows },
            identifier: \.id
        )
        let stateLock = NSLock()
        var liveSelection = [TestWindow(id: 7, revision: 1)]
        var reconciledGenerations = [Int]()
        var observedSelection = [TestWindow]()
        var providerCount = 0

        XCTAssertEqual(
            pipeline.refresh(
                currentModel: { 0 },
                currentSelection: {
                    stateLock.lock()
                    defer { stateLock.unlock() }
                    return liveSelection
                },
                using: { completion in
                    stateLock.lock()
                    providerCount += 1
                    stateLock.unlock()
                    completion(.success(TestSnapshot(
                        generation: 1,
                        windows: [TestWindow(id: 7, revision: 2), TestWindow(id: 9, revision: 2)]
                    )))
                    firstProviderFinished.fulfill()
                    return {}
                }, publish: { result in
                guard case .success(let publication) = result else { return }
                stateLock.lock()
                reconciledGenerations.append(publication.resolution.model)
                observedSelection = publication.resolution.selection
                stateLock.unlock()
                firstPublished.fulfill()
            }),
            .started
        )
        wait(for: [firstProviderFinished], timeout: 1)

        stateLock.lock()
        liveSelection = [TestWindow(id: 8, revision: 1)]
        stateLock.unlock()
        XCTAssertEqual(
            pipeline.refresh(
                currentModel: { 0 },
                currentSelection: { [] },
                using: { _ in
                    XCTFail("A queued publication must coalesce another provider request")
                    return {}
                }, publish: { _ in
                XCTFail("A coalesced request must not publish")
            }),
            .coalesced
        )

        stateLock.lock()
        liveSelection = [TestWindow(id: 9, revision: 1)]
        stateLock.unlock()

        releasePublicationQueue.signal()
        wait(for: [firstPublished], timeout: 1)
        stateLock.lock()
        let observedGenerations = reconciledGenerations
        let finalSelection = observedSelection
        let observedProviderCount = providerCount
        stateLock.unlock()
        XCTAssertEqual(observedProviderCount, 1)
        XCTAssertEqual(observedGenerations, [1])
        XCTAssertEqual(finalSelection, [TestWindow(id: 9, revision: 2)])
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
        let beforePublish = publicationBoundary[..<publish.lowerBound]
        guard let unlock = beforePublish.range(of: "lock.unlock()", options: .backwards) else {
            return XCTFail("Publication boundary must unlock before invoking the callback")
        }
        XCTAssertFalse(
            beforePublish[unlock.upperBound...].contains("lock.lock()"),
            "External publication callbacks must never run while the adapter lock is held"
        )
    }

    func testPublicationCallbackCoalescesRefreshUntilItReturnsThenAllowsNextGeneration() {
        let publicationQueue = DispatchQueue(label: "window-refresh-reentrant-start-test")
        let adapter = WindowSelectorRefreshAdapter<Int>(
            timeout: 1,
            publicationQueue: publicationQueue
        )
        let firstPublished = expectation(description: "first generation published")
        let secondPublished = expectation(description: "second generation published")
        let lock = NSLock()
        var providerCount = 0
        var publications = [Int]()

        XCTAssertEqual(
            adapter.refresh(using: { complete in
                lock.lock()
                providerCount += 1
                lock.unlock()
                complete(.success(1))
                return {}
            }, publish: { result in
                if case .success(let value) = result {
                    lock.lock()
                    publications.append(value)
                    lock.unlock()
                }
                XCTAssertEqual(
                    adapter.refresh(using: { _ in
                        XCTFail("A refresh inside publication must not start another provider")
                        return {}
                    }, publish: { _ in
                        XCTFail("A coalesced refresh must not publish")
                    }),
                    .coalesced
                )
                firstPublished.fulfill()
            }),
            .started
        )

        wait(for: [firstPublished], timeout: 1)
        XCTAssertEqual(
            adapter.refresh(using: { complete in
                lock.lock()
                providerCount += 1
                lock.unlock()
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

        wait(for: [secondPublished], timeout: 1)
        lock.lock()
        let observedPublications = publications
        let observedProviderCount = providerCount
        lock.unlock()
        XCTAssertEqual(observedProviderCount, 2)
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

    private final class WindowSelectorTestAsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters = [CheckedContinuation<Void, Never>]()

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let currentWaiters = waiters
            waiters.removeAll()
            lock.unlock()
            currentWaiters.forEach { $0.resume() }
        }
    }

    private final class WindowSelectorTestCaptureActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var isCapturing = false
        private var stopCount = 0
        private var failures = [String]()

        func start() {
            lock.lock()
            isCapturing = true
            lock.unlock()
        }

        func stop() {
            lock.lock()
            isCapturing = false
            stopCount += 1
            lock.unlock()
        }

        func fail(_ error: Error) {
            lock.lock()
            failures.append(error.localizedDescription)
            lock.unlock()
        }

        func snapshot() -> (Bool, Int, [String]) {
            lock.lock()
            defer { lock.unlock() }
            return (isCapturing, stopCount, failures)
        }
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectRoot = testsDirectory.deletingLastPathComponent()
        return try String(contentsOf: projectRoot.appendingPathComponent(relativePath))
    }
}
