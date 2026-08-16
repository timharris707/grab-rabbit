import AppKit
import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

struct WindowSelectorRefreshSnapshot {
    let content: SCShareableContent
    let windows: [SCWindow]
    let thumbnails: [SCDisplay: [WindowThumbnail]]
}

final class WindowSelectorThumbnailProvider: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    typealias Completion = WindowSelectorRefreshAdapter<WindowSelectorRefreshSnapshot>.Completion
    private static let maximumConcurrentThumbnailCaptures = 12

    private struct StreamEntry {
        let window: SCWindow
        let displays: [SCDisplay]
    }

    private let filterUntitledWindows: Bool
    private let captureThumbnails: Bool
    private let stateQueue = DispatchQueue(
        label: "dev.clickai.grabrabbit.window-thumbnail-provider",
        qos: .userInitiated
    )
    private let stateQueueKey = DispatchSpecificKey<Void>()
    private let startRegistry = WindowSelectorThumbnailStartRegistry<SCStream>(
        start: { try await $0.startCapture() },
        stop: { try await $0.stopCapture() }
    )
    private var completion: Completion?
    private var content: SCShareableContent?
    private var streams = [SCStream]()
    private var entries = [ObjectIdentifier: StreamEntry]()
    private var batch = WindowSelectorThumbnailBatch<ObjectIdentifier>()
    private var windows = [SCWindow]()
    private var thumbnails = [SCDisplay: [WindowThumbnail]]()
    private var finished = false
    private var cleanupStarted = false
    private var cleanupComplete = false
    private var pendingTerminalResult: Result<WindowSelectorRefreshSnapshot, WindowSelectorRefreshError>?
    private var cleanupCompletions = [() -> Void]()

    init(filterUntitledWindows: Bool, captureThumbnails: Bool) {
        self.filterUntitledWindows = filterUntitledWindows
        self.captureThumbnails = captureThumbnails
        super.init()
        stateQueue.setSpecific(key: stateQueueKey, value: ())
    }

    func start(completion: @escaping Completion) {
        stateQueue.async {
            guard !self.finished else { return }
            self.completion = completion
            SCContext.fetchWindowSelectorContent { result in
                self.stateQueue.async {
                    switch result {
                    case .success(let content):
                        self.prepare(content)
                    case .failure(.permissionDenied):
                        self.finish(with: .failure(.permissionDenied))
                    case .failure(.unavailable(let message)):
                        self.fail(message)
                    }
                }
            }
        }
    }

    func cancel(completion: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            cancelOnStateQueue(completion: completion)
        } else {
            stateQueue.async {
                self.cancelOnStateQueue(completion: completion)
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        guard resolve(
            stream,
            image: sampleBuffer.nsImage ?? NSImage(named: "unknowScreen")!
        ) else { return }
        startRegistry.stop(stream)
    }

    func stream(_ stream: SCStream, didStopWithError _: Error) {
        stateQueue.async {
            self.startRegistry.confirmStopped(stream)
            self.recordFallback(for: stream)
        }
    }

    private func prepare(_ content: SCShareableContent) {
        guard !finished else { return }
        self.content = content
        windows = eligibleWindows(from: content)
        let plan = WindowSelectorThumbnailCapturePlan.make(
            windows: windows,
            captureThumbnails: captureThumbnails,
            maximumCaptures: Self.maximumConcurrentThumbnailCaptures
        )

        for window in plan.placeholders {
            appendPlaceholder(for: window, in: content)
        }

        guard !plan.captured.isEmpty else {
            succeed()
            return
        }

        for window in plan.captured {
            let stream = SCStream(
                filter: SCContentFilter(desktopIndependentWindow: window),
                configuration: thumbnailConfiguration(for: window),
                delegate: self
            )
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: stateQueue)
                let identifier = ObjectIdentifier(stream)
                entries[identifier] = StreamEntry(
                    window: window,
                    displays: displays(for: window, in: content)
                )
                batch.register(identifier)
                streams.append(stream)
            } catch {
                appendPlaceholder(for: window, in: content)
            }
        }

        guard !streams.isEmpty else {
            succeed()
            return
        }

        for stream in streams {
            startRegistry.start(stream) { [weak self] error in
                self?.stateQueue.async {
                    self?.recordFallback(for: stream)
                }
            }
        }
    }

    private func eligibleWindows(from content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            guard let app = window.owningApplication,
                  let title = window.title else { return false }
            return !SCContext.excludedApps.contains(app.bundleIdentifier)
                && !title.contains("Item-0")
                && title != "Window"
                && window.frame.width > 40
                && window.frame.height > 40
                && window.isOnScreen
                && !(ud.bool(forKey: "hideSelf") && app.bundleIdentifier == Bundle.main.bundleIdentifier)
                && !(title.isEmpty && app.bundleIdentifier == "com.apple.finder")
                && app.bundleIdentifier != Bundle.main.bundleIdentifier
                && !app.applicationName.isEmpty
                && (!filterUntitledWindows || !title.isEmpty)
        }
    }

    private func displays(for window: SCWindow, in content: SCShareableContent) -> [SCDisplay] {
        content.displays.filter { NSIntersectsRect(window.frame, $0.frame) }
    }

    private func recordFallback(for stream: SCStream) {
        _ = resolve(stream, image: NSImage(named: "unknowScreen")!)
    }

    private func resolve(_ stream: SCStream, image: NSImage) -> Bool {
        let identifier = ObjectIdentifier(stream)
        guard !finished,
              let entry = entries[identifier],
              let isComplete = batch.resolve(identifier) else { return false }
        appendThumbnail(image, for: entry)
        if isComplete {
            succeed()
        }
        return true
    }

    private func appendPlaceholder(for window: SCWindow, in content: SCShareableContent) {
        appendThumbnail(
            NSImage(named: "unknowScreen")!,
            for: StreamEntry(window: window, displays: displays(for: window, in: content))
        )
    }

    private func appendThumbnail(_ image: NSImage, for entry: StreamEntry) {
        let thumbnail = WindowThumbnail(image: image, window: entry.window)
        entry.displays.forEach { display in
            thumbnails[display, default: []].append(thumbnail)
        }
    }

    private func thumbnailConfiguration(for window: SCWindow) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let factor = window.frame.width < 200 && window.frame.height < 200 ? 1.0 : 0.5
        configuration.width = Int(window.frame.width * factor)
        configuration.height = Int(window.frame.height * factor)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 13, *) {
            configuration.capturesAudio = false
        }
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.queueDepth = 3
        return configuration
    }

    private func succeed() {
        guard !finished, let content else { return }
        let snapshot = WindowSelectorRefreshSnapshot(
            content: content,
            windows: windows,
            thumbnails: thumbnails
        )
        finish(with: .success(snapshot))
    }

    private func fail(_ message: String) {
        finish(with: .failure(.unavailable(message)))
    }

    private func finish(with result: Result<WindowSelectorRefreshSnapshot, WindowSelectorRefreshError>) {
        guard !finished else { return }
        finished = true
        pendingTerminalResult = result
        beginCleanup()
        deliverPendingFailure()
    }

    private func cancelOnStateQueue(completion: @escaping () -> Void) {
        if cleanupComplete {
            completion()
            return
        }
        cleanupCompletions.append(completion)
        if !finished {
            finished = true
            pendingTerminalResult = nil
            self.completion = nil
        }
        beginCleanup()
    }

    private func beginCleanup() {
        guard !cleanupStarted else { return }
        cleanupStarted = true
        startRegistry.stopAll(
            onFailure: { [self] error in
                stateQueue.async {
                    self.cleanupFailed(error)
                }
            },
            completion: { [self] in
                stateQueue.async {
                    self.completeCleanup()
                }
            }
        )
    }

    private func cleanupFailed(_ error: Error) {
        guard !cleanupComplete else { return }
        if case .success? = pendingTerminalResult {
            pendingTerminalResult = .failure(.unavailable(error.localizedDescription))
        }
        deliverPendingFailure()
    }

    private func deliverPendingFailure() {
        guard case .failure = pendingTerminalResult,
              let result = pendingTerminalResult,
              let completion else { return }
        pendingTerminalResult = nil
        self.completion = nil
        completion(result)
    }

    private func completeCleanup() {
        guard !cleanupComplete else { return }
        cleanupComplete = true
        let result = pendingTerminalResult
        let completion = self.completion
        let cleanupCompletions = self.cleanupCompletions
        pendingTerminalResult = nil
        self.completion = nil
        self.cleanupCompletions.removeAll()

        streams.removeAll()
        entries.removeAll()
        batch.removeAll()
        content = nil
        windows.removeAll()
        thumbnails.removeAll()

        if let result {
            completion?(result)
        }
        cleanupCompletions.forEach { $0() }
    }
}

final class WindowThumbnail {
    let image: NSImage
    let window: SCWindow

    init(image: NSImage, window: SCWindow) {
        self.image = image
        self.window = window
    }
}
