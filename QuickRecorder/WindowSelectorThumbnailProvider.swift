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
    private var completion: Completion?
    private var content: SCShareableContent?
    private var streams = [SCStream]()
    private var entries = [ObjectIdentifier: StreamEntry]()
    private var pendingStreams = Set<ObjectIdentifier>()
    private var windows = [SCWindow]()
    private var thumbnails = [SCDisplay: [WindowThumbnail]]()
    private var finished = false

    init(filterUntitledWindows: Bool, captureThumbnails: Bool) {
        self.filterUntitledWindows = filterUntitledWindows
        self.captureThumbnails = captureThumbnails
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

    func cancel() {
        stateQueue.async {
            guard !self.finished else { return }
            self.finished = true
            self.stopAllStreams()
            self.completion = nil
            self.content = nil
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        let identifier = ObjectIdentifier(stream)
        guard !finished,
              pendingStreams.remove(identifier) != nil,
              let entry = entries[identifier] else { return }

        let thumbnail = WindowThumbnail(
            image: sampleBuffer.nsImage ?? NSImage(named: "unknowScreen")!,
            window: entry.window
        )
        entry.displays.forEach { display in
            thumbnails[display, default: []].append(thumbnail)
        }
        stream.stopCapture()
        if pendingStreams.isEmpty {
            succeed()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateQueue.async {
            guard !self.finished,
                  self.pendingStreams.contains(ObjectIdentifier(stream)) else { return }
            self.fail(error.localizedDescription)
        }
    }

    private func prepare(_ content: SCShareableContent) {
        guard !finished else { return }
        self.content = content
        windows = eligibleWindows(from: content)

        guard captureThumbnails else {
            for window in windows {
                let thumbnail = WindowThumbnail(
                    image: NSImage(named: "unknowScreen")!,
                    window: window
                )
                displays(for: window, in: content).forEach { display in
                    thumbnails[display, default: []].append(thumbnail)
                }
            }
            succeed()
            return
        }

        do {
            for window in windows {
                let stream = SCStream(
                    filter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: thumbnailConfiguration(for: window),
                    delegate: self
                )
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: stateQueue)
                let identifier = ObjectIdentifier(stream)
                entries[identifier] = StreamEntry(
                    window: window,
                    displays: displays(for: window, in: content)
                )
                pendingStreams.insert(identifier)
                streams.append(stream)
            }
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard !streams.isEmpty else {
            succeed()
            return
        }

        for stream in streams {
            Task { [weak self] in
                do {
                    try await stream.startCapture()
                    self?.stateQueue.async {
                        if self?.finished == true {
                            stream.stopCapture()
                        }
                    }
                } catch {
                    self?.stateQueue.async {
                        self?.fail(error.localizedDescription)
                    }
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
        finished = true
        let completion = self.completion
        let snapshot = WindowSelectorRefreshSnapshot(
            content: content,
            windows: windows,
            thumbnails: thumbnails
        )
        stopAllStreams()
        self.completion = nil
        self.content = nil
        completion?(.success(snapshot))
    }

    private func fail(_ message: String) {
        finish(with: .failure(.unavailable(message)))
    }

    private func finish(with result: Result<WindowSelectorRefreshSnapshot, WindowSelectorRefreshError>) {
        guard !finished else { return }
        finished = true
        let completion = self.completion
        stopAllStreams()
        self.completion = nil
        content = nil
        windows.removeAll()
        completion?(result)
    }

    private func stopAllStreams() {
        streams.forEach { $0.stopCapture() }
        streams.removeAll()
        entries.removeAll()
        pendingStreams.removeAll()
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
