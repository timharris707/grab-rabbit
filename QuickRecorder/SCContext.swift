//
//  SCContext.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import AVFAudio
import AVFoundation
import Foundation
import ScreenCaptureKit
import UserNotifications
import SwiftLAME
import SwiftUI
import AECAudioStream

class SCContext {
    static var trimingList = [URL]()
    static var firstFrame: CMSampleBuffer?
    static var autoStop = 0
    static var recordCam = ""
    static var recordDevice = ""
    static var captureSession: AVCaptureSession!
    static var previewSession: AVCaptureSession!
    static var frameCache: CMSampleBuffer?
    static var filter: SCContentFilter?
    static var isMagnifierEnabled = false
    static var saveFrame = false
    static var isPaused = false
    static var isResume = false
    static var isSkipFrame = false
    static var lastPTS: CMTime?
    static var timeOffset = CMTimeMake(value: 0, timescale: 0)
    static var screenArea: NSRect?
    static let audioEngine = AVAudioEngine()
    static let AECEngine = AECAudioStream(sampleRate: 48000)
    static var backgroundColor: CGColor = CGColor.black
    static var filePath: String!
    static var filePath1: String!
    static var filePath2: String!
    static var outputJob: RecordingOutputJob?
    static var audioFile: AVAudioFile?
    static var audioFile2: AVAudioFile?
    static var vW: AVAssetWriter!
    static var vwInput, awInput, micInput: AVAssetWriterInput!
    static var startTime: Date?
    static var timePassed: TimeInterval = 0
    static var stream: SCStream!
    static var screen: SCDisplay?
    static var window: [SCWindow]?
    static var application: [SCRunningApplication]?
    static var streamType: StreamType?
    static let excludedApps = ["", "com.apple.dock", "com.apple.screencaptureui", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.WindowManager", "dev.mnpn.Azayaka", "com.gaosun.eul", "com.pointum.hazeover", "net.matthewpalmer.Vanilla", "com.dwarvesv.minimalbar", "com.bjango.istatmenus.status"]

    private static let contentState = ScreenRecordingContentState<SCShareableContent> { isReady, revision in
        DispatchQueue.main.async {
            captureReadiness.update(isReady, revision: revision)
        }
    }

    static var availableContent: SCShareableContent? {
        contentState.content
    }

    private static let screenRecordingPermissionCoordinator = ScreenRecordingPermissionCoordinator<SCShareableContent> { dismiss in
        DispatchQueue.main.async {
            let alert = createAlert(
                title: "Permission Required",
                message: PermissionCopy.screenRecording(
                    productName: Bundle.main.appName,
                    localizedFormat: PermissionCopy.screenRecordingFormat.local
                ),
                button1: "Open Settings",
                button2: "Cancel"
            )
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            dismiss()
        }
    }
    
    static func updateAvailableContentSync() -> SCShareableContent? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent? = nil

        refreshAvailableContent { refreshResult in
            if case .success(let content) = refreshResult {
                result = content
            }
            semaphore.signal()
        }

        semaphore.wait()
        return result
    }
    
    static func updateAvailableContent(completion: @escaping () -> Void) {
        refreshAvailableContent { result in
            if case .success = result {
                completion()
            }
        }
    }

    static func refreshAvailableContent(completion: @escaping (Result<SCShareableContent, ScreenRecordingContentError>) -> Void) {
        screenRecordingPermissionCoordinator.refresh(using: fetchAvailableContent) { result in
            contentState.apply(result)
            switch result {
            case .success:
                scPerm = true
            case .failure(.permissionDenied):
                scPerm = false
                DispatchQueue.main.async {
                    captureReadiness.updateRecoveryActionAvailability(true)
                }
            case .failure(.unavailable(let message)):
                print("Error: failed to fetch available content: ".local, message)
            }
            completion(result)
        }
    }

    static func recoverScreenRecordingAccess() {
        if CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.async {
                captureReadiness.updateRecoveryActionAvailability(false)
            }
            refreshAvailableContent { _ in }
        } else {
            screenRecordingPermissionCoordinator.presentRecoveryIfNeeded()
        }
    }

    private static func fetchAvailableContent(completion: @escaping (Result<SCShareableContent, ScreenRecordingContentError>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let error {
                if case SCStreamError.userDeclined = error {
                    completion(.failure(.permissionDenied))
                } else {
                    completion(.failure(.unavailable(error.localizedDescription)))
                }
                return
            }
            guard let content, !content.displays.isEmpty else {
                completion(.failure(.unavailable("There needs to be at least one display connected!".local)))
                return
            }
            completion(.success(content))
        }
    }
    
    static func getSelf() -> SCRunningApplication? {
        return SCContext.availableContent!.applications.first(where: { Bundle.main.bundleIdentifier == $0.bundleIdentifier })
    }
    
    static func getSelfWindows() -> [SCWindow]? {
        return SCContext.availableContent!.windows.filter( {
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            && title != "Mouse Pointer".local
            && title != "Screen Magnifier".local
            && title != "Camera Overlayer".local
            && title != "iDevice Overlayer".local
        })
    }
    
    static func getApps(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCRunningApplication] {
        var apps = [SCRunningApplication]()
        for app in getWindows(isOnScreen: isOnScreen, hideSelf: hideSelf).map({ $0.owningApplication }) {
            if !apps.contains(app!) { apps.append(app!) }
        }
        if hideSelf && ud.bool(forKey: "hideSelf") { apps = apps.filter({$0.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return apps
    }
    
    static func getWindows(isOnScreen: Bool = true, hideSelf: Bool = true) -> [SCWindow] {
        var windows = [SCWindow]()
        windows = availableContent!.windows.filter {
            guard let app =  $0.owningApplication,
                  let title = $0.title else {//, !title.isEmpty else {
                return false
            }
            return !excludedApps.contains(app.bundleIdentifier)
            && !title.contains("Item-0")
            && title != "Window"
            && $0.frame.width > 40
            && $0.frame.height > 40
        }
        if isOnScreen { windows = windows.filter({$0.isOnScreen == true}) }
        if hideSelf && ud.bool(forKey: "hideSelf") { windows = windows.filter({$0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier}) }
        return windows
    }
    
    static func getAppIcon(_ app: SCRunningApplication) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 69, height: 69)
            return icon
        }
        let icon = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: "blank icon")
        icon!.size = NSSize(width: 69, height: 69)
        return icon
    }
    
    static func getScreenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let screenWithMouse = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
        return screenWithMouse
    }
    
    static func getSCDisplayWithMouse() -> SCDisplay? {
        if let displays = availableContent?.displays {
            for display in displays {
                if let currentDisplayID = getScreenWithMouse()?.displayID {
                    if display.displayID == currentDisplayID {
                        return display
                    }
                }
            }
        }
        return nil
    }
    
    static func reserveOutputJob(
        capture: Bool = false,
        layout: RecordingOutputJob.Layout,
        date: Date = Date()
    ) throws -> RecordingOutputJob {
        guard let saveDirectory = ud.string(forKey: "saveDirectory") else {
            throw RecordingOutputReservationError.invalidDirectory(URL(fileURLWithPath: ""))
        }
        return try RecordingOutputJob.reserve(
            in: URL(fileURLWithPath: saveDirectory, isDirectory: true),
            prefix: capture ? "Capturing at ".local : "Recording at ".local,
            date: date,
            layout: layout
        )
    }
    
    static func updateAudioSettings(
        format: String = ud.string(forKey: "audioFormat") ?? "",
        rate: Int = 48000,
        qualityKbps: Int? = nil
    ) -> [String : Any] {
        var audioSettings: [String : Any] = [AVSampleRateKey : rate, AVNumberOfChannelsKey : 2] // reset audioSettings
        var bitRate = (qualityKbps ?? ud.integer(forKey: "audioQuality")) * 1000
        if rate < 44100 { bitRate = min(64000, bitRate / 2) }
        switch format {
        case AudioFormat.mp3.rawValue: fallthrough
        case AudioFormat.aac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = bitRate
        case AudioFormat.alac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatAppleLossless
            audioSettings[AVEncoderBitDepthHintKey] = 16
        case AudioFormat.flac.rawValue:
            audioSettings[AVFormatIDKey] = kAudioFormatFLAC
        case AudioFormat.opus.rawValue:
            audioSettings[AVFormatIDKey] = ud.string(forKey: "videoFormat") != VideoFormat.mp4.rawValue ? kAudioFormatOpus : kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] =  bitRate
        default:
            assertionFailure("unknown audio format while setting audio settings: ".local + (ud.string(forKey: "audioFormat") ?? "[no defaults]".local))
        }
        return audioSettings
    }
    
    static func getBackgroundColor() -> CGColor {
        guard let color = ud.string(forKey: "background") else { return CGColor.black  }
        if color == BackgroundType.wallpaper.rawValue { return CGColor.black }
        switch color {
            case "clear": backgroundColor = CGColor.clear
            case "black": backgroundColor = CGColor.black
            case "white": backgroundColor = CGColor.white
            case "gray": backgroundColor = NSColor.systemGray.cgColor
            case "yellow": backgroundColor = NSColor.systemYellow.cgColor
            case "orange": backgroundColor = NSColor.systemOrange.cgColor
            case "green": backgroundColor = NSColor.systemGreen.cgColor
            case "blue": backgroundColor = NSColor.systemBlue.cgColor
            case "red": backgroundColor = NSColor.systemRed.cgColor
            default: backgroundColor = ud.cgColor(forKey: "userColor") ?? CGColor.black
        }
        return backgroundColor
    }
    
    static func performMicCheck() async {
        guard ud.bool(forKey: "recordMic") == true else { return }
        if await AVCaptureDevice.requestAccess(for: .audio) { return }

        ud.setValue(false, forKey: "recordMic")
        DispatchQueue.main.async {
            let alert = createAlert(
                title: "Permission Required",
                message: PermissionCopy.microphone(
                    productName: Bundle.main.appName,
                    localizedFormat: PermissionCopy.microphoneFormat.local
                ),
                button1: "Open Settings",
                button2: "Cancel"
            )
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
    
    static func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized, .restricted, .notDetermined:
            break
        case .denied:
            DispatchQueue.main.async {
                let alert = createAlert(
                    title: "Permission Required",
                    message: PermissionCopy.camera(
                        productName: Bundle.main.appName,
                        localizedFormat: PermissionCopy.cameraFormat.local
                    ),
                    button1: "Open Settings",
                    button2: "Cancel"
                )
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
        @unknown default:
            break
        }
    }
    
    static func getWallpaper(_ display: SCDisplay) -> NSImage? {
        guard let screen = display.nsScreen else { return nil }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        do {
            var wallpaper: NSImage?
            try wallpaper = NSImage(data: Data(contentsOf: url))
            if let w = wallpaper { return w }
        } catch {
            print("load wallpaper error: \(error)")
        }
        return nil
    }
    
    static func getRecordingSize() -> String {
        guard let activeOutputPath = outputJob?.inputURL.path ?? filePath else {
            return "Unknown".local
        }
        do {
            let fileAttr = try fd.attributesOfItem(atPath: activeOutputPath)
            let byteFormat = ByteCountFormatter()
            byteFormat.allowedUnits = [.useMB]
            byteFormat.countStyle = .file
            return byteFormat.string(fromByteCount: fileAttr[FileAttributeKey.size] as! Int64)
        } catch {
            print(String(format: "failed to fetch file for size indicator: %@".local, error.localizedDescription))
        }
        return "Unknown".local
    }
    
    static func getRecordingLength() -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        if isPaused { return formatter.string(from: timePassed) ?? "Unknown".local }
        timePassed = Date.now.timeIntervalSince(startTime ?? Date.now)
        return formatter.string(from: timePassed) ?? "Unknown".local
    }
    
    static func isCameraRunning() -> Bool {
        var preview = false
        var capture = false
        if let session = previewSession { preview = session.isRunning }
        if let session = captureSession { capture = session.isRunning }
        return (preview || capture)
    }
    
    static func pauseRecording() {
        isPaused.toggle()
        PopoverState.shared.isPaused = isPaused
        if !isPaused {
            isResume = true
            startTime = Date.now.addingTimeInterval(-1) - SCContext.timePassed
        }
    }
    
    static func stopRecording() {
        let finishedJob = outputJob
        let recordsMicrophone = finishedJob?.recordsMicrophone ?? ud.bool(forKey: "recordMic")
        let shouldRemuxVideo = finishedJob?.kind == .videoRemux
        var directVideoResult: Result<URL, RecordingExportError>?
        if ud.bool(forKey: "preventSleep") { SleepPreventer.shared.allowSleep() }
        autoStop = 0
        lastPTS = nil
        recordCam = ""
        recordDevice = ""
        isMagnifierEnabled = false
        mousePointer.orderOut(nil)
        screenMagnifier.orderOut(nil)
        AppDelegate.shared.stopGlobalMouseMonitor()

        if let w = NSApp.windows.first(where:  { $0.title == "Area Overlayer".local }) { w.close() }
        
        if stream != nil { stream.stopCapture() }
        stream = nil
        if recordsMicrophone {
            micInput.markAsFinished()
            AudioRecorder.shared.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            //DispatchQueue.global().async { try? audioEngine.inputNode.setVoiceProcessingEnabled(false) }
            if ud.bool(forKey: "enableAEC") { try? AECEngine.stopAudioUnit() }
        }
        audioFile = nil // close audio file
        audioFile2 = nil // close audio file2
        if streamType != .systemaudio {
            let dispatchGroup = DispatchGroup()
            dispatchGroup.enter()
            vwInput.markAsFinished()
            if #available(macOS 13, *) { awInput.markAsFinished() }
            vW.finishWriting {
                if vW.status != .completed {
                    print("Video writing failed with status: \(vW.status), error: \(String(describing: vW.error))")
                    let err = vW.error?.localizedDescription ?? "Unknow Error"
                    if let finishedJob {
                        let cleanupError = finishedJob.discardOutputs(reason: .failed(stage: .first, message: err))
                        directVideoResult = .failure(cleanupError)
                    }
                    showNotification(title: "Failed to save file".local, body: "\(err)", id: "quickrecorder.error.\(UUID().uuidString)")
                } else {
                    if shouldRemuxVideo, let finishedJob {
                        mixAudioTracks(job: finishedJob) { result in
                            switch result {
                            case .success(let url):
                                print("Exported video to \(String(describing: url.path))")
                                if !ud.bool(forKey: "showPreview") {
                                    showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, url.path), id: "quickrecorder.completed.\(UUID().uuidString)")
                                }
                                DispatchQueue.main.async {
                                    if ud.bool(forKey: "trimAfterRecord") {
                                        AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: url), title: url.lastPathComponent, only: false)
                                    } else {
                                        showPreview(path: url.path)
                                    }
                                }
                            case .failure(let error):
                                print("Failed to export video: \(error.localizedDescription)")
                                showNotification(
                                    title: "Failed to save file".local,
                                    body: error.localizedDescription,
                                    id: "quickrecorder.error.\(UUID().uuidString)"
                                )
                            }
                        }
                    } else if let finishedJob {
                        directVideoResult = finishedJob.finishSingleOutput()
                        if case .failure(let error) = directVideoResult {
                            showNotification(
                                title: "Failed to save file".local,
                                body: error.localizedDescription,
                                id: "quickrecorder.error.\(UUID().uuidString)"
                            )
                        }
                    }
                }
                dispatchGroup.leave()
            }
            dispatchGroup.wait()
        } else if recordsMicrophone {
            if let finishedJob,
               case .package(let automaticallyExports) = finishedJob.kind,
               let packageWriter = vW {
                _ = finishedJob.beginPostprocessing()
                packageWriter.finishWriting {
                    let writerResult: Result<Void, RecordingExportError>
                    switch packageWriter.status {
                    case .completed:
                        writerResult = .success(())
                    case .cancelled:
                        writerResult = .failure(.cancelled(stage: .first))
                    default:
                        writerResult = .failure(.failed(
                            stage: .first,
                            message: packageWriter.error?.localizedDescription
                                ?? "Audio package writer ended with status \(packageWriter.status.rawValue)."
                        ))
                    }
                    _ = finishedJob.finishPackageAfterWriter(writerResult) { result in
                        switch result {
                        case .success(let fileURL):
                            DispatchQueue.main.async {
                                finishCompletedAudioPackage(
                                    fileURL,
                                    automaticallyExports: automaticallyExports,
                                    audioQualityKbps: finishedJob.audioQualityKbps
                                )
                            }
                        case .failure(let error):
                            showNotification(
                                title: "Failed to save file".local,
                                body: error.localizedDescription,
                                id: "quickrecorder.error.\(UUID().uuidString)"
                            )
                        }
                    }
                }
            } else if let finishedJob, case .package = finishedJob.kind {
                let error = finishedJob.discardOutputs(reason: .preparation(
                    stage: .first,
                    message: "The audio package writer is unavailable."
                ))
                showNotification(
                    title: "Failed to save file".local,
                    body: error.localizedDescription,
                    id: "quickrecorder.error.\(UUID().uuidString)"
                )
            } else {
                vW?.finishWriting {}
            }
        }
        
        DispatchQueue.main.async {
            controlPanel.close()
            if isCameraRunning() {
                if camWindow.isVisible { camWindow.close() }
                if deviceWindow.isVisible { deviceWindow.close() }
                if let preview = previewSession { preview.stopRunning() }
                if let capture = captureSession { capture.stopRunning() }
            }
        }
        
        if streamType == .systemaudio {
            guard let finishedJob else {
                showNotification(
                    title: "Failed to save file".local,
                    body: "The recording output job is unavailable.",
                    id: "quickrecorder.error.\(UUID().uuidString)"
                )
                streamType = nil
                return
            }
            switch finishedJob.kind {
            case .conversion:
                _ = finishedJob.beginPostprocessing()
                Task { [finishedJob] in
                    do {
                        try await m4a2mp3(
                            inputUrl: finishedJob.inputURL,
                            outputUrl: finishedJob.stagedOutputURL,
                            qualityKbps: finishedJob.audioQualityKbps
                        )
                        let result = finishedJob.finishExport(.success(()))
                        guard case .success(let outPutUrl) = result else {
                            if case .failure(let error) = result { throw error }
                            return
                        }
                        if !ud.bool(forKey: "showPreview") {
                            let title = "Recording Completed".local
                            let decodedPath = outPutUrl.path.removingPercentEncoding ?? outPutUrl.path
                            let body = String(format: "File saved to: %@".local, decodedPath)
                            let id = "quickrecorder.completed.\(UUID().uuidString)"
                            showNotification(title: title, body: body, id: id)
                        } else {
                            DispatchQueue.main.async { showPreview(path: outPutUrl.path, image: NSImage(named: "audioIcon")) }
                        }
                    } catch {
                        let exportError: RecordingExportError
                        if let typedError = error as? RecordingExportError {
                            exportError = typedError
                        } else if error is CancellationError {
                            exportError = .cancelled(stage: .conversion)
                        } else {
                            exportError = .failed(stage: .conversion, message: error.localizedDescription)
                        }
                        let cleanupError = finishedJob.discardOutputs(reason: exportError)
                        showNotification(title: "Failed to save file".local, body: cleanupError.localizedDescription, id: "quickrecorder.error.\(UUID().uuidString)")
                    }
                }
            case .package:
                break // The package writer callback owns terminalization and any automatic export.
            case .single:
                switch finishedJob.finishSingleOutput() {
                case .success(let outputURL):
                    if !ud.bool(forKey: "showPreview") {
                        let title = "Recording Completed".local
                        let body = String(format: "File saved to: %@".local, outputURL.path)
                        let id = "quickrecorder.completed.\(UUID().uuidString)"
                        showNotification(title: title, body: body, id: id)
                    } else {
                        showPreview(path: outputURL.path, image: NSImage(named: "qmaIcon"))
                    }
                case .failure(let error):
                    showNotification(title: "Failed to save file".local, body: error.localizedDescription, id: "quickrecorder.error.\(UUID().uuidString)")
                }
            case .videoRemux:
                let error = finishedJob.discardOutputs(reason: .preparation(
                    stage: .first,
                    message: "A video-remux job reached audio-only finalization."
                ))
                showNotification(title: "Failed to save file".local, body: error.localizedDescription, id: "quickrecorder.error.\(UUID().uuidString)")
            }
        }
        
        isPaused = false
        hideMousePointer = false
        window = nil
        screen = nil
        startTime = nil
        AppDelegate.shared.presenterType = "OFF"
        updateStatusBar()
        
        if !shouldRemuxVideo && streamType != .systemaudio {
            guard case .success(let outputURL) = directVideoResult else {
                streamType = nil
                if let finishedJob, outputJob === finishedJob { outputJob = nil }
                return
            }
            if !ud.bool(forKey: "showPreview") {
                let title = "Recording Completed".local
                let body = String(format: "File saved to: %@".local, outputURL.path)
                let id = "quickrecorder.completed.\(UUID().uuidString)"
                showNotification(title: title, body: body, id: id)
            } else {
                showPreview(path: outputURL.path)
            }
            trimVideo()
        }
        
        streamType = nil
        firstFrame = nil
        if let finishedJob, outputJob === finishedJob { outputJob = nil }
    }

    private static func finishCompletedAudioPackage(
        _ fileURL: URL,
        automaticallyExports: Bool,
        audioQualityKbps: Int?
    ) {
        if automaticallyExports {
            let document = try? qmaPackageHandle.load(from: fileURL)
            guard let document else {
                showNotification(
                    title: "Failed to save file".local,
                    body: "The recorded audio package could not be opened.",
                    id: "quickrecorder.error.\(UUID().uuidString)"
                )
                return
            }
            let audioPlayerManager = AudioPlayerManager()
            audioPlayerManager.loadAudioFiles(
                format: document.info.format,
                package: fileURL,
                encoder: document.info.encoder,
                saveMP3: document.info.exportMP3
            )
            audioPlayerManager.sysVol = document.info.sysVol
            audioPlayerManager.micVol = document.info.micVol
            let exportMP3 = document.info.exportMP3
            let layout: RecordingOutputJob.Layout = exportMP3
                ? .conversion(
                    inputExtension: document.info.format,
                    finalExtension: "mp3",
                    audioQualityKbps: audioQualityKbps
                )
                : .single(
                    fileExtension: document.info.format,
                    audioQualityKbps: audioQualityKbps
                )
            do {
                let exportJob = try RecordingOutputJob.reserve(
                    in: fileURL.deletingLastPathComponent(),
                    preferredStem: fileURL.deletingPathExtension().lastPathComponent,
                    layout: layout
                )
                audioPlayerManager.saveFile(
                    exportJob.finalURL,
                    saveAsMP3: exportMP3,
                    recordingJob: exportJob
                )
            } catch {
                showNotification(
                    title: "Failed to save file".local,
                    body: error.localizedDescription,
                    id: "quickrecorder.error.\(UUID().uuidString)"
                )
            }
        } else if !ud.bool(forKey: "showPreview") {
            let title = "Recording Completed".local
            let body = String(format: "File saved to: %@".local, fileURL.path)
            let id = "quickrecorder.completed.\(UUID().uuidString)"
            showNotification(title: title, body: body, id: id)
        } else {
            showPreview(path: fileURL.path, image: NSImage(named: "qmaIcon"))
        }
    }
    
    static func showPreview(path: String, image: NSImage? = nil) {
        if !ud.bool(forKey: "showPreview") { return }
        var previewImage: NSImage?
        let previewURL = fd.temporaryDirectory.appendingPathComponent("qr-preview.jpg")
        if image == nil { firstFrame?.nsImage?.saveToFile(previewURL, type: .jpeg) }
        
        if let i = image { previewImage = i } else { previewImage = NSImage(contentsOf: previewURL) }
        if let previewImage = previewImage, let screen = getScreenWithMouse() {
            let contentView = NSHostingView(rootView: PreviewView(frame: previewImage, filePath: path))
            previewWindow.contentView = contentView
            previewWindow.setFrameOrigin(NSPoint(x: screen.frame.maxX - 280, y: screen.frame.minY + 20))
            previewWindow.orderFront(self)
        }
    }
    
    static func m4a2mp3(inputUrl: URL, outputUrl: URL, qualityKbps: Int? = nil) async throws {
        let progress = Progress()
        let lameEncoder = try SwiftLameEncoder(
            sourceUrl: inputUrl,
            configuration: .init(
                sampleRate: .custom(48000),
                bitrateMode: .constant(Int32(qualityKbps ?? ud.integer(forKey: "audioQuality"))),
                quality: .nearBest
            ),
            destinationUrl: outputUrl,
            progress: progress // optional
        )
        try await lameEncoder.encode(priority: .userInitiated)
    }
    
    static func trimVideo() {
        if ud.bool(forKey: "trimAfterRecord") {
            let fileURL = filePath.url
            AppDelegate.shared.createNewWindow(view: VideoTrimmerView(videoURL: fileURL), title: fileURL.lastPathComponent, only: false)
        }
    }
    
    static func getCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getMicrophone() -> [AVCaptureDevice] {
        var discoverySession: AVCaptureDevice.DiscoverySession
        if #available(macOS 15.0, *) {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .microphone], mediaType: .audio, position: .unspecified)
        } else {
            discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified)
        }
        return discoverySession.devices.filter({ !$0.localizedName.contains("CADefaultDeviceAggregate") })
    }
    
    static func getiDevice() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .muxed, position: .unspecified)
        return discoverySession.devices
    }
    
    static func getCurrentMic() -> AVCaptureDevice? {
        let deviceName = ud.string(forKey: "micDevice")
        return getMicrophone().first(where: { $0.localizedName == deviceName })
    }
    
    /*static func getChannelCount() -> Int? {
        if let device = getCurrentMic() {
            if let channels = device.formats.first?.formatDescription.audioChannelLayout?.numberOfChannels {
                return channels
            }
            
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let channelCount = audioStreamBasicDescription.mChannelsPerFrame
                return max(2, Int(channelCount))
            }
        }
        return getDefaultChannelCount()
    }
    
    static func getDefaultChannelCount() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // Get the default audio input device.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // Get the channel count.
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Query the stream configuration.
        var streamConfig: UnsafeMutableAudioBufferListPointer?
        propertySize = 0
        
        // Get the property size first.
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
        guard sizeStatus == noErr else {
            print("Failed to get size for stream configuration")
            return nil
        }
        
        // Allocate memory for the audio stream configuration.
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferList.deallocate() }
        
        let configStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList)
        guard configStatus == noErr else {
            print("Failed to get stream configuration")
            return nil
        }
        
        streamConfig = UnsafeMutableAudioBufferListPointer(bufferList)
        
        // Calculate the total channel count.
        var totalChannels = 0
        for buffer in streamConfig! {
            totalChannels += Int(buffer.mNumberChannels)
        }
        return max(2, totalChannels)
    }*/
    
    static func getSampleRate() -> Int? {
        if let device = getCurrentMic() {
            let activeFormat = device.activeFormat
            let description = activeFormat.formatDescription
            
            if let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                let sampleRate = audioStreamBasicDescription.mSampleRate
                return Int(sampleRate)
            }
        }
        return getDefaultSampleRate()
    }
    
    static func getDefaultSampleRate() -> Int? {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout.size(ofValue: deviceID))
        
        // Get the default audio input device.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default audio input device")
            return nil
        }
        
        // Get the sample rate.
        var sampleRate: Double = 0
        propertySize = UInt32(MemoryLayout.size(ofValue: sampleRate))
        
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let sampleRateStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &sampleRate
        )
        
        guard sampleRateStatus == noErr else {
            print("Failed to get sample rate for the default input device")
            return nil
        }
        
        return Int(sampleRate)
    }
    
    static func adjustTime(sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferGetFormatDescription(sample) != nil else { return nil }
        
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(CMSampleBufferGetNumSamples(sample)))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: timingInfo.count, arrayToFill: &timingInfo, entriesNeededOut: nil)
        
        for i in 0..<timingInfo.count {
            timingInfo[i].decodeTimeStamp = CMTimeSubtract(timingInfo[i].decodeTimeStamp, offset)
            timingInfo[i].presentationTimeStamp = CMTimeSubtract(timingInfo[i].presentationTimeStamp, offset)
        }
        
        var outSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: timingInfo.count, sampleTimingArray: &timingInfo, sampleBufferOut: &outSampleBuffer)
        
        return outSampleBuffer
    }
    
    static func showNotification(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("Notification failed to send: \(error.localizedDescription)") }
        }
    }
    
    static func mixAudioTracks(job: RecordingOutputJob, completion: @escaping (Result<URL, RecordingExportError>) -> Void) {
        showNotification(title: "Still Processing".local, body: "Mixing audio track...".local, id: "quickrecorder.processing.\(UUID().uuidString)")
        guard job.beginPostprocessing() else {
            _ = job.finishExport(
                .failure(.preparation(stage: .first, message: "The recording job is already terminal.")),
                deliveringTo: completion
            )
            return
        }
        let finishTerminal: (Result<Void, RecordingExportError>) -> Void = { result in
            _ = job.finishExport(result, deliveringTo: completion)
        }
        
        let asset = AVAsset(url: job.inputURL)
        guard let audioOutputURL = job.intermediateURLs.first else {
            finishTerminal(.failure(.preparation(stage: .first, message: "Missing audio intermediate URL.")))
            return
        }
        let audioOnlyComposition = AVMutableComposition()
        
        let fileEnding = job.finalURL.pathExtension
        let fileType: AVFileType
        switch fileEnding {
        case VideoFormat.mov.rawValue: fileType = AVFileType.mov
        case VideoFormat.mp4.rawValue: fileType = AVFileType.mp4
        default:
            finishTerminal(.failure(.preparation(stage: .first, message: "Unsupported video format: \(fileEnding)")))
            return
        }
        
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count > 1 else {
            finishTerminal(.failure(.preparation(stage: .first, message: "Not enough audio tracks found.")))
            return
        }
        
        for audioTrack in audioTracks {
            if let compositionAudioTrack = audioOnlyComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                } catch {
                    finishTerminal(.failure(.preparation(stage: .first, message: "Failed to insert audio track: \(error.localizedDescription)")))
                    return
                }
            }
        }
        
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioTracks.map {
            let parameters = AVMutableAudioMixInputParameters(track: $0)
            parameters.trackID = $0.trackID
            return parameters
        }
        
        guard let audioExportSession = AVAssetExportSession(asset: audioOnlyComposition, presetName: AVAssetExportPresetHighestQuality) else {
            finishTerminal(.failure(.preparation(stage: .first, message: "Failed to create audio export session.")))
            return
        }
        audioExportSession.outputURL = audioOutputURL
        audioExportSession.outputFileType = fileType
        audioExportSession.audioMix = audioMix
        
        audioExportSession.exportAsynchronously {
            switch audioExportSession.status {
            case .completed:
                let audioAsset = AVAsset(url: audioOutputURL)
                let composition = AVMutableComposition()
                
                guard let videoTrack = asset.tracks(withMediaType: .video).first,
                      let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    finishTerminal(.failure(.preparation(stage: .second, message: "Failed to get video track.")))
                    return
                }
                
                do {
                    try compositionVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
                } catch {
                    finishTerminal(.failure(.preparation(stage: .second, message: "Failed to insert video track: \(error.localizedDescription)")))
                    return
                }
                
                let audioTracks = audioAsset.tracks(withMediaType: .audio)
                guard audioTracks.count >= 1 else {
                    finishTerminal(.failure(.preparation(stage: .second, message: "Not enough audio tracks found.")))
                    return
                }
                
                for audioTrack in audioTracks {
                    if let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        do {
                            try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                        } catch {
                            finishTerminal(.failure(.preparation(stage: .second, message: "Failed to insert audio track: \(error.localizedDescription)")))
                            return
                        }
                    }
                }
                
                guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                    finishTerminal(.failure(.preparation(stage: .second, message: "Failed to create export session.")))
                    return
                }
                
                exportSession.outputURL = job.stagedOutputURL
                exportSession.outputFileType = fileType
                exportSession.audioMix = audioMix
                exportSession.shouldOptimizeForNetworkUse = true
                
                exportSession.exportAsynchronously {
                    switch exportSession.status {
                    case .completed:
                        finishTerminal(.success(()))
                    case .failed:
                        finishTerminal(.failure(.failed(
                            stage: .second,
                            message: exportSession.error?.localizedDescription ?? "Export failed for an unknown reason."
                        )))
                    case .cancelled:
                        finishTerminal(.failure(.cancelled(stage: .second)))
                    default:
                        finishTerminal(.failure(.failed(
                            stage: .second,
                            message: "Export ended with unexpected status \(exportSession.status.rawValue)."
                        )))
                    }
                }
            case .failed:
                finishTerminal(.failure(.failed(
                    stage: .first,
                    message: audioExportSession.error?.localizedDescription ?? "Export failed for an unknown reason."
                )))
            case .cancelled:
                finishTerminal(.failure(.cancelled(stage: .first)))
            default:
                finishTerminal(.failure(.failed(
                    stage: .first,
                    message: "Export ended with unexpected status \(audioExportSession.status.rawValue)."
                )))
            }
        }
    }
}
