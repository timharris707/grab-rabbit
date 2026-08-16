import AVFoundation
import CoreMedia
import Foundation
import LiveProbeCore
import ScreenCaptureKit

enum LiveSourceDiscovery {
    static func cameraDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.sorted { $0.localizedName < $1.localizedName }
    }

    static func cameras() -> [StableCameraSource] {
        cameraDevices().map {
            StableCameraSource(
                uniqueID: $0.uniqueID,
                name: $0.localizedName,
                deviceType: $0.deviceType.rawValue
            )
        }
    }

    static func windows() async throws -> (models: [CapturableWindowSource], native: [SCWindow]) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter { window in
            window.owningApplication != nil
                && window.frame.width >= 2
                && window.frame.height >= 2
                && window.windowID != 0
        }.sorted { lhs, rhs in
            let leftApp = lhs.owningApplication?.applicationName ?? ""
            let rightApp = rhs.owningApplication?.applicationName ?? ""
            if leftApp == rightApp { return lhs.windowID < rhs.windowID }
            return leftApp < rightApp
        }
        let models = windows.map { window in
            CapturableWindowSource(
                windowID: window.windowID,
                title: window.title ?? "",
                applicationName: window.owningApplication?.applicationName ?? "",
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                width: Int(window.frame.width.rounded()),
                height: Int(window.frame.height.rounded())
            )
        }
        return (models, windows)
    }

    static func inventory(queryWindows: Bool) async -> (LiveSourceInventory, [SCWindow]) {
        let authorization = AuthorizationSnapshot.current()
        var windows = [CapturableWindowSource]()
        var nativeWindows = [SCWindow]()
        let windowQuery: String
        if !queryWindows {
            windowQuery = "skipped-by-command"
        } else if !authorization.screenCapturePreflightGranted {
            windowQuery = "skipped-screen-authorization-not-granted-no-request-made"
        } else {
            do {
                let discovered = try await self.windows()
                windows = discovered.models
                nativeWindows = discovered.native
                windowQuery = "queried-real-windows-only"
            } catch {
                windowQuery = "failed: \(error.localizedDescription)"
            }
        }
        return (
            LiveSourceInventory(
                generatedAt: iso8601Now(),
                cameras: cameras(),
                windows: windows,
                authorization: authorization,
                signing: RuntimeSigningIdentity.current(),
                windowQuery: windowQuery
            ),
            nativeWindows
        )
    }
}

final class ScreenSampleDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
    let coordinator: LiveCaptureCoordinator

    init(coordinator: LiveCaptureCoordinator) {
        self.coordinator = coordinator
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        coordinator.requestStop(reason: "screen-stream-stopped: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                  ) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  sampleBuffer.imageBuffer != nil else { return }
            coordinator.receiveWindow(sampleBuffer)
        case .audio:
            coordinator.receiveAudio(sampleBuffer, system: true)
        default:
            break
        }
    }
}

final class LiveCaptureRuntime: @unchecked Sendable {
    private let coordinator: LiveCaptureCoordinator
    private let cameraDevice: AVCaptureDevice
    private let window: SCWindow?
    private let includeSystemAudio: Bool
    private let includeMicrophone: Bool
    private let cameraSession = AVCaptureSession()
    private var cameraDelegate: CameraSampleDelegate?
    private var screenDelegate: ScreenSampleDelegate?
    private var screenStream: SCStream?
    private var disconnectObserver: NSObjectProtocol?
    private let clearBackgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0)

    init(
        coordinator: LiveCaptureCoordinator,
        cameraDevice: AVCaptureDevice,
        window: SCWindow?,
        includeSystemAudio: Bool,
        includeMicrophone: Bool
    ) {
        self.coordinator = coordinator
        self.cameraDevice = cameraDevice
        self.window = window
        self.includeSystemAudio = includeSystemAudio
        self.includeMicrophone = includeMicrophone
    }

    func start() async throws {
        try configureCamera()
        if let window { try await configureScreen(window: window) }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let disconnected = notification.object as? AVCaptureDevice,
                  disconnected.uniqueID == self.cameraDevice.uniqueID else { return }
            self.coordinator.selectedCameraDisconnected(uniqueID: disconnected.uniqueID)
        }
        cameraSession.startRunning()
        guard cameraSession.isRunning else { throw LiveProbeError.capture("camera session did not start") }
        if let screenStream { try await screenStream.startCapture() }
        coordinator.startFixedClockIfNeeded()
        coordinator.statistics.event("capture-started")
    }

    func stop() async {
        if let screenStream { try? await screenStream.stopCapture() }
        if cameraSession.isRunning { cameraSession.stopRunning() }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = nil
        coordinator.statistics.event("capture-stopped")
    }

    private func configureCamera() throws {
        cameraSession.beginConfiguration()
        defer { cameraSession.commitConfiguration() }
        cameraSession.sessionPreset = .high
        let cameraInput = try AVCaptureDeviceInput(device: cameraDevice)
        guard cameraSession.canAddInput(cameraInput) else {
            throw LiveProbeError.capture("cannot add exact selected camera input")
        }
        cameraSession.addInput(cameraInput)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        let delegate = CameraSampleDelegate(coordinator: coordinator)
        delegate.videoOutput = videoOutput
        videoOutput.setSampleBufferDelegate(delegate, queue: coordinator.sampleQueue)
        guard cameraSession.canAddOutput(videoOutput) else {
            throw LiveProbeError.capture("cannot add camera video-data output")
        }
        cameraSession.addOutput(videoOutput)
        if includeMicrophone {
            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                throw LiveProbeError.capture("no microphone device available")
            }
            let microphoneInput = try AVCaptureDeviceInput(device: microphone)
            guard cameraSession.canAddInput(microphoneInput) else {
                throw LiveProbeError.capture("cannot add microphone input")
            }
            cameraSession.addInput(microphoneInput)
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(delegate, queue: coordinator.sampleQueue)
            guard cameraSession.canAddOutput(audioOutput) else {
                throw LiveProbeError.capture("cannot add microphone audio-data output")
            }
            cameraSession.addOutput(audioOutput)
        }
        cameraDelegate = delegate
    }

    private func configureScreen(window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = filter.pointPixelScale
        configuration.width = max(2, Int((filter.contentRect.width * CGFloat(scale)).rounded()))
        configuration.height = max(2, Int((filter.contentRect.height * CGFloat(scale)).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = .zero
        configuration.queueDepth = 6
        configuration.showsCursor = false
        configuration.backgroundColor = clearBackgroundColor
        configuration.capturesAudio = includeSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let delegate = ScreenSampleDelegate(coordinator: coordinator)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: coordinator.sampleQueue)
        if includeSystemAudio {
            try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: coordinator.sampleQueue)
        }
        screenDelegate = delegate
        screenStream = stream
    }
}
