import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

enum Candidate: String, CaseIterable, Codable {
    case screenDriven = "screen-driven"
    case cameraDriven = "camera-driven"
    case fixedClock = "fixed-clock"
    case hybrid
}

enum BrowserCase: String, CaseIterable, Codable {
    case staticPage = "static"
    case lowChange = "low-change"
    case active
}

enum Canvas: String, CaseIterable, Codable {
    case landscape = "16x9"
    case portrait = "9x16"
    case square

    var dimensions: (Int, Int) {
        switch self {
        case .landscape: (1920, 1080)
        case .portrait: (1080, 1920)
        case .square: (1080, 1080)
        }
    }
}

enum Composition: String, Codable {
    case cameraOnly = "camera-only"
    case cameraBrowser = "camera-browser"
}

struct RawBrowserFrame {
    let sequence: Int
    let pts: Double
    let pixels: [UInt32]
}

struct SanitizedBrowserFrame {
    let sequence: Int
    let pts: Double
    let pixels: [UInt32]

    fileprivate init(sequence: Int, pts: Double, pixels: [UInt32]) {
        self.sequence = sequence
        self.pts = pts
        self.pixels = pixels
    }
}

enum WindowPrivacyBoundary {
    static let exteriorSentinel: UInt32 = 0xffff4f00
    static let opaqueMatte: UInt32 = 0xff000000

    static func sanitize(_ raw: RawBrowserFrame) -> SanitizedBrowserFrame {
        var copiedPixels = raw.pixels
        for index in copiedPixels.indices where copiedPixels[index] == exteriorSentinel {
            copiedPixels[index] = opaqueMatte
        }
        return SanitizedBrowserFrame(sequence: raw.sequence, pts: raw.pts, pixels: copiedPixels)
    }
}

struct FrameCache {
    private(set) var latest: SanitizedBrowserFrame?

    mutating func store(_ frame: SanitizedBrowserFrame) {
        latest = frame
    }
}

struct CameraFrame {
    let sequence: Int
    let pts: Double
}

struct OutputEvent: Codable {
    let candidate: String
    let browserCase: String
    let canvas: String
    let outputSequence: Int
    let outputPTS: Double
    let trigger: String
    let cameraSequence: Int
    let cameraPTS: Double
    let browserSequence: Int
    let browserPTS: Double
    let browserAgeMilliseconds: Double
    let cameraLatencyMilliseconds: Double
    let duplicateCamera: Bool
    let duplicateBrowser: Bool
    let writerReady: Bool
    let outcome: String
}

struct Metrics: Codable {
    let candidate: String
    let browserCase: String
    let canvas: String
    let width: Int
    let height: Int
    let durationSeconds: Double
    let expectedActiveSeconds: Double
    let offeredFrames: Int
    let appendedFrames: Int
    let droppedWriterNotReady: Int
    let effectiveFPS: Double
    let maxOutputGapMilliseconds: Double
    let duplicateCameraFrames: Int
    let duplicateBrowserFrames: Int
    let maxBrowserAgeMilliseconds: Double
    let p95CameraLatencyMilliseconds: Double
    let maxAbsoluteAVDriftMilliseconds: Double
    let monotonicTimestamps: Bool
    let pauseResumeContinuous: Bool
    let disconnectedFailClosed: Bool
    let privacySentinelPixelsInCache: Int
}

struct NativeMetrics: Codable {
    let candidate: String
    let browserCase: String
    let canvas: String
    let composition: String
    let width: Int
    let height: Int
    let encodedVideoFrames: Int
    let encodedAudioBuffers: Int
    let writerReadinessWaits: Int
    let appendFailures: Int
    let wallSeconds: Double
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let maximumResidentBytes: Int64
    let thermalStateBefore: String
    let thermalStateAfter: String
    let privacySentinelPixelsAtCacheIngress: Int
    let privacySentinelPixelsInRenderedOutput: Int
    let outputDurationSeconds: Double
}

struct Simulation {
    let candidate: Candidate
    let browserCase: BrowserCase
    let canvas: Canvas
    let duration = 12.0
    let frameInterval = 1.0 / 30.0
    let pauseRange = 4.0..<5.0
    let disconnectPTS = 10.0
    let writerBlockedRanges = [2.20..<2.32, 7.40..<7.58]

    func run() -> (Metrics, [OutputEvent]) {
        let cameraFrames = stride(from: 0.0, through: duration, by: frameInterval).enumerated().map {
            CameraFrame(sequence: $0.offset, pts: $0.element)
        }
        let browserFrames = makeBrowserFrames()
        let renderTriggers = makeTriggers(cameraFrames: cameraFrames, browserFrames: browserFrames)
        var cache = FrameCache()
        var browserCursor = 0
        var cameraCursor = 0
        var events = [OutputEvent]()
        var lastAppendedCamera: Int?
        var lastAppendedBrowser: Int?
        var outputSequence = 0

        for trigger in renderTriggers where trigger.pts <= duration {
            while browserCursor < browserFrames.count, browserFrames[browserCursor].pts <= trigger.pts + 0.000_001 {
                cache.store(WindowPrivacyBoundary.sanitize(browserFrames[browserCursor]))
                browserCursor += 1
            }
            while cameraCursor + 1 < cameraFrames.count,
                  cameraFrames[cameraCursor + 1].pts <= trigger.pts + 0.000_001 {
                cameraCursor += 1
            }
            guard let browser = cache.latest else { continue }
            let camera = cameraFrames[cameraCursor]
            let isPaused = pauseRange.contains(trigger.pts)
            let isDisconnected = trigger.pts >= disconnectPTS
            let writerReady = !writerBlockedRanges.contains(where: { $0.contains(trigger.pts) })
            let outputPTS = trigger.pts >= pauseRange.upperBound
                ? trigger.pts - (pauseRange.upperBound - pauseRange.lowerBound)
                : trigger.pts
            let outcome: String
            if isDisconnected { outcome = "refused-camera-disconnected" }
            else if isPaused { outcome = "paused" }
            else if !writerReady { outcome = "dropped-writer-not-ready" }
            else { outcome = "appended" }
            let duplicateCamera = lastAppendedCamera == camera.sequence
            let duplicateBrowser = lastAppendedBrowser == browser.sequence
            let event = OutputEvent(
                candidate: candidate.rawValue,
                browserCase: browserCase.rawValue,
                canvas: canvas.rawValue,
                outputSequence: outputSequence,
                outputPTS: outputPTS,
                trigger: trigger.kind,
                cameraSequence: camera.sequence,
                cameraPTS: camera.pts,
                browserSequence: browser.sequence,
                browserPTS: browser.pts,
                browserAgeMilliseconds: max(0, trigger.pts - browser.pts) * 1_000,
                cameraLatencyMilliseconds: max(0, trigger.pts - camera.pts) * 1_000,
                duplicateCamera: duplicateCamera,
                duplicateBrowser: duplicateBrowser,
                writerReady: writerReady,
                outcome: outcome
            )
            events.append(event)
            outputSequence += 1
            if outcome == "appended" {
                lastAppendedCamera = camera.sequence
                lastAppendedBrowser = browser.sequence
            }
        }

        let appended = events.filter { $0.outcome == "appended" }
        let activeDuration = duration - pauseRange.upperBound + pauseRange.lowerBound - (duration - disconnectPTS)
        let gaps = zip(appended, appended.dropFirst()).map { ($1.outputPTS - $0.outputPTS) * 1_000 }
        let cameraLatencies = appended.map(\.cameraLatencyMilliseconds).sorted()
        let p95Index = cameraLatencies.isEmpty ? 0 : min(cameraLatencies.count - 1, Int(Double(cameraLatencies.count) * 0.95))
        let audioPTS = min(duration, disconnectPTS) - (pauseRange.upperBound - pauseRange.lowerBound)
        let videoPTS = appended.last?.outputPTS ?? 0
        let dimensions = canvas.dimensions
        let sentinelCount = cache.latest?.pixels.filter { $0 == WindowPrivacyBoundary.exteriorSentinel }.count ?? 0
        let postResume = appended.first { $0.outputPTS >= pauseRange.lowerBound }
        let prePause = appended.last { $0.outputPTS < pauseRange.lowerBound }
        let monotonic = zip(appended, appended.dropFirst()).allSatisfy { $0.outputPTS < $1.outputPTS }
        let normalResumeGap = candidate == .screenDriven && browserCase == .lowChange ? 1.01 : frameInterval * 2.01
        let metrics = Metrics(
            candidate: candidate.rawValue,
            browserCase: browserCase.rawValue,
            canvas: canvas.rawValue,
            width: dimensions.0,
            height: dimensions.1,
            durationSeconds: duration,
            expectedActiveSeconds: activeDuration,
            offeredFrames: events.count,
            appendedFrames: appended.count,
            droppedWriterNotReady: events.filter { $0.outcome == "dropped-writer-not-ready" }.count,
            effectiveFPS: activeDuration > 0 ? Double(appended.count) / activeDuration : 0,
            maxOutputGapMilliseconds: gaps.max() ?? 0,
            duplicateCameraFrames: appended.filter(\.duplicateCamera).count,
            duplicateBrowserFrames: appended.filter(\.duplicateBrowser).count,
            maxBrowserAgeMilliseconds: appended.map(\.browserAgeMilliseconds).max() ?? 0,
            p95CameraLatencyMilliseconds: cameraLatencies.isEmpty ? 0 : cameraLatencies[p95Index],
            maxAbsoluteAVDriftMilliseconds: abs(audioPTS - videoPTS) * 1_000,
            monotonicTimestamps: monotonic,
            pauseResumeContinuous: prePause != nil && postResume != nil
                && (postResume!.outputPTS - prePause!.outputPTS) <= normalResumeGap,
            disconnectedFailClosed: !events.contains { $0.outputPTS >= disconnectPTS && $0.outcome == "appended" },
            privacySentinelPixelsInCache: sentinelCount
        )
        return (metrics, events)
    }

    private func makeBrowserFrames() -> [RawBrowserFrame] {
        let times: [Double]
        switch browserCase {
        case .staticPage: times = [0]
        case .lowChange: times = stride(from: 0.0, through: duration, by: 1.0).map { $0 }
        case .active: times = stride(from: 0.0, through: duration, by: frameInterval).map { $0 }
        }
        return times.enumerated().map { index, pts in
            RawBrowserFrame(
                sequence: index,
                pts: pts,
                pixels: [WindowPrivacyBoundary.exteriorSentinel, 0xff336699, 0xff224466, WindowPrivacyBoundary.exteriorSentinel]
            )
        }
    }

    private func makeTriggers(cameraFrames: [CameraFrame], browserFrames: [RawBrowserFrame]) -> [(pts: Double, kind: String)] {
        switch candidate {
        case .screenDriven:
            return browserFrames.map { ($0.pts, "screen") }
        case .cameraDriven:
            return cameraFrames.map { ($0.pts, "camera") }
        case .fixedClock:
            return stride(from: 0.0, through: duration, by: frameInterval).map { ($0, "fixed") }
        case .hybrid:
            let ticks = stride(from: 0.0, through: duration, by: frameInterval).map { ($0, "camera-motion") }
            let browserWakeups = browserFrames.map { ($0.pts, "screen-wakeup") }
            var coalesced = [Int: (pts: Double, kind: String)]()
            for trigger in ticks + browserWakeups {
                let key = Int((trigger.0 * 1_000_000).rounded())
                if let existing = coalesced[key] {
                    coalesced[key] = (existing.pts, "coalesced-camera-screen")
                } else {
                    coalesced[key] = trigger
                }
            }
            return coalesced.values.sorted { $0.pts < $1.pts }
        }
    }
}

struct Arguments {
    let candidate: Candidate
    let browserCase: BrowserCase
    let canvas: Canvas
    let metricsURL: URL
    let eventsURL: URL

    init() throws {
        let values = CommandLine.arguments
        guard values.count == 6,
              let candidate = Candidate(rawValue: values[1]),
              let browserCase = BrowserCase(rawValue: values[2]),
              let canvas = Canvas(rawValue: values[3]) else {
            throw NSError(domain: "CadenceProbe", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "usage: cadence-probe <screen-driven|camera-driven|fixed-clock|hybrid> <static|low-change|active> <16x9|9x16|square> <metrics.json> <events.jsonl>"
            ])
        }
        self.candidate = candidate
        self.browserCase = browserCase
        self.canvas = canvas
        metricsURL = URL(fileURLWithPath: values[4])
        eventsURL = URL(fileURLWithPath: values[5])
    }
}

enum NativeRendererError: Error {
    case cannotAddInput(String)
    case cannotStartWriter(String)
    case missingPixelBufferPool
    case pixelBufferAllocation(CVReturn)
    case missingAudioBuffer
    case audioSampleCreation
    case appendFailed(String)
    case finishFailed(String)
}

struct NativeRenderer {
    let candidate: Candidate
    let browserCase: BrowserCase
    let canvas: Canvas
    let composition: Composition
    let outputURL: URL

    func render(events: [OutputEvent]) throws -> NativeMetrics {
        let dimensions = canvas.dimensions
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimensions.0,
            AVVideoHeightKey: dimensions.1,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.0,
                kCVPixelBufferHeightKey as String: dimensions.1,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw NativeRendererError.cannotAddInput("video") }
        guard writer.canAdd(audioInput) else { throw NativeRendererError.cannotAddInput("audio") }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw NativeRendererError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw NativeRendererError.missingPixelBufferPool }

        var usageBefore = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)
        let wallStart = ContinuousClock.now
        let thermalBefore = thermalDescription(ProcessInfo.processInfo.thermalState)
        let privacyProbe = WindowPrivacyBoundary.sanitize(
            RawBrowserFrame(
                sequence: 0,
                pts: 0,
                pixels: [
                    WindowPrivacyBoundary.exteriorSentinel,
                    0xff336699,
                    WindowPrivacyBoundary.exteriorSentinel,
                ]
            )
        )
        var privacyCache = FrameCache()
        privacyCache.store(privacyProbe)
        let sentinelPixelsAtCacheIngress = privacyCache.latest?.pixels.filter {
            $0 == WindowPrivacyBoundary.exteriorSentinel
        }.count ?? -1
        var waits = 0
        var failures = 0
        var renderedSentinels = 0
        var encodedVideo = 0
        let appendedEvents = events.filter { $0.outcome == "appended" }

        for event in appendedEvents {
            while !videoInput.isReadyForMoreMediaData {
                waits += 1
                usleep(1_000)
            }
            var pixelBuffer: CVPixelBuffer?
            let allocation = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard allocation == kCVReturnSuccess, let pixelBuffer else {
                throw NativeRendererError.pixelBufferAllocation(allocation)
            }
            fill(pixelBuffer: pixelBuffer, event: event)
            renderedSentinels += countSentinels(in: pixelBuffer)
            if adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(seconds: event.outputPTS, preferredTimescale: 60_000)
            ) {
                encodedVideo += 1
            } else {
                failures += 1
                throw NativeRendererError.appendFailed(writer.error?.localizedDescription ?? "video append")
            }
        }
        videoInput.markAsFinished()

        let lastVideoPTS = appendedEvents.last?.outputPTS ?? 0
        let audioEndFrame = Int64(((lastVideoPTS + 1.0 / 30.0) * 48_000).rounded())
        var audioStartFrame: Int64 = 0
        var encodedAudio = 0
        while audioStartFrame < audioEndFrame {
            while !audioInput.isReadyForMoreMediaData {
                waits += 1
                usleep(1_000)
            }
            let frameCount = AVAudioFrameCount(min(1_024, audioEndFrame - audioStartFrame))
            guard let sample = makeAudioSample(startFrame: audioStartFrame, frameCount: frameCount) else {
                throw NativeRendererError.audioSampleCreation
            }
            guard audioInput.append(sample) else {
                failures += 1
                throw NativeRendererError.appendFailed(writer.error?.localizedDescription ?? "audio append")
            }
            audioStartFrame += Int64(frameCount)
            encodedAudio += 1
        }
        audioInput.markAsFinished()

        let finish = DispatchSemaphore(value: 0)
        writer.finishWriting { finish.signal() }
        finish.wait()
        guard writer.status == .completed else {
            throw NativeRendererError.finishFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        let wallSeconds = Double((ContinuousClock.now - wallStart).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - wallStart).components.seconds)
        var usageAfter = rusage()
        getrusage(RUSAGE_SELF, &usageAfter)
        return NativeMetrics(
            candidate: candidate.rawValue,
            browserCase: browserCase.rawValue,
            canvas: canvas.rawValue,
            composition: composition.rawValue,
            width: dimensions.0,
            height: dimensions.1,
            encodedVideoFrames: encodedVideo,
            encodedAudioBuffers: encodedAudio,
            writerReadinessWaits: waits,
            appendFailures: failures,
            wallSeconds: wallSeconds,
            userCPUSeconds: timevalSeconds(usageAfter.ru_utime) - timevalSeconds(usageBefore.ru_utime),
            systemCPUSeconds: timevalSeconds(usageAfter.ru_stime) - timevalSeconds(usageBefore.ru_stime),
            maximumResidentBytes: Int64(usageAfter.ru_maxrss),
            thermalStateBefore: thermalBefore,
            thermalStateAfter: thermalDescription(ProcessInfo.processInfo.thermalState),
            privacySentinelPixelsAtCacheIngress: sentinelPixelsAtCacheIngress,
            privacySentinelPixelsInRenderedOutput: renderedSentinels,
            outputDurationSeconds: lastVideoPTS + 1.0 / 30.0
        )
    }

    private func fill(pixelBuffer: CVPixelBuffer, event: OutputEvent) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            let browserStripe = composition == .cameraBrowser
                ? UInt32((y / 24 + event.browserSequence) % 32)
                : 0
            let color = composition == .cameraBrowser
                ? UInt32(0xff202830) | (browserStripe << 8)
                : UInt32(0xff181818)
            for x in 0..<width { row[x] = color }
        }
        let pipWidth = max(80, composition == .cameraBrowser ? width / 4 : width * 3 / 4)
        let pipHeight = max(80, composition == .cameraBrowser ? height / 4 : height * 3 / 4)
        let travel = max(1, width - pipWidth - 40)
        let originX = 20 + (event.cameraSequence * 7) % travel
        let originY = max(20, height - pipHeight - 20)
        for y in originY..<min(height, originY + pipHeight) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in originX..<min(width, originX + pipWidth) {
                row[x] = 0xff30b0f0
            }
        }
        let corners = [0, width - 1, (height - 1) * bytesPerRow / 4, (height - 1) * bytesPerRow / 4 + width - 1]
        let words = base.assumingMemoryBound(to: UInt32.self)
        for index in corners { words[index] = WindowPrivacyBoundary.opaqueMatte }
    }

    private func countSentinels(in pixelBuffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return -1 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var count = 0
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width where row[x] == WindowPrivacyBoundary.exteriorSentinel { count += 1 }
        }
        return count
    }

    private func makeAudioSample(startFrame: Int64, frameCount: AVAudioFrameCount) -> CMSampleBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            channel[index] = Float(sin(2 * Double.pi * 440 * Double(startFrame + Int64(index)) / 48_000) * 0.08)
        }
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: startFrame, timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.mutableAudioBufferList
        ) == noErr else { return nil }
        return sample
    }

    private func timevalSeconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

do {
    if CommandLine.arguments.dropFirst().first == "render" {
        let values = CommandLine.arguments
        guard values.count == 8,
              let candidate = Candidate(rawValue: values[2]),
              let browserCase = BrowserCase(rawValue: values[3]),
              let canvas = Canvas(rawValue: values[4]),
              let composition = Composition(rawValue: values[5]) else {
            throw NSError(domain: "CadenceProbe", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "usage: cadence-probe render <candidate> <case> <canvas> <camera-only|camera-browser> <output.mov> <native-metrics.json>"
            ])
        }
        let simulation = Simulation(candidate: candidate, browserCase: browserCase, canvas: canvas)
        let (_, events) = simulation.run()
        let outputURL = URL(fileURLWithPath: values[6])
        let nativeMetrics = try NativeRenderer(
            candidate: candidate,
            browserCase: browserCase,
            canvas: canvas,
            composition: composition,
            outputURL: outputURL
        ).render(events: events)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(nativeMetrics).write(to: URL(fileURLWithPath: values[7]), options: .atomic)
        print("rendered=\(outputURL.path) frames=\(nativeMetrics.encodedVideoFrames) wall=\(String(format: "%.3f", nativeMetrics.wallSeconds))")
        exit(0)
    }
    let arguments = try Arguments()
    let (metrics, events) = Simulation(
        candidate: arguments.candidate,
        browserCase: arguments.browserCase,
        canvas: arguments.canvas
    ).run()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(metrics).write(to: arguments.metricsURL, options: .atomic)
    let eventLines = try events.map { event -> String in
        let data = try encoder.encode(event)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "")
    }.joined(separator: "\n") + "\n"
    try eventLines.write(to: arguments.eventsURL, atomically: true, encoding: .utf8)
    print("\(metrics.candidate),\(metrics.browserCase),\(metrics.canvas),\(metrics.appendedFrames),\(String(format: "%.3f", metrics.effectiveFPS)),\(String(format: "%.3f", metrics.maxOutputGapMilliseconds)),\(metrics.droppedWriterNotReady),\(metrics.duplicateCameraFrames),\(metrics.duplicateBrowserFrames),\(String(format: "%.3f", metrics.maxBrowserAgeMilliseconds)),\(String(format: "%.3f", metrics.p95CameraLatencyMilliseconds)),\(String(format: "%.3f", metrics.maxAbsoluteAVDriftMilliseconds)),\(metrics.monotonicTimestamps),\(metrics.pauseResumeContinuous),\(metrics.disconnectedFailClosed),\(metrics.privacySentinelPixelsInCache)")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(2)
}
