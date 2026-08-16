import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import LiveProbeCore
import Security

enum LiveCandidate: String, Codable {
    case cameraDriven = "camera-driven"
    case fixedClock = "fixed-clock"
}

enum LiveCanvas: String, Codable {
    case landscape = "16x9"
    case portrait = "9x16"
    case square

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .landscape: (1920, 1080)
        case .portrait: (1080, 1920)
        case .square: (1080, 1080)
        }
    }
}

struct RuntimeSigningIdentity: Codable {
    let executablePath: String
    let codeIdentifier: String?
    let teamIdentifier: String?
    let certificateSHA1s: [String]
    let flags: UInt32?
    let approvedDeveloperIDPresent: Bool
    let inspectionError: String?

    static func current() -> RuntimeSigningIdentity {
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        var selfCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &selfCode)
        guard selfStatus == errSecSuccess, let selfCode else {
            return RuntimeSigningIdentity(
                executablePath: executablePath,
                codeIdentifier: nil,
                teamIdentifier: nil,
                certificateSHA1s: [],
                flags: nil,
                approvedDeveloperIDPresent: false,
                inspectionError: "SecCodeCopySelf status \(selfStatus)"
            )
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(selfCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return RuntimeSigningIdentity(
                executablePath: executablePath,
                codeIdentifier: nil,
                teamIdentifier: nil,
                certificateSHA1s: [],
                flags: nil,
                approvedDeveloperIDPresent: false,
                inspectionError: "SecCodeCopyStaticCode status \(staticStatus)"
            )
        }
        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard infoStatus == errSecSuccess, let values = information as? [String: Any] else {
            return RuntimeSigningIdentity(
                executablePath: executablePath,
                codeIdentifier: nil,
                teamIdentifier: nil,
                certificateSHA1s: [],
                flags: nil,
                approvedDeveloperIDPresent: false,
                inspectionError: "SecCodeCopySigningInformation status \(infoStatus)"
            )
        }
        let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let fingerprints = certificates.map { certificate in
            let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            return digest.map { String(format: "%02X", $0) }.joined()
        }
        let identifier = values[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        let approvedFingerprint = "189EC9780DE0A94CF5B24CC5983CAB3FDAE15638"
        return RuntimeSigningIdentity(
            executablePath: executablePath,
            codeIdentifier: identifier,
            teamIdentifier: teamIdentifier,
            certificateSHA1s: fingerprints,
            flags: flags,
            approvedDeveloperIDPresent: teamIdentifier == "F66FM4V88Q" && fingerprints.contains(approvedFingerprint),
            inspectionError: nil
        )
    }
}

struct AuthorizationSnapshot: Codable {
    let camera: String
    let microphone: String
    let screenCapturePreflightGranted: Bool

    static func current() -> AuthorizationSnapshot {
        AuthorizationSnapshot(
            camera: description(AVCaptureDevice.authorizationStatus(for: .video)),
            microphone: description(AVCaptureDevice.authorizationStatus(for: .audio)),
            screenCapturePreflightGranted: CGPreflightScreenCaptureAccess()
        )
    }

    private static func description(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not-determined"
        @unknown default: "unknown"
        }
    }
}

struct LiveSourceInventory: Codable {
    let generatedAt: String
    let cameras: [StableCameraSource]
    let windows: [CapturableWindowSource]
    let authorization: AuthorizationSnapshot
    let signing: RuntimeSigningIdentity
    let windowQuery: String
}

struct LiveEvent: Codable {
    let kind: String
    let uptimeNanoseconds: UInt64
    let outputPTSSeconds: Double?
    let value: Double?
    let detail: String?
}

struct LiveRunMetrics: Codable {
    let schema: String
    let candidate: String
    let canvas: String
    let fps: Int
    let requestedDurationSeconds: Double
    let outputPath: String
    let selectedCamera: StableCameraSource
    let selectedWindow: CapturableWindowSource?
    let authorizationBefore: AuthorizationSnapshot
    let authorizationAfter: AuthorizationSnapshot
    let signing: RuntimeSigningIdentity
    let startedAt: String
    let finishedAt: String
    let stopReason: String
    let videoFramesAppended: Int
    let videoFramesDroppedNotReady: Int
    let videoAppendFailures: Int
    let cameraCallbacks: Int
    let windowCallbacks: Int
    let systemAudioCallbacks: Int
    let microphoneCallbacks: Int
    let audioDropsNotReady: Int
    let timestampRejections: Int
    let duplicateCameraFrames: Int
    let duplicateWindowFrames: Int
    let cameraCallbackMeanIntervalMilliseconds: Double?
    let cameraCallbackP95JitterMilliseconds: Double?
    let windowCallbackMeanIntervalMilliseconds: Double?
    let outputMeanIntervalMilliseconds: Double?
    let outputP95JitterMilliseconds: Double?
    let cameraToOutputP95Milliseconds: Double?
    let browserAgeP95Milliseconds: Double?
    let maximumBrowserAgeMilliseconds: Double?
    let finalSystemAudioVideoDriftMilliseconds: Double?
    let finalMicrophoneVideoDriftMilliseconds: Double?
    let monotonicTimestamps: Bool
    let pauseCount: Int
    let resumeCount: Int
    let selectedCameraDisconnected: Bool
    let privacySentinelPixelsAtCacheIngress: Int
    let privacySentinelPixelsRendered: Int
    let privacyUnsanitizedExteriorPixelsAtCacheIngress: Int
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let maximumResidentBytes: Int64
    let thermalStateBefore: String
    let thermalStateAfter: String
    let powermetricsHookPath: String?
    let eventsPath: String
}

enum LiveProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case screenPermissionMissing
    case cameraPermissionMissing(String)
    case microphonePermissionMissing(String)
    case outputAlreadyExists(String)
    case outputDirectoryMissing(String)
    case selectedWindowRequired
    case writer(String)
    case capture(String)
    case privacy(String)
    case signingNotApproved

    var description: String {
        switch self {
        case .invalidArguments(let value): value
        case .screenPermissionMissing: "Screen Recording authorization is not already granted; no permission request was made."
        case .cameraPermissionMissing(let value): "Camera authorization must already be authorized (current: \(value)); no permission request was made."
        case .microphonePermissionMissing(let value): "Microphone authorization must already be authorized (current: \(value)); no permission request was made."
        case .outputAlreadyExists(let path): "Refusing to overwrite output: \(path)"
        case .outputDirectoryMissing(let path): "Output directory does not exist: \(path)"
        case .selectedWindowRequired: "A camera/browser run requires --window-id with an exact capturable window ID."
        case .writer(let value): "Writer failure: \(value)"
        case .capture(let value): "Capture failure: \(value)"
        case .privacy(let value): "Privacy boundary failure: \(value)"
        case .signingNotApproved: "Live recording requires the exact approved Developer ID fingerprint 189EC9780DE0A94CF5B24CC5983CAB3FDAE15638."
        }
    }
}

func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}
