import CoreVideo
import AVFoundation
import Foundation
import ScreenCaptureKit
import XCTest

final class WindowCapturePrivacyTests: XCTestCase {
    private let width = 64
    private let height = 48
    private let cornerRadius = 10
    private let testMatte = WindowCapturePrivacy.opaqueMatte
    private let sentinels: [WindowCaptureMatte] = [
        .init(red: 255, green: 79, blue: 0),
        .init(red: 255, green: 0, blue: 255),
        .init(red: 0, green: 255, blue: 255),
        .init(red: 0, green: 255, blue: 0),
    ]

    func testSentinelCornersAreSanitizedForEveryWallpaperAndMode() throws {
        for sentinel in sentinels {
            for mode in WindowCaptureMode.allCases {
                let buffer = try makeRoundedWindow(over: sentinel)
                try WindowCapturePrivacy.sanitize(buffer, mode: mode, matte: testMatte)

                XCTAssertEqual(CVPixelBufferGetWidth(buffer), width)
                XCTAssertEqual(CVPixelBufferGetHeight(buffer), height)

                let result = try inspectExterior(of: buffer, mode: mode, sentinel: sentinel)
                XCTAssertEqual(result.sentinelPixels, 0, "\(mode) leaked sentinel pixels")
                XCTAssertEqual(result.invalidPixels, 0, "\(mode) produced the wrong exterior")
            }
        }
    }

    func testWindowDimensionsFollowSourceContentAtBothResolutionSettings() {
        let source = CGRect(x: 500, y: 300, width: 987.5, height: 1040)

        let sourceResolution = WindowCapturePrivacy.pixelDimensions(
            contentRect: source,
            pointPixelScale: 2,
            highResolution: false
        )
        XCTAssertEqual(sourceResolution.width, 988)
        XCTAssertEqual(sourceResolution.height, 1040)

        let retinaResolution = WindowCapturePrivacy.pixelDimensions(
            contentRect: source,
            pointPixelScale: 2,
            highResolution: true
        )
        XCTAssertEqual(retinaResolution.width, 1975)
        XCTAssertEqual(retinaResolution.height, 2080)
    }

    func testTransparentAndOpaqueOutputProfilesAreExplicit() {
        let transparent = WindowCapturePrivacy.outputProfile(
            mode: .transparent,
            compatibilityFileType: .mp4,
            compatibilityCodec: .h264
        )
        XCTAssertEqual(transparent.fileExtension, "mov")
        XCTAssertEqual(transparent.fileType, .mov)
        XCTAssertEqual(transparent.codec, .proRes4444)
        XCTAssertTrue(transparent.preservesAlpha)

        for fileType in [AVFileType.mov, .mp4] {
            for codec in [AVVideoCodecType.h264, .hevc] {
                let opaque = WindowCapturePrivacy.outputProfile(
                    mode: .opaque,
                    compatibilityFileType: fileType,
                    compatibilityCodec: codec
                )
                XCTAssertEqual(opaque.fileType, fileType)
                XCTAssertEqual(opaque.codec, codec)
                XCTAssertFalse(opaque.preservesAlpha)
            }
        }
    }

    func testBackgroundColorIsClearOrExactOpaqueMatte() throws {
        XCTAssertEqual(WindowCapturePrivacy.opaqueMatte, WindowCaptureMatte(red: 0, green: 0, blue: 0))
        let transparent = WindowCapturePrivacy.backgroundColor(mode: .transparent, matte: testMatte)
        XCTAssertEqual(transparent.alpha, 0)

        let opaque = WindowCapturePrivacy.backgroundColor(mode: .opaque, matte: testMatte)
        let components = try XCTUnwrap(opaque.components)
        XCTAssertEqual(opaque.alpha, 1)
        XCTAssertEqual(components[0], CGFloat(testMatte.red) / 255, accuracy: 0.0001)
        XCTAssertEqual(components[1], CGFloat(testMatte.green) / 255, accuracy: 0.0001)
        XCTAssertEqual(components[2], CGFloat(testMatte.blue) / 255, accuracy: 0.0001)
    }

    func testConfigurationBackgroundColorHasAnOwnerBeyondItsAssignmentScope() {
        let configuration = SCStreamConfiguration()
        weak var assignedColor: CGColor?
        var session: CaptureOutputSession?

        autoreleasepool {
            let sanitizer = WindowCaptureFrameSanitizer(mode: .transparent, matte: testMatte)
            assignedColor = sanitizer.backgroundColor
            configuration.backgroundColor = sanitizer.backgroundColor
            session = CaptureOutputSession(
                stream: NSObject(),
                outputJob: nil,
                writer: nil,
                videoInput: nil,
                systemAudioInput: nil,
                standaloneAudioFile: nil,
                windowSanitizer: sanitizer,
                configurationBackgroundColor: sanitizer.backgroundColor,
                sampleQueue: DispatchQueue(label: "WindowCapturePrivacyTests.color-owner"),
                isAudioOnly: false
            )
        }

        XCTAssertNotNil(assignedColor, "SCStreamConfiguration.backgroundColor is assign and needs a strong session owner")
        let copiedConfiguration = configuration.copy() as? SCStreamConfiguration
        XCTAssertEqual(copiedConfiguration?.backgroundColor.alpha, 0)
        withExtendedLifetime(session) {}
        withExtendedLifetime(configuration) {}
    }

    func testDelayedOldStreamCannotUseCurrentSessionPolicyOrWriter() throws {
        let streamA = NSObject()
        let streamB = NSObject()
        let sinkA = TestVideoDestination()
        let sinkB = TestVideoDestination()
        let store = CaptureOutputSessionStore()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: sinkA)
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: sinkB)
        let delayedABuffer = try makeRoundedWindow(over: sentinels[0])
        let delayedASample = try makeSampleBuffer(imageBuffer: delayedABuffer)

        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(store.deactivate(sessionA))
        XCTAssertTrue(store.install(sessionB))
        let result = try store.routeVideo(from: streamA, sampleBuffer: delayedASample)

        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(sinkA.appendCount, 0)
        XCTAssertEqual(sinkB.appendCount, 0)
        let unchanged = try inspectExterior(of: delayedABuffer, mode: .transparent, sentinel: sentinels[0])
        XCTAssertGreaterThan(unchanged.sentinelPixels, 0, "B's opaque sanitizer must not touch a delayed A frame")

        let currentForB = try XCTUnwrap(store.session(for: streamB))
        let currentBBuffer = try makeRoundedWindow(over: sentinels[1])
        let currentBSample = try makeSampleBuffer(imageBuffer: currentBBuffer)
        XCTAssertEqual(try currentForB.routeVideo(from: streamB, sampleBuffer: currentBSample), .appended)
        XCTAssertEqual(sinkA.appendCount, 0)
        XCTAssertEqual(sinkB.appendCount, 1)
        let sanitized = try inspectExterior(of: currentBBuffer, mode: .opaque, sentinel: sentinels[1])
        XCTAssertEqual(sanitized.sentinelPixels, 0)
        XCTAssertEqual(sanitized.invalidPixels, 0)
    }

    func testLateOldStreamCannotDeactivateCurrentSession() {
        let streamA = NSObject()
        let streamB = NSObject()
        let store = CaptureOutputSessionStore()
        let sessionA = makeCaptureSession(stream: streamA, mode: .transparent, sink: TestVideoDestination())
        let sessionB = makeCaptureSession(stream: streamB, mode: .opaque, sink: TestVideoDestination())

        XCTAssertTrue(store.install(sessionA))
        XCTAssertTrue(store.deactivate(sessionA))
        XCTAssertTrue(store.install(sessionB))

        XCTAssertNil(store.session(for: streamA))
        XCTAssertFalse(store.deactivate(sessionA), "a late A stop/error must not deactivate B")
        XCTAssertTrue(store.session(for: streamB) === sessionB)
    }

    func testFFmpegReadsTransparentAndOpaqueFixtures() throws {
        let ffprobe = try XCTUnwrap(executable(named: "ffprobe"))
        let ffmpeg = try XCTUnwrap(executable(named: "ffmpeg"))
        let fixtures = [
            (mode: WindowCaptureMode.transparent, fileType: AVFileType.mov, codec: AVVideoCodecType.proRes4444, expectedCodec: "prores"),
            (mode: WindowCaptureMode.opaque, fileType: AVFileType.mp4, codec: AVVideoCodecType.h264, expectedCodec: "h264"),
            (mode: WindowCaptureMode.opaque, fileType: AVFileType.mov, codec: AVVideoCodecType.hevc, expectedCodec: "hevc"),
        ]

        for fixture in fixtures {
            let url = try writeFixture(
                mode: fixture.mode,
                fileType: fixture.fileType,
                codec: fixture.codec
            )
            defer { try? FileManager.default.removeItem(at: url) }

            let probeData = try run(
                ffprobe,
                arguments: [
                    "-v", "error",
                    "-select_streams", "v:0",
                    "-show_entries", "stream=codec_name,pix_fmt,width,height:format=format_name",
                    "-of", "json",
                    url.path,
                ]
            )
            let probe = try XCTUnwrap(try JSONSerialization.jsonObject(with: probeData) as? [String: Any])
            let streams = try XCTUnwrap(probe["streams"] as? [[String: Any]])
            let stream = try XCTUnwrap(streams.first)
            let format = try XCTUnwrap(probe["format"] as? [String: Any])
            XCTAssertEqual(stream["codec_name"] as? String, fixture.expectedCodec)
            XCTAssertEqual(stream["width"] as? Int, width)
            XCTAssertEqual(stream["height"] as? Int, height)
            XCTAssertTrue((format["format_name"] as? String)?.contains("mov") == true)
            if fixture.mode == .transparent {
                XCTAssertTrue((stream["pix_fmt"] as? String)?.contains("yuva") == true)
            }

            let rgba = try run(
                ffmpeg,
                arguments: [
                    "-v", "error",
                    "-i", url.path,
                    "-frames:v", "1",
                    "-pix_fmt", "rgba",
                    "-f", "rawvideo",
                    "pipe:1",
                ]
            )
            XCTAssertEqual(rgba.count, width * height * 4)
            let bytes = [UInt8](rgba)
            for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
                let offset = (y * width + x) * 4
                if fixture.mode == .transparent {
                    XCTAssertEqual(bytes[offset + 3], 0)
                } else {
                    XCTAssertEqual(bytes[offset + 3], 255)
                    XCTAssertEqual(bytes[offset], testMatte.red, accuracy: 24)
                    XCTAssertEqual(bytes[offset + 1], testMatte.green, accuracy: 24)
                    XCTAssertEqual(bytes[offset + 2], testMatte.blue, accuracy: 24)
                }
            }
        }
    }

    func testNormalAndQuickWindowPathsUseTheSelectedModeWithoutMutatingAudioChoices() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let selectorSource = try projectSource("QuickRecorder/ViewModel/WinSelector.swift")
        let settingsSource = try projectSource("QuickRecorder/ViewModel/SettingsView.swift")

        XCTAssertTrue(engineSource.contains("SCContentFilter(desktopIndependentWindow: includ[0])"))
        XCTAssertTrue(selectorSource.contains("windowCaptureMode: windowCaptureMode"))
        XCTAssertTrue(appSource.contains("windowCaptureMode: windowCaptureMode"))
        XCTAssertTrue(appSource.contains("fastStart: true"))
        XCTAssertTrue(settingsSource.contains("Quick Topmost Window"))
        XCTAssertTrue(selectorSource.contains("Single-window exterior"))

        XCTAssertFalse(selectorSource.contains("recordWinSound ="))
        XCTAssertFalse(selectorSource.contains("recordMic ="))
        XCTAssertFalse(appSource.contains("recordWinSound ="))
        XCTAssertFalse(appSource.contains("recordMic ="))
    }

    private func makeRoundedWindow(over sentinel: WindowCaptureMatte) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw XCTSkip("Unable to allocate a BGRA test buffer: \(status)")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                if isExterior(x: x, y: y) {
                    row[offset] = sentinel.blue
                    row[offset + 1] = sentinel.green
                    row[offset + 2] = sentinel.red
                    row[offset + 3] = 0
                } else {
                    row[offset] = 231
                    row[offset + 1] = 232
                    row[offset + 2] = 233
                    row[offset + 3] = 255
                }
            }
        }
        return buffer
    }

    private func makeSampleBuffer(imageBuffer: CVPixelBuffer) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private func makeCaptureSession(
        stream: AnyObject,
        mode: WindowCaptureMode,
        sink: TestVideoDestination
    ) -> CaptureOutputSession {
        CaptureOutputSession(
            stream: stream,
            outputJob: nil,
            writer: nil,
            videoInput: sink,
            systemAudioInput: nil,
            standaloneAudioFile: nil,
            windowSanitizer: WindowCaptureFrameSanitizer(mode: mode, matte: testMatte),
            configurationBackgroundColor: nil,
            sampleQueue: DispatchQueue(label: "WindowCapturePrivacyTests.\(mode.rawValue)"),
            isAudioOnly: false
        )
    }

    private func writeFixture(
        mode: WindowCaptureMode,
        fileType: AVFileType,
        codec: AVVideoCodecType
    ) throws -> URL {
        let profile = WindowCapturePrivacy.outputProfile(
            mode: mode,
            compatibilityFileType: fileType,
            compatibilityCodec: codec
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-corner-\(UUID().uuidString)")
            .appendingPathExtension(profile.fileExtension)
        let writer = try AVAssetWriter(outputURL: url, fileType: profile.fileType)
        let settings = WindowCapturePrivacy.videoSettings(
            profile: profile,
            width: width,
            height: height,
            compressionProperties: [AVVideoExpectedSourceFrameRateKey: 30]
        )
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), writer.error?.localizedDescription ?? "writer did not start")
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<3 {
            let buffer = try makeRoundedWindow(over: sentinels[frame])
            try WindowCapturePrivacy.sanitize(buffer, mode: mode, matte: testMatte)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()

        let finished = expectation(description: "finish \(profile.codec.rawValue)")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "writer failed")
        return url
    }

    private func executable(named name: String) -> URL? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func run(_ executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: error, as: UTF8.self)
        )
        return output
    }

    private func inspectExterior(
        of buffer: CVPixelBuffer,
        mode: WindowCaptureMode,
        sentinel: WindowCaptureMatte
    ) throws -> (sentinelPixels: Int, invalidPixels: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var sentinelPixels = 0
        var invalidPixels = 0
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where isExterior(x: x, y: y) {
                let offset = x * 4
                let blue = row[offset]
                let green = row[offset + 1]
                let red = row[offset + 2]
                let alpha = row[offset + 3]
                if red == sentinel.red && green == sentinel.green && blue == sentinel.blue {
                    sentinelPixels += 1
                }
                switch mode {
                case .transparent:
                    if red != 0 || green != 0 || blue != 0 || alpha != 0 {
                        invalidPixels += 1
                    }
                case .opaque:
                    if red != testMatte.red || green != testMatte.green || blue != testMatte.blue || alpha != 255 {
                        invalidPixels += 1
                    }
                }
            }
        }
        return (sentinelPixels, invalidPixels)
    }

    private func isExterior(x: Int, y: Int) -> Bool {
        let left = x < cornerRadius
        let right = x >= width - cornerRadius
        let bottom = y < cornerRadius
        let top = y >= height - cornerRadius
        guard (left || right) && (bottom || top) else { return false }

        let centerX = left ? cornerRadius : width - cornerRadius - 1
        let centerY = bottom ? cornerRadius : height - cornerRadius - 1
        let dx = x - centerX
        let dy = y - centerY
        return dx * dx + dy * dy >= cornerRadius * cornerRadius
    }
}

private final class TestVideoDestination: CaptureVideoSampleDestination {
    var isReadyForMoreMediaData = true
    private(set) var appendCount = 0

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        appendCount += 1
        return true
    }
}
