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
                outputPTS: trigger.pts,
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
        let audioPTS = min(duration, disconnectPTS)
        let videoPTS = appended.last?.outputPTS ?? 0
        let dimensions = canvas.dimensions
        let sentinelCount = cache.latest?.pixels.filter { $0 == WindowPrivacyBoundary.exteriorSentinel }.count ?? 0
        let postResume = appended.first { $0.outputPTS >= pauseRange.upperBound }
        let prePause = appended.last { $0.outputPTS < pauseRange.lowerBound }
        let monotonic = zip(appended, appended.dropFirst()).allSatisfy { $0.outputPTS < $1.outputPTS }
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
            pauseResumeContinuous: prePause != nil && postResume != nil && (postResume!.outputPTS - prePause!.outputPTS) > 1.0,
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
            return (ticks + browserWakeups).sorted {
                if abs($0.0 - $1.0) < 0.000_001 { return $0.1 < $1.1 }
                return $0.0 < $1.0
            }
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

do {
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
