//
//  RecordEngine.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/17.
//

import Foundation
import UserNotifications
import ScreenCaptureKit
import AVFoundation
import AVFAudio
import VideoToolbox
import AECAudioStream

extension AppDelegate {
    @objc func prepRecord(type: String, screens: SCDisplay?, windows: [SCWindow]?, applications: [SCRunningApplication]?, fastStart: Bool = false) {
        prepRecord(
            type: type,
            screens: screens,
            windows: windows,
            applications: applications,
            fastStart: fastStart,
            windowCaptureMode: nil
        )
    }

    func prepRecord(
        type: String,
        screens: SCDisplay?,
        windows: [SCWindow]?,
        applications: [SCRunningApplication]?,
        fastStart: Bool = false,
        windowCaptureMode requestedWindowCaptureMode: WindowCaptureMode?
    ) {
        switch type {
        case "window":  SCContext.streamType = .window
        case "windows":  SCContext.streamType = .windows
        case "display": SCContext.streamType = .screen
        case "application": SCContext.streamType = .application
        case "area": SCContext.streamType = .screenarea
        case "audio":   SCContext.streamType = .systemaudio
            default: return // if we don't even know what to record I don't think we should even try
        }
        var isDirectory: ObjCBool = false
        let outputPath = saveDirectory!
        if fd.fileExists(atPath: outputPath, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                SCContext.streamType = nil
                _ = createAlert(title: "Failed to Record".local, message: "The output path is a file instead of a folder!".local, button1: "OK").runModal()
                return
            }
        } else {
            do {
                try fd.createDirectory(atPath: outputPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                SCContext.streamType = nil
                _ = createAlert(title: "Failed to Record".local, message: "Unable to create output folder!".local, button1: "OK").runModal()
                return
            }
        }
        
        // file preparation
        if let screens = screens {
            SCContext.screen = SCContext.availableContent!.displays.first(where: { $0 == screens })
        } else { SCContext.streamType = nil; return }
        
        if let windows = windows {
            SCContext.window = SCContext.availableContent!.windows.filter({ windows.contains($0) })
        } else { if SCContext.streamType == .window { SCContext.streamType = nil; return } }
        
        if let applications = applications {
            SCContext.application = SCContext.availableContent!.applications.filter({ applications.contains($0) })
        } else { if SCContext.streamType == .application { SCContext.streamType = nil; return } }
        
        let screen = SCContext.screen ?? SCContext.getSCDisplayWithMouse()!
        let qrSelf = SCContext.getSelf()
        let qrWindows = SCContext.getSelfWindows()
        let dockApp = SCContext.availableContent!.applications.first(where: { $0.bundleIdentifier.description == "com.apple.dock" })
        let wallpaper = SCContext.availableContent!.windows.filter({
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title != "LPSpringboard" && title != "Dock"
        })
        let desktop = SCContext.availableContent!.windows.filter({
            guard let title = $0.title else { return false }
            return $0.owningApplication?.bundleIdentifier == "" && title == "Desktop"
        })
        let dockWindow = SCContext.availableContent!.windows.filter({
            guard let title = $0.title else { return true }
            return $0.owningApplication?.bundleIdentifier == "com.apple.dock" && title == "Dock"
        })
        let desktopFiles = SCContext.availableContent!.windows.filter({
            $0.owningApplication?.bundleIdentifier == "com.apple.finder"
            && $0.title == "" && $0.frame == screen.frame })
        let controlCenterWindow = SCContext.availableContent!.applications.filter({ $0.bundleIdentifier == "com.apple.controlcenter" })
        let mouseWindow = SCContext.availableContent!.windows.filter({ $0.title == "Mouse Pointer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
        let camLayer = SCContext.availableContent!.windows.filter({ $0.title == "Camera Overlayer".local && $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier })
        var appBlackList = [String]()
        if let savedData = ud.data(forKey: "hiddenApps"),
           let decodedApps = try? JSONDecoder().decode([AppInfo].self, from: savedData) {
            appBlackList = (decodedApps as [AppInfo]).map({ $0.bundleID })
        }
        let excliudedApps = SCContext.availableContent!.applications.filter({ appBlackList.contains($0.bundleIdentifier) })
        
        if SCContext.streamType == .window || SCContext.streamType == .windows {
            if var includ = SCContext.window {
                if includ.count > 1 {
                    if highlightMouse { includ += mouseWindow }
                    if background.rawValue == BackgroundType.wallpaper.rawValue { if dockApp != nil { includ += wallpaper }}
                    SCContext.filter = SCContentFilter(display: screen, including: includ + camLayer)
                    if #available(macOS 14.2, *) { SCContext.filter?.includeMenuBar = includeMenuBar }
                } else {
                    SCContext.streamType = .window
                    SCContext.filter = SCContentFilter(desktopIndependentWindow: includ[0])
                }
            }
        } else {
            if SCContext.streamType == .screen || SCContext.streamType == .screenarea {
                if SCContext.streamType == .screenarea {
                    if let area = SCContext.screenArea, let name = screen.nsScreen?.localizedName {
                        let a = ["x": area.origin.x, "y": area.origin.y, "width": area.width, "height": area.height]
                        ud.set([name: a], forKey: "savedArea")
                    }
                }
                var excluded = [SCRunningApplication]()
                var except = [SCWindow]()
                excluded += excliudedApps
                if hideCCenter { excluded += controlCenterWindow }
                if hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
                if background.rawValue != BackgroundType.wallpaper.rawValue { if dockApp != nil {
                    except += wallpaper
                    except += desktop
                }}
                if hideDesktopFiles { except += desktopFiles }
                SCContext.filter = SCContentFilter(display: screen, excludingApplications: excluded, exceptingWindows: except)
                if #available(macOS 14.2, *) { SCContext.filter?.includeMenuBar = ((SCContext.streamType == .screen || SCContext.streamType == .screenarea) && includeMenuBar) }
            }
            if SCContext.streamType == .application {
                var includ = SCContext.application!
                var except = [SCWindow]()
                if let qrSelf = qrSelf { includ.append(qrSelf) }
                let withFinder = includ.map{ $0.bundleIdentifier }.contains("com.apple.finder")
                if withFinder && hideDesktopFiles { except += desktopFiles }
                if hideSelf { if let qrWindows = qrWindows { except += qrWindows }}
                //if ud.bool(forKey: "highlightMouse") { if let qrSelf = qrSelf { includ.append(qrSelf) }}
                if background.rawValue == BackgroundType.wallpaper.rawValue { if let dock = dockApp { includ.append(dock); except += dockWindow}}
                SCContext.filter = SCContentFilter(display: screen, including: includ, exceptingWindows: except)
                if #available(macOS 14.2, *) { SCContext.filter?.includeMenuBar = includeMenuBar }
            }
        }
        if SCContext.streamType == .systemaudio {
            SCContext.filter = SCContentFilter(display: screen, excludingApplications: [], exceptingWindows: [])
            do {
                try prepareAudioRecording()
            } catch {
                SCContext.streamType = nil
                _ = createAlert(
                    title: "Failed to Record".local,
                    message: error.localizedDescription,
                    button1: "OK"
                ).runModal()
                return
            }
        }
        let sessionWindowCaptureMode: WindowCaptureMode? = SCContext.streamType == .window
            ? requestedWindowCaptureMode ?? windowCaptureMode
            : nil
        Task {
            await record(
                filter: SCContext.filter!,
                fastStart: fastStart,
                windowCaptureMode: sessionWindowCaptureMode
            )
        }
    }

    func record(
        filter: SCContentFilter,
        fastStart: Bool = true,
        windowCaptureMode: WindowCaptureMode? = nil
    ) async {
        SCContext.timeOffset = CMTimeMake(value: 0, timescale: 0)
        SCContext.isPaused = false
        SCContext.isResume = false
        
        let audioOnly = SCContext.streamType == .systemaudio
        let windowSanitizer = windowCaptureMode.map {
            WindowCaptureFrameSanitizer(mode: $0, matte: WindowCapturePrivacy.opaqueMatte)
        }
        let configurationBackgroundColor: CGColor? = {
            guard !audioOnly else { return nil }
            if let windowSanitizer { return windowSanitizer.backgroundColor }
            guard background.rawValue != BackgroundType.wallpaper.rawValue else { return nil }
            return SCContext.getBackgroundColor()
        }()
        
        let conf: SCStreamConfiguration
#if compiler(>=6.0)
        if recordHDR && windowCaptureMode == nil {
            if #available(macOS 15, *) {
                // TODO change here. https://developer.apple.com/videos/play/wwdc2024/10088/?time=191
                // For canonical display, it means you are capturing HDR content that is optimized for sharing with other HDR devices.
                // hdrLocalDisplay or hdrCanonicalDisplay


                conf = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
            } else { conf = SCStreamConfiguration() }
        } else { conf = SCStreamConfiguration() }
#else
        conf = SCStreamConfiguration()
#endif
        conf.width = 2
        conf.height = 2
        
        if !audioOnly {
            if #available(macOS 14.0, *) {
                if windowCaptureMode != nil {
                    let dimensions = WindowCapturePrivacy.pixelDimensions(
                        contentRect: filter.contentRect,
                        pointPixelScale: CGFloat(filter.pointPixelScale),
                        highResolution: highRes == 2
                    )
                    conf.width = dimensions.width
                    conf.height = dimensions.height
                } else {
                    conf.width = Int(filter.contentRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                    conf.height = Int(filter.contentRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                }
            } else {
                guard let pointPixelScaleOld = (SCContext.screen ?? SCContext.getSCDisplayWithMouse()!).nsScreen?.backingScaleFactor else { return }
                if SCContext.streamType == .application || SCContext.streamType == .windows || SCContext.streamType == .screen {
                    let frame = (SCContext.screen ?? SCContext.getSCDisplayWithMouse()!).frame
                    conf.width = Int(frame.width)
                    conf.height = Int(frame.height)
                }
                if SCContext.streamType == .window {
                    let frame = SCContext.window![0].frame
                    conf.width = Int(frame.width)
                    conf.height = Int(frame.height)
                }
                if SCContext.streamType == .screenarea {
                    let frame = SCContext.screenArea!
                    conf.width = Int(frame.width)
                    conf.height = Int(frame.height)
                }
                conf.width = conf.width * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
                conf.height = conf.height * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
            }
            
            if fastStart{
                conf.showsCursor = false
            } else{
                conf.showsCursor = showMouse
            }
                    

            if let configurationBackgroundColor {
                conf.backgroundColor = configurationBackgroundColor
            }
            if !recordHDR || windowCaptureMode != nil {
                conf.pixelFormat = kCVPixelFormatType_32BGRA
                conf.colorSpaceName = CGColorSpace.sRGB
                //if withAlpha { conf.pixelFormat = kCVPixelFormatType_32BGRA }
            } else {
                // For recording HDR in a BT2020 PQ container
                conf.colorSpaceName = CGColorSpace.itur_2100_PQ
//                https://developer.apple.com/videos/play/wwdc2022/10155/ guide on how to record 4k60
//                streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    
// Note: 420 encoding causes color bleed at edges, e.g. youtube settings icon with red logo
                // conf.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
//              dont exceed 8 frames  https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth
//                lower queuedepth has more stutter, dont go below 4 https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example/blob/main/Sources/sckrecording/main.swift
                conf.queueDepth = 8
            }
        }
        
        if #available(macOS 13, *) {
            conf.capturesAudio = recordWinSound || fastStart || audioOnly
            conf.sampleRate = 48000
            conf.channelCount = 2
        }
        

        //  conf.minimumFrameInterval = CMTime(value: 1, timescale: audioOnly ? CMTimeScale.max : CMTimeScale(frameRate))
         conf.minimumFrameInterval = CMTime(value: 1, timescale: audioOnly ? CMTimeScale.max : (frameRate >= 60 ? 0 : CMTimeScale(frameRate)))

//        CMTimeScale is the denominator in the fraction
//        conf.minimumFrameInterval = CMTime(seconds: audioOnly ? Double(CMTimeScale.max) : Double(1)/Double(frameRate), preferredTimescale: 10000)

        // note: ScreenCaptureKit only delivers frames when something changes
        // https://www.reddit.com/r/swift/comments/158n4c9/comment/ju847rm/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button

        //blog post from the reddit comment https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/

        //https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example

        // https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval
        //minimumFrameInterval: Use this value to throttle the rate at which you receive updates. The default value is 0, which indicates that the system uses the maximum supported frame rate.

        print("Frame interval passed to ScreenCaptureKit. (timescale is FPS. 0 means no throttling): \(conf.minimumFrameInterval)")
        

        if SCContext.streamType == .screenarea {
            if let nsRect = SCContext.screenArea {
                let newY = SCContext.screen!.frame.height - nsRect.size.height - nsRect.origin.y
                conf.sourceRect = CGRect(x: nsRect.origin.x, y: newY, width: nsRect.size.width, height: nsRect.size.height)
                if #available(macOS 14.0, *) {
                    conf.width = Int(conf.sourceRect.width) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                    conf.height = Int(conf.sourceRect.height) * (highRes == 2 ? Int(filter.pointPixelScale) : 1)
                } else {
                    guard let pointPixelScaleOld = (SCContext.screen ?? SCContext.getSCDisplayWithMouse()!).nsScreen?.backingScaleFactor else { return }
                    conf.width = Int(conf.sourceRect.width) * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
                    conf.height = Int(conf.sourceRect.height) * (highRes == 2 ? Int(pointPixelScaleOld) : 1)
                }
            }
        }
        
        let encoderIsH265 = (encoder.rawValue == Encoder.h265.rawValue) || recordHDR
        let checksH264Availability: Bool
        switch windowCaptureMode {
        case .transparent:
            checksH264Availability = false
        case .opaque:
            checksH264Availability = encoder == .h264
        case nil:
            checksH264Availability = !encoderIsH265
        }
        if !audioOnly && checksH264Availability {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(conf.width),
                height: Int32(conf.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
            
            if status != noErr {
                let button = showAlertSyncOnMainThread(
                    level: .critical,
                    title: "Encoder Warning",
                    message: "VideoToolbox H.264 hardware encoder doesn't support the current resolution.\nContinue with a software encoder will significantly increase the CPU usage.\n\nWould you like to use H.265 instead?".local,
                    button1: "Use H.265",
                    button2: "Continue with H.264"
                )
                if button == .alertFirstButtonReturn { ud.setValue(Encoder.h265.rawValue, forKey: "encoder") }
            }
        }
        
        let sessionID = UUID()
        let sampleQueue = DispatchQueue(label: "dev.clickai.grabrabbit.capture.\(sessionID.uuidString)")
        let stream = withExtendedLifetime(configurationBackgroundColor) {
            SCStream(filter: filter, configuration: conf, delegate: self)
        }
        let preconfiguredOutputJob = audioOnly ? SCContext.outputJob : nil
        var outputSession: CaptureOutputSession?
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if #available(macOS 13, *) {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if !audioOnly {
                try initVideo(conf: conf, windowCaptureMode: windowCaptureMode)
            } else {
                //SCContext.startTime = Date.now
                if recordMic { startMicRecording() }
            }
            let videoInput: AVAssetWriterInput? = audioOnly ? nil : SCContext.vwInput
            let systemAudioInput: AVAssetWriterInput?
            if #available(macOS 13, *), !audioOnly {
                systemAudioInput = SCContext.awInput
            } else {
                systemAudioInput = nil
            }
            let session = CaptureOutputSession(
                id: sessionID,
                stream: stream,
                outputJob: SCContext.outputJob,
                writer: SCContext.vW,
                videoInput: videoInput,
                systemAudioInput: systemAudioInput,
                standaloneAudioFile: audioOnly ? SCContext.audioFile : nil,
                windowSanitizer: windowSanitizer,
                configurationBackgroundColor: configurationBackgroundColor,
                sampleQueue: sampleQueue,
                isAudioOnly: audioOnly
            )
            outputSession = session
            guard captureOutputSessions.install(session) else {
                throw RecordingExportError.preparation(
                    stage: .first,
                    message: "Another capture session is already active."
                )
            }
            SCContext.stream = stream
            try await stream.startCapture()
        } catch {
            let recordingError = (error as? RecordingExportError)
                ?? .preparation(stage: .first, message: error.localizedDescription)
            if let outputSession {
                _ = captureOutputSessions.clear(outputSession)
            }
            if SCContext.stream === stream { SCContext.stream = nil }
            if let job = outputSession?.outputJob ?? preconfiguredOutputJob {
                _ = job.discardOutputs(reason: recordingError)
                if SCContext.outputJob === job { SCContext.outputJob = nil }
            }
            SCContext.showNotification(
                title: "Failed to Record".local,
                body: recordingError.localizedDescription,
                id: "quickrecorder.error.\(UUID().uuidString)"
            )
            return
        }
        if !audioOnly { registerGlobalMouseMonitor() }
        DispatchQueue.main.async { updateStatusBar() }
        if preventSleep { SleepPreventer.shared.preventSleep(reason: "Screen recording in progress") }
    }

    func prepareAudioRecording() throws {
        var fileEnding = audioFormat.rawValue
        let encorder = fileEnding == AudioFormat.mp3.rawValue ? "aac" : fileEnding
        let fileType: AVFileType
        switch fileEnding { // todo: I'd like to store format info differently
            case AudioFormat.mp3.rawValue: fallthrough
            case AudioFormat.aac.rawValue: fallthrough
            case AudioFormat.alac.rawValue: fileEnding = "m4a"; fileType = .m4a
            case AudioFormat.flac.rawValue: fileEnding = "flac"; fileType = .caf
            case AudioFormat.opus.rawValue: fileEnding = "ogg"; fileType = .caf
            default:
                throw RecordingExportError.preparation(
                    stage: .first,
                    message: "Unsupported audio format: \(fileEnding)"
                )
        }
        if recordMic && SCContext.streamType == .systemaudio {
            let job = try SCContext.reserveOutputJob(
                layout: .package(
                    fileExtension: "qma",
                    requiredMembers: ["info.json", "sys.\(fileEnding)", "mic.\(fileEnding)"],
                    automaticallyExports: remuxAudio,
                    audioQualityKbps: ud.integer(forKey: "audioQuality")
                )
            )
            SCContext.outputJob = job
            SCContext.filePath = job.finalURL.path
            SCContext.filePath1 = job.inputURL.appendingPathComponent("sys.\(fileEnding)").path
            SCContext.filePath2 = job.inputURL.appendingPathComponent("mic.\(fileEnding)").path
            let infoJsonURL = job.inputURL.appendingPathComponent("info.json")
            let jsonString = "{\"format\": \"\(fileEnding)\", \"encoder\": \"\(encorder)\", \"exportMP3\": \(audioFormat.rawValue == AudioFormat.mp3.rawValue), \"sysVol\": 1.0, \"micVol\": 1.0}"
            do {
                try jsonString.write(to: infoJsonURL, atomically: true, encoding: .utf8)
                SCContext.audioFile = try AVAudioFile(forWriting: SCContext.filePath1.url, settings: SCContext.updateAudioSettings(), commonFormat: .pcmFormatFloat32, interleaved: false)

                let sampleRate = SCContext.getSampleRate() ?? 48000
                let settings = SCContext.updateAudioSettings(rate: sampleRate)
                SCContext.vW = try AVAssetWriter.init(outputURL: SCContext.filePath2.url, fileType: fileType)
                SCContext.micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: settings)
                SCContext.micInput.expectsMediaDataInRealTime = true
                if SCContext.vW.canAdd(SCContext.micInput) { SCContext.vW.add(SCContext.micInput) }
                SCContext.vW.startWriting()
            } catch {
                let recordingError = RecordingExportError.preparation(stage: .first, message: error.localizedDescription)
                _ = job.discardOutputs(reason: recordingError)
                SCContext.outputJob = nil
                throw recordingError
            }
        } else {
            let layout: RecordingOutputJob.Layout = audioFormat == .mp3
                ? .conversion(
                    inputExtension: fileEnding,
                    finalExtension: "mp3",
                    audioQualityKbps: ud.integer(forKey: "audioQuality")
                )
                : .single(fileExtension: fileEnding)
            let job = try SCContext.reserveOutputJob(layout: layout)
            SCContext.outputJob = job
            SCContext.filePath = job.finalURL.path
            SCContext.filePath1 = job.inputURL.path
            do {
                SCContext.audioFile = try AVAudioFile(forWriting: job.inputURL, settings: SCContext.updateAudioSettings(), commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                let recordingError = RecordingExportError.preparation(stage: .first, message: error.localizedDescription)
                _ = job.discardOutputs(reason: recordingError)
                SCContext.outputJob = nil
                throw recordingError
            }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        return deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
    var isMainScreen: Bool {
        guard let id = self.displayID else { return false }
        return (CGDisplayIsMain(id) == 1)
    }
}

extension SCDisplay {
    var nsScreen: NSScreen? {
        return NSScreen.screens.first(where: { $0.displayID == self.displayID })
    }
}

extension AppDelegate {
    func initVideo(
        conf: SCStreamConfiguration,
        windowCaptureMode: WindowCaptureMode? = nil
    ) throws {
        SCContext.startTime = nil

        let compatibilityFileType: AVFileType
        switch videoFormat.rawValue {
            case VideoFormat.mov.rawValue: compatibilityFileType = AVFileType.mov
            case VideoFormat.mp4.rawValue: compatibilityFileType = AVFileType.mp4
            default:
                throw RecordingExportError.preparation(
                    stage: .first,
                    message: "Unsupported video format: \(videoFormat.rawValue)"
                )
        }
        let compatibilityCodec: AVVideoCodecType = encoder == .h265 ? .hevc : .h264
        let windowProfile = windowCaptureMode.map {
            WindowCapturePrivacy.outputProfile(
                mode: $0,
                compatibilityFileType: compatibilityFileType,
                compatibilityCodec: compatibilityCodec
            )
        }
        let fileEnding = windowProfile?.fileExtension ?? videoFormat.rawValue
        let fileType = windowProfile?.fileType ?? compatibilityFileType
        let videoCodec = windowProfile?.codec
            ?? ((encoder == .h265 || recordHDR) ? ((withAlpha && !recordHDR) ? .hevcWithAlpha : .hevc) : .h264)

        let layout: RecordingOutputJob.Layout = remuxAudio && recordMic && recordWinSound
            ? .videoRemux(fileExtension: fileEnding)
            : .single(fileExtension: fileEnding, recordsMicrophone: recordMic)
        let job = try SCContext.reserveOutputJob(layout: layout)
        SCContext.outputJob = job
        SCContext.filePath = job.finalURL.path
        do {
            SCContext.vW = try AVAssetWriter.init(outputURL: job.inputURL, fileType: fileType)
        } catch {
            let recordingError = RecordingExportError.preparation(stage: .first, message: error.localizedDescription)
            _ = job.discardOutputs(reason: recordingError)
            SCContext.outputJob = nil
            throw recordingError
        }
        SCContext.vW.shouldOptimizeForNetworkUse = true
        let encoderIsH265 = videoCodec == .hevc || videoCodec == .hevcWithAlpha
        let fpsMultiplier: Double = Double(frameRate)/8
        let encoderMultiplier: Double = encoderIsH265 ? 0.5 : 0.9
        let resolution = Double(max(600, conf.width)) * Double(max(600, conf.height))
        var qualityMultiplier = 1 - (log10(sqrt(resolution) * fpsMultiplier) / 5)
        switch videoQuality {
            case 0.3: qualityMultiplier = max(0.1, qualityMultiplier)
            case 0.7: qualityMultiplier = max(0.4, min(0.6, qualityMultiplier * 3))
            default: qualityMultiplier = 1.0
        }
        let h264Level = AVVideoProfileLevelH264HighAutoLevel
        let recordsHDR = recordHDR && windowCaptureMode == nil
        let h265Level = recordsHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel

        let targetBitrate = resolution * fpsMultiplier * encoderMultiplier * qualityMultiplier * (recordsHDR ? 2 : 1)
        print("framerate set in app: \(frameRate)")
        print("target bitrate: \(targetBitrate/1000000)")

        var videoSettings = WindowCapturePrivacy.videoSettings(
            profile: WindowCaptureOutputProfile(
                fileExtension: fileEnding,
                fileType: fileType,
                codec: videoCodec,
                preservesAlpha: windowProfile?.preservesAlpha ?? (videoCodec == .hevcWithAlpha)
            ),
            width: conf.width,
            height: conf.height,
            compressionProperties: [
                AVVideoProfileLevelKey: encoderIsH265 ? h265Level : h264Level,
                AVVideoAverageBitRateKey: max(200000, Int(targetBitrate)),
                AVVideoExpectedSourceFrameRateKey: frameRate,
            ]
        )
        
        if !recordHDR || windowCaptureMode != nil {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2] as [String : Any]
        }
        
        SCContext.vwInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings)
        SCContext.vwInput.expectsMediaDataInRealTime = true
        
        if SCContext.vW.canAdd(SCContext.vwInput) { SCContext.vW.add(SCContext.vwInput) }

        if #available(macOS 13, *) {
            SCContext.awInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: SCContext.updateAudioSettings())
            SCContext.awInput.expectsMediaDataInRealTime = true
            if SCContext.vW.canAdd(SCContext.awInput) { SCContext.vW.add(SCContext.awInput) }
        }

        if recordMic {
            let sampleRate = SCContext.getSampleRate() ?? 48000
            let settings = SCContext.updateAudioSettings(rate: sampleRate)
            
            SCContext.micInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: settings)
            SCContext.micInput.expectsMediaDataInRealTime = true
            if SCContext.vW.canAdd(SCContext.micInput) { SCContext.vW.add(SCContext.micInput) }
            startMicRecording()
        }
        SCContext.vW.startWriting()
    }
    
    func startMicRecording() {
        if micDevice == "default" {
            if enableAEC {
                var level = AUVoiceIOOtherAudioDuckingLevel.mid
                switch AECLevel {
                    case "min": level = .min
                    case "max": level = .max
                    default: level = .mid
                }
                try? SCContext.AECEngine.startAudioStream(enableAEC: enableAEC, duckingLevel: level, audioBufferHandler: { pcmBuffer in
                    if SCContext.isPaused || SCContext.startTime == nil { return }
                    if SCContext.micInput.isReadyForMoreMediaData {
                        SCContext.micInput.append(pcmBuffer.asSampleBuffer!)
                    }
                })
            } else {
                let input = SCContext.audioEngine.inputNode
                let inputFormat = input.inputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, time in
                    if SCContext.isPaused || SCContext.startTime == nil { return }
                    if SCContext.micInput.isReadyForMoreMediaData {
                        SCContext.micInput.append(buffer.asSampleBuffer!)
                    }
                }
                try! SCContext.audioEngine.start()
            }
        } else {
            AudioRecorder.shared.setupAudioCapture()
            AudioRecorder.shared.start()
        }
    }
    
    func outputVideoEffectDidStart(for stream: SCStream) {
        guard let outputSession = captureOutputSessions.session(for: stream) else { return }
        DispatchQueue.main.async {
            guard self.captureOutputSessions.session(for: stream) === outputSession else { return }
            camWindow.close()
        }
        print("[Presenter Overlay ON]")
        isPresenterON = true
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(poSafeDelay)) {
            guard self.captureOutputSessions.session(for: stream) === outputSession else { return }
            self.isCameraReady = true
        }
    }
    
    func outputVideoEffectDidStop(for stream: SCStream) {
        guard let outputSession = captureOutputSessions.session(for: stream) else { return }
        print("[Presenter Overlay OFF]")
        presenterType = "OFF"
        isPresenterON = false
        isCameraReady = false
        DispatchQueue.main.async {
            guard self.captureOutputSessions.session(for: stream) === outputSession else { return }
            camWindow.orderFront(self)
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard let outputSession = captureOutputSessions.session(for: stream) else { return }
        if SCContext.saveFrame, let imageBuffer = sampleBuffer.imageBuffer {
            SCContext.saveFrame = false
            do {
                let job = try SCContext.reserveOutputJob(capture: true, layout: .single(fileExtension: "png"))
                do {
                    var ciImage = CIImage(cvPixelBuffer: imageBuffer)
                    let url = job.stagedOutputURL
                    if !recordHDR {
                        sampleBuffer.nsImage?.saveToFile(url)
                    } else {
                        let context = CIContext()
                
                    // Create the HEIF destination with the correct UTI
                    //            if let destination = url? {
                    // Specify format and color space (assuming default settings here)
                    //                let format = CIFormat.rgb10
                    let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) ?? CGColorSpaceCreateDeviceRGB()
                
                    // let colorSpace = ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                
                    // Image exposure needs to be increased by one stop to match the original
                    ciImage = ciImage.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 1.0])
                
                
                
                
                
                    //                context.writeHEIF10Representation(of: ciImage, to: destination as! URL, colorSpace: colorSpace)
                    // try context.writeHEIF10Representation(of:ciImage,
                    //                                       to:url,
                    //                                       colorSpace:colorSpace,
                    //                                       options: [
                    //     kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0
                        if #available(macOS 14.0, *) {
                            try context.writePNGRepresentation(of:ciImage,
                                                               to:url,
                                                               format: .RGB10,
                                                               colorSpace:colorSpace
                            )
                        } else {
                            // Fallback on earlier versions
                            print("RGB10 PNG not supported on this macOS version")
                            try context.writePNGRepresentation(of:ciImage,
                                                               to:url,
                                                               format: .RGBA8,
                                                               colorSpace:colorSpace)
                        }
                        //        try context.writePNGRepresentation(of:outImage, to:outURL, format: .RGBA16,colorSpace:colorSpace,options:[:])
                    }
                    if case .failure(let error) = job.finishSingleOutput() {
                        SCContext.showNotification(
                            title: "Failed to save file".local,
                            body: error.localizedDescription,
                            id: "quickrecorder.error.\(UUID().uuidString)"
                        )
                    }
                    //                CGImageDestinationFinalize(destination)
                } catch {
                    let recordingError = RecordingExportError.failed(stage: .first, message: error.localizedDescription)
                    let cleanupError = job.discardOutputs(reason: recordingError)
                    SCContext.showNotification(
                        title: "Failed to save file".local,
                        body: cleanupError.localizedDescription,
                        id: "quickrecorder.error.\(UUID().uuidString)"
                    )
                }
            } catch {
                SCContext.showNotification(
                    title: "Failed to save file".local,
                    body: error.localizedDescription,
                    id: "quickrecorder.error.\(UUID().uuidString)"
                )
            }
        }
        if SCContext.isPaused { return }
        guard sampleBuffer.isValid else { return }
        var SampleBuffer = sampleBuffer
        if SCContext.isResume {
            SCContext.isResume = false
            var pts = CMSampleBufferGetPresentationTimeStamp(SampleBuffer)
            guard let last = SCContext.lastPTS else { return }
            if last.flags.contains(CMTimeFlags.valid) {
                if SCContext.timeOffset.flags.contains(CMTimeFlags.valid) { pts = CMTimeSubtract(pts, SCContext.timeOffset) }
                let off = CMTimeSubtract(pts, last)
                print("adding \(CMTimeGetSeconds(off)) to \(CMTimeGetSeconds(SCContext.timeOffset)) (pts \(CMTimeGetSeconds(SCContext.timeOffset)))")
                if SCContext.timeOffset.value == 0 { SCContext.timeOffset = off } else { SCContext.timeOffset = CMTimeAdd(SCContext.timeOffset, off) }
            }
            SCContext.lastPTS?.flags = []
        }
        switch outputType {
        case .screen:
            if (SCContext.screen == nil && SCContext.window == nil && SCContext.application == nil) || SCContext.streamType == .systemaudio { break }
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(SampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first else { return }
            guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else { return }
            
            if let writer = outputSession.writer, writer.status == .writing, SCContext.startTime == nil {
                SCContext.startTime = Date.now
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(SampleBuffer))
            }
            if (SCContext.timeOffset.value > 0) { SampleBuffer = SCContext.adjustTime(sample: SampleBuffer, by: SCContext.timeOffset) ?? sampleBuffer }
            var pts = CMSampleBufferGetPresentationTimeStamp(SampleBuffer)
            let dur = CMSampleBufferGetDuration(SampleBuffer)
            if (dur.value > 0) { pts = CMTimeAdd(pts, dur) }
            if frameQueue.getArray().contains(where: { $0 >= pts }) { print("Skip this frame"); return } else { frameQueue.append(pts) }
            SCContext.lastPTS = pts
            if outputSession.videoInput?.isReadyForMoreMediaData == true {
                if #available(macOS 14.2, *) {
                    if let rect = attachments[.presenterOverlayContentRect] as? [String: Any]{
                        var type = "np"
                        let off = (rect["X"] as! CGFloat == .infinity)
                        let small = (rect["X"] as! CGFloat == 0.0)
                        let big = (!off && !small)
                        if off { type = "OFF" } else if small { type = "Small" } else if big { type = "Big" }
                        if type != presenterType {
                            print("Presenter Overlay set to \"\(type)\"!")
                            isCameraReady = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(poSafeDelay)) {
                                self.isCameraReady = true
                            }
                            presenterType = type
                        }
                    }
                }
                if isPresenterON && !isCameraReady { break }
                if SCContext.firstFrame == nil { SCContext.firstFrame = SampleBuffer }
                do {
                    _ = try outputSession.routeVideo(from: stream, sampleBuffer: SampleBuffer)
                } catch {
                    SCContext.showNotification(
                        title: "Failed to Record".local,
                        body: "Unable to apply the selected window privacy mode.".local,
                        id: "quickrecorder.error.\(UUID().uuidString)"
                    )
                    SCContext.stopRecording()
                    return
                }
            }
            break
        case .audio:
            if outputSession.isAudioOnly { // write directly to file if not video recording
                hideMousePointer = true
                if let writer = outputSession.writer, writer.status == .writing, SCContext.startTime == nil {
                    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(SampleBuffer))
                }
                if SCContext.startTime == nil { SCContext.startTime = Date.now }
                guard let samples = SampleBuffer.asPCMBuffer else { return }
                do { try outputSession.standaloneAudioFile?.write(from: samples) }
                catch { assertionFailure("audio file writing issue".local) }
            } else {
                if SCContext.lastPTS == nil { return }
                if outputSession.systemAudioInput?.isReadyForMoreMediaData == true {
                    outputSession.systemAudioInput?.append(SampleBuffer)
                }
            }
#if compiler(>=6.0)
        case .microphone:
            break
#endif
        @unknown default:
            assertionFailure("unknown stream type".local)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { // stream error
        guard let outputSession = captureOutputSessions.session(for: stream) else { return }
        print("closing stream with error:\n".local, error,
              "\nthis might be due to the window closing or the user stopping from the sonoma ui".local)
        DispatchQueue.main.async {
            guard self.captureOutputSessions.session(for: stream) === outputSession else { return }
            _ = self.captureOutputSessions.deactivate(outputSession)
            self.captureOutputSessions.release(outputSession)
            SCContext.stream = nil
            SCContext.stopRecording()
        }
    }
}

class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = AudioRecorder()
    private var captureSession: AVCaptureSession!
    private var audioInput: AVCaptureDeviceInput!
    private var audioDataOutput: AVCaptureAudioDataOutput!

    func setupAudioCapture() {
        captureSession = AVCaptureSession()

        // Get the default audio device (microphone)
        guard let audioDevice = SCContext.getCurrentMic() else {
            print("Unable to access microphone")
            return
        }
        
        // Create audio input
        do {
            audioInput = try AVCaptureDeviceInput(device: audioDevice)
        } catch {
            print("Unable to create audio input: \(error)")
            return
        }
        
        // Add audio input to capture session
        if captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        } else {
            print("Unable to add audio input to capture session")
            return
        }

        // Create audio data output
        audioDataOutput = AVCaptureAudioDataOutput()
        let audioQueue = DispatchQueue(label: "audioQueue")
        audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
        
        // Add audio data output to capture session
        if captureSession.canAddOutput(audioDataOutput) {
            captureSession.addOutput(audioDataOutput)
        } else {
            print("Unable to add audio data output to capture session")
            return
        }
    }
    
    func start() {
        if let session = captureSession {
            session.startRunning()
        }
    }
    
    func stop() {
        if let session = captureSession {
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if SCContext.isPaused || SCContext.startTime == nil { return }
        if SCContext.micInput.isReadyForMoreMediaData {
            SCContext.micInput.append(sampleBuffer)
        }
    }
}

// https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos
// For Sonoma updated to https://developer.apple.com/forums/thread/727709
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? self.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = self.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
    
    var nsImage: NSImage? {
        return autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(self) else { return nil }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let ciContext = CIContext()
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                return NSImage(cgImage: cgImage, size: .zero)
            }
            return nil
        }
    }
}

// Based on https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c
extension AVAudioPCMBuffer {
    var asSampleBuffer: CMSampleBuffer? {
        let asbd = self.format.streamDescription
        var sampleBuffer: CMSampleBuffer? = nil
        var format: CMFormatDescription? = nil

        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(asbd.pointee.mSampleRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(self.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: self.mutableAudioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
