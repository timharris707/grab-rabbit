import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import LiveProbeCore

struct FailureReport: Codable {
    var schema = "grab-rabbit-live-cadence-failure-v1"
    let command: String
    let generatedAt: String
    let error: String
    let exitCode: Int32
    let outputCreated: Bool
    let privacySentinelPixels: Int?
    let authorization: AuthorizationSnapshot
    let signing: RuntimeSigningIdentity
}

struct CLIOptions {
    private let values: [String: String]
    private let flags: Set<String>

    init(arguments: [String]) throws {
        var values = [String: String]()
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                throw LiveProbeError.invalidArguments("Unexpected argument: \(key)")
            }
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[key] = arguments[index + 1]
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
        self.values = values
        self.flags = flags
    }

    func value(_ key: String) -> String? { values[key] }
    func has(_ key: String) -> Bool { flags.contains(key) }
    func required(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw LiveProbeError.invalidArguments("Missing required \(key)")
        }
        return value
    }
    func double(_ key: String, default fallback: Double) throws -> Double {
        guard let raw = values[key] else { return fallback }
        guard let value = Double(raw) else { throw LiveProbeError.invalidArguments("Invalid \(key): \(raw)") }
        return value
    }
    func int(_ key: String, default fallback: Int) throws -> Int {
        guard let raw = values[key] else { return fallback }
        guard let value = Int(raw) else { throw LiveProbeError.invalidArguments("Invalid \(key): \(raw)") }
        return value
    }
}

@main
struct LiveCadenceProbeMain {
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 2 else { throw usageError() }
            let command = CommandLine.arguments[1]
            let options = try CLIOptions(arguments: Array(CommandLine.arguments.dropFirst(2)))
            switch command {
            case "list-sources":
                try await listSources(options)
            case "preflight":
                try await preflight(options)
            case "authorize":
                try await authorize(options)
            case "record":
                try await record(options)
            default:
                throw usageError()
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(exitCode(for: error))
        }
    }

    private static func listSources(_ options: CLIOptions) async throws {
        let (inventory, _) = await LiveSourceDiscovery.inventory(queryWindows: !options.has("--skip-window-query"))
        let data = try prettyEncoder().encode(inventory)
        if let path = options.value("--json") {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func preflight(_ options: CLIOptions) async throws {
        let cameraID = try options.required("--camera-id")
        let windowID = try parseWindowID(options.value("--window-id"))
        let outputPath = options.value("--output")
        let reportPath = options.value("--json")
        let queryWindows = windowID != nil
        let (inventory, _) = await LiveSourceDiscovery.inventory(queryWindows: queryWindows)
        let sentinelResult = try SanitizedWindowFrameFactory.sentinelProbe()
        guard sentinelResult == 0 else { throw LiveProbeError.privacy("sentinel self-test left \(sentinelResult) pixels") }
        do {
            _ = try LiveSourceSelection.afterValidatedSources(
                cameraID: cameraID,
                cameras: inventory.cameras,
                windowID: windowID,
                windows: inventory.windows,
                createOutput: { true }
            )
            let report: [String: Any] = [
                "schema": "grab-rabbit-live-cadence-preflight-v1",
                "generated_at": iso8601Now(),
                "passed": true,
                "exact_camera_id_matched_in_process": true,
                "exact_window_id_matched_in_process": windowID != nil,
                "output_created": false,
                "output_path": outputPath as Any,
                "privacy_sentinel_pixels": sentinelResult,
                "authorization": try jsonObject(inventory.authorization),
                "signing": try jsonObject(inventory.signing),
                "stage_seams": [
                    "camera-verification",
                    "stable-approved-signing-tcc",
                    "browser-selection-cases",
                    "shape-pause-disconnect-matrix",
                    "external-powermetrics",
                    "verification-visual-verdict",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let reportPath { try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic) }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            let code = exitCode(for: error)
            let report = FailureReport(
                command: "preflight",
                generatedAt: iso8601Now(),
                error: String(describing: error),
                exitCode: code,
                outputCreated: outputPath.map { FileManager.default.fileExists(atPath: $0) } ?? false,
                privacySentinelPixels: sentinelResult,
                authorization: inventory.authorization,
                signing: inventory.signing
            )
            let data = try prettyEncoder().encode(report)
            if let reportPath { try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic) }
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
            exit(code)
        }
    }

    private static func authorize(_ options: CLIOptions) async throws {
        let reportURL = URL(fileURLWithPath: try options.required("--json"))
        try validateNewOutput(reportURL)
        let signing = RuntimeSigningIdentity.current()
        guard signing.approvedDeveloperIDPresent else { throw LiveProbeError.signingNotApproved }
        let before = AuthorizationSnapshot.current()
        let cameraGranted = before.camera == "authorized"
            ? true
            : await AVCaptureDevice.requestAccess(for: .video)
        let microphoneGranted = before.microphone == "authorized"
            ? true
            : await AVCaptureDevice.requestAccess(for: .audio)
        let screenCaptureGranted = before.screenCapturePreflightGranted
            ? true
            : CGRequestScreenCaptureAccess()
        let report = AuthorizationReport(
            schema: "grab-rabbit-live-cadence-authorization-v1",
            generatedAt: iso8601Now(),
            signing: signing,
            before: before,
            cameraGranted: cameraGranted,
            microphoneGranted: microphoneGranted,
            screenCaptureGranted: screenCaptureGranted,
            after: AuthorizationSnapshot.current()
        )
        let data = try prettyEncoder().encode(report)
        try data.write(to: reportURL, options: .atomic)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        guard cameraGranted, microphoneGranted, screenCaptureGranted else {
            throw LiveProbeError.capture("one or more requested TCC grants remain unavailable")
        }
    }

    private static func record(_ options: CLIOptions) async throws {
        let cameraID = try options.required("--camera-id")
        let windowID = try parseWindowID(options.value("--window-id"))
        let outputURL = URL(fileURLWithPath: try options.required("--output"))
        let metricsURL = URL(fileURLWithPath: try options.required("--metrics"))
        let eventsURL = URL(fileURLWithPath: try options.required("--events"))
        let candidateRaw = try options.required("--candidate")
        let canvasRaw = try options.required("--canvas")
        guard let candidate = LiveCandidate(rawValue: candidateRaw) else {
            throw LiveProbeError.invalidArguments("Candidate must be camera-driven or fixed-clock")
        }
        guard let canvas = LiveCanvas(rawValue: canvasRaw) else {
            throw LiveProbeError.invalidArguments("Canvas must be 16x9, 9x16, or square")
        }
        let fps = try options.int("--fps", default: 30)
        let duration = try options.double("--duration", default: 12)
        let pauseAt = try options.double("--pause-at", default: -1)
        let pauseDuration = try options.double("--pause-duration", default: 0)
        guard (1...60).contains(fps), duration > 0, pauseDuration >= 0 else {
            throw LiveProbeError.invalidArguments("Invalid fps/duration/pause values")
        }
        let includeSystemAudio = options.has("--system-audio")
        let includeMicrophone = options.has("--microphone")
        if includeSystemAudio && windowID == nil { throw LiveProbeError.selectedWindowRequired }
        try validateNewOutput(outputURL)
        try validateNewOutput(metricsURL)
        try validateNewOutput(eventsURL)

        let authorizationBefore = AuthorizationSnapshot.current()
        guard authorizationBefore.camera == "authorized" else {
            throw LiveProbeError.cameraPermissionMissing(authorizationBefore.camera)
        }
        if windowID != nil, !authorizationBefore.screenCapturePreflightGranted {
            throw LiveProbeError.screenPermissionMissing
        }
        if includeMicrophone, authorizationBefore.microphone != "authorized" {
            throw LiveProbeError.microphonePermissionMissing(authorizationBefore.microphone)
        }
        let signing = RuntimeSigningIdentity.current()
        guard signing.approvedDeveloperIDPresent else { throw LiveProbeError.signingNotApproved }
        let sentinelResult = try SanitizedWindowFrameFactory.sentinelProbe()
        guard sentinelResult == 0 else { throw LiveProbeError.privacy("sentinel self-test left \(sentinelResult) pixels") }

        let (inventory, nativeWindows) = await LiveSourceDiscovery.inventory(queryWindows: windowID != nil)
        let selectedCamera = try LiveSourceSelection.camera(uniqueID: cameraID, from: inventory.cameras)
        let selectedWindow = try windowID.map { try LiveSourceSelection.window(windowID: $0, from: inventory.windows) }
        guard let cameraDevice = LiveSourceDiscovery.cameraDevices().first(where: { $0.uniqueID == selectedCamera.uniqueID }) else {
            throw LiveSourceSelectionError.cameraNotFound(selectedCamera.uniqueID)
        }
        let nativeWindow = windowID.flatMap { id in nativeWindows.first(where: { $0.windowID == id }) }
        if windowID != nil, nativeWindow == nil { throw LiveSourceSelectionError.windowNotFound(windowID!) }

        var usageBefore = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)
        let thermalBefore = thermalDescription(ProcessInfo.processInfo.thermalState)
        let startedAt = iso8601Now()
        let coordinator = try LiveCaptureCoordinator(
            candidate: candidate,
            canvas: canvas,
            fps: fps,
            requiresWindow: windowID != nil,
            outputURL: outputURL,
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: includeMicrophone
        )
        let runtime = LiveCaptureRuntime(
            coordinator: coordinator,
            cameraDevice: cameraDevice,
            window: nativeWindow,
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: includeMicrophone
        )
        do {
            try await runtime.start()
            if pauseAt >= 0, pauseAt < duration, pauseDuration > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(pauseAt))
                    guard coordinator.requestedStopReason == nil else { return }
                    coordinator.setPaused(true)
                    try? await Task.sleep(for: .seconds(pauseDuration))
                    guard coordinator.requestedStopReason == nil else { return }
                    coordinator.setPaused(false)
                }
            }
            let deadline = ContinuousClock.now + .seconds(duration)
            while ContinuousClock.now < deadline, coordinator.requestedStopReason == nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            await runtime.stop()
            let stopReason = try await coordinator.finish(defaultReason: "duration-complete")
            try coordinator.statistics.writeEvents(to: eventsURL)
            let summary = coordinator.statistics.summary()
            var usageAfter = rusage()
            getrusage(RUSAGE_SELF, &usageAfter)
            let metrics = buildMetrics(
                candidate: candidate,
                canvas: canvas,
                fps: fps,
                duration: duration,
                outputURL: outputURL,
                selectedCamera: LiveCameraEvidence(
                    name: selectedCamera.name,
                    deviceType: selectedCamera.deviceType,
                    exactUniqueIDMatchedInProcess: true
                ),
                selectedWindow: selectedWindow.map {
                    LiveWindowEvidence(
                        applicationName: $0.applicationName,
                        width: $0.width,
                        height: $0.height,
                        exactWindowIDMatchedInProcess: true
                    )
                },
                authorizationBefore: authorizationBefore,
                authorizationAfter: AuthorizationSnapshot.current(),
                signing: signing,
                startedAt: startedAt,
                stopReason: stopReason,
                summary: summary,
                usageBefore: usageBefore,
                usageAfter: usageAfter,
                thermalBefore: thermalBefore,
                powermetricsHookPath: options.value("--powermetrics-path"),
                eventsURL: eventsURL
            )
            try prettyEncoder().encode(metrics).write(to: metricsURL, options: .atomic)
            FileHandle.standardOutput.write(try prettyEncoder().encode(metrics))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            await runtime.stop()
            coordinator.requestStop(reason: "runtime-error: \(error)")
            _ = try? await coordinator.finish(defaultReason: "runtime-error")
            try? coordinator.statistics.writeEvents(to: eventsURL)
            throw error
        }
    }

    private static func buildMetrics(
        candidate: LiveCandidate,
        canvas: LiveCanvas,
        fps: Int,
        duration: Double,
        outputURL: URL,
        selectedCamera: LiveCameraEvidence,
        selectedWindow: LiveWindowEvidence?,
        authorizationBefore: AuthorizationSnapshot,
        authorizationAfter: AuthorizationSnapshot,
        signing: RuntimeSigningIdentity,
        startedAt: String,
        stopReason: String,
        summary: StatisticsSummary,
        usageBefore: rusage,
        usageAfter: rusage,
        thermalBefore: String,
        powermetricsHookPath: String?,
        eventsURL: URL
    ) -> LiveRunMetrics {
        let videoPTS = summary.events.compactMap { $0.kind == "video-appended" ? $0.outputPTSSeconds : nil }
        return LiveRunMetrics(
            schema: "grab-rabbit-live-cadence-run-v1",
            candidate: candidate.rawValue,
            canvas: canvas.rawValue,
            fps: fps,
            requestedDurationSeconds: duration,
            outputPath: outputURL.path,
            selectedCamera: selectedCamera,
            selectedWindow: selectedWindow,
            authorizationBefore: authorizationBefore,
            authorizationAfter: authorizationAfter,
            signing: signing,
            startedAt: startedAt,
            finishedAt: iso8601Now(),
            stopReason: stopReason,
            videoFramesAppended: summary.videoFramesAppended,
            videoFramesDroppedNotReady: summary.videoFramesDroppedNotReady,
            videoAppendFailures: summary.videoAppendFailures,
            cameraCallbacks: summary.cameraCallbacks,
            windowCallbacks: summary.windowCallbacks,
            systemAudioCallbacks: summary.systemAudioCallbacks,
            microphoneCallbacks: summary.microphoneCallbacks,
            audioDropsNotReady: summary.audioDropsNotReady,
            timestampRejections: summary.timestampRejections,
            duplicateCameraFrames: summary.duplicateCameraFrames,
            duplicateWindowFrames: summary.duplicateWindowFrames,
            cameraCallbackMeanIntervalMilliseconds: meanInterval(summary.cameraCallbackTimes),
            cameraCallbackP95JitterMilliseconds: p95Jitter(summary.cameraCallbackTimes, targetMilliseconds: 1_000 / Double(fps)),
            windowCallbackMeanIntervalMilliseconds: meanInterval(summary.windowCallbackTimes),
            outputMeanIntervalMilliseconds: meanInterval(summary.outputTimes),
            outputP95JitterMilliseconds: p95Jitter(summary.outputTimes, targetMilliseconds: 1_000 / Double(fps)),
            cameraToOutputP95Milliseconds: percentile(summary.cameraLatenciesMilliseconds, 0.95),
            browserAgeP95Milliseconds: percentile(summary.browserAgesMilliseconds, 0.95),
            maximumBrowserAgeMilliseconds: summary.browserAgesMilliseconds.max(),
            finalSystemAudioVideoDriftMilliseconds: drift(summary.lastSystemAudioPTS, summary.lastVideoPTS),
            finalMicrophoneVideoDriftMilliseconds: drift(summary.lastMicrophonePTS, summary.lastVideoPTS),
            monotonicTimestamps: zip(videoPTS, videoPTS.dropFirst()).allSatisfy { $0 < $1 },
            pauseCount: summary.pauseCount,
            resumeCount: summary.resumeCount,
            selectedCameraDisconnected: summary.selectedCameraDisconnected,
            privacySentinelPixelsAtCacheIngress: summary.privacySentinelPixelsAtCacheIngress,
            privacySentinelPixelsRendered: summary.privacySentinelPixelsRendered,
            privacyUnsanitizedExteriorPixelsAtCacheIngress: summary.privacyUnsanitizedExteriorPixelsAtCacheIngress,
            userCPUSeconds: timevalSeconds(usageAfter.ru_utime) - timevalSeconds(usageBefore.ru_utime),
            systemCPUSeconds: timevalSeconds(usageAfter.ru_stime) - timevalSeconds(usageBefore.ru_stime),
            maximumResidentBytes: Int64(usageAfter.ru_maxrss),
            thermalStateBefore: thermalBefore,
            thermalStateAfter: thermalDescription(ProcessInfo.processInfo.thermalState),
            powermetricsHookPath: powermetricsHookPath,
            eventsPath: eventsURL.path
        )
    }

    private static func validateNewOutput(_ url: URL) throws {
        guard url.path.hasPrefix("/") else { throw LiveProbeError.invalidArguments("Output paths must be absolute") }
        if FileManager.default.fileExists(atPath: url.path) { throw LiveProbeError.outputAlreadyExists(url.path) }
        var isDirectory: ObjCBool = false
        let parent = url.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LiveProbeError.outputDirectoryMissing(parent)
        }
    }

    private static func parseWindowID(_ raw: String?) throws -> UInt32? {
        guard let raw else { return nil }
        guard let value = UInt32(raw) else { throw LiveProbeError.invalidArguments("Invalid --window-id: \(raw)") }
        return value
    }

    private static func prettyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: prettyEncoder().encode(value))
    }

    private static func meanInterval(_ times: [UInt64]) -> Double? {
        let values = intervals(times)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func p95Jitter(_ times: [UInt64], targetMilliseconds: Double) -> Double? {
        percentile(intervals(times).map { abs($0 - targetMilliseconds) }, 0.95)
    }

    private static func intervals(_ times: [UInt64]) -> [Double] {
        zip(times, times.dropFirst()).map { Double($1 - $0) / 1_000_000 }
    }

    private static func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * quantile).rounded(.up)))]
    }

    private static func drift(_ audio: Double?, _ video: Double?) -> Double? {
        guard let audio, let video else { return nil }
        return abs(audio - video) * 1_000
    }

    private static func timevalSeconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private static func exitCode(for error: Error) -> Int32 {
        if let source = error as? LiveSourceSelectionError {
            switch source {
            case .noCameras: return 20
            case .cameraNotFound: return 21
            case .noCapturableWindows, .windowNotFound: return 22
            }
        }
        if let live = error as? LiveProbeError {
            switch live {
            case .screenPermissionMissing, .cameraPermissionMissing, .microphonePermissionMissing: return 23
            case .signingNotApproved: return 24
            case .privacy: return 25
            case .invalidArguments: return 2
            default: return 1
            }
        }
        return 1
    }

    private static func usageError() -> LiveProbeError {
        .invalidArguments("""
        usage:
          live-cadence-probe list-sources [--json PATH] [--skip-window-query]
          live-cadence-probe preflight --camera-id ID [--window-id ID] [--output PATH] [--json PATH]
          live-cadence-probe authorize --json /absolute/authorization.json
          live-cadence-probe record --camera-id ID [--window-id ID] --candidate camera-driven|fixed-clock --canvas 16x9|9x16|square --output PATH --metrics PATH --events PATH [--duration S] [--fps N] [--pause-at S --pause-duration S] [--system-audio] [--microphone] [--powermetrics-path PATH]
        """)
    }
}
