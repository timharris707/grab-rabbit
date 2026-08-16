import Foundation

enum ProbeError: LocalizedError {
    case invalidArguments(String)
    case invalidManifest(String)
    case missingCamera(String)
    case cameraAccessDenied
    case captureFailed(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message),
             let .invalidManifest(message),
             let .missingCamera(message),
             let .captureFailed(message),
             let .processingFailed(message):
            return message
        case .cameraAccessDenied:
            return "Camera access was denied. Allow Grab Rabbit Foreground Probe in System Settings > Privacy & Security > Camera, then retry."
        }
    }
}

struct PhaseDefinition: Codable, Hashable {
    let label: String
    let startSeconds: Double
    let endSeconds: Double

    static let standard: [PhaseDefinition] = [
        .init(label: "seated-stillness", startSeconds: 0, endSeconds: 5),
        .init(label: "speaking-motion", startSeconds: 5, endSeconds: 11),
        .init(label: "hand-arm-occlusion-microphone", startSeconds: 11, endSeconds: 17),
        .init(label: "hand-arm-occlusion-chair", startSeconds: 17, endSeconds: 23),
        .init(label: "chair-movement", startSeconds: 23, endSeconds: 29),
        .init(label: "final-stillness", startSeconds: 29, endSeconds: 32),
    ]
}

struct HostSnapshot: Codable {
    let computerName: String
    let hostName: String
    let hardwareModel: String
    let architecture: String
    let operatingSystem: String
    let operatingSystemVersion: String
}

struct FormatSnapshot: Codable {
    let width: Int32
    let height: Int32
    let nominalFramesPerSecond: Double
    let pixelFormat: String
}

struct EffectSnapshot: Codable {
    let backgroundReplacementEnabled: Bool
    let backgroundReplacementActive: Bool
    let centerStageEnabled: Bool
    let centerStageActive: Bool
    let portraitEffectEnabled: Bool
    let portraitEffectActive: Bool
    let studioLightEnabled: Bool
    let studioLightActive: Bool
}

struct CameraSnapshot: Codable {
    let name: String
    let uniqueID: String
    let modelID: String
    let manufacturer: String
    let deviceType: String
    let cameraClass: String
    let isContinuityCamera: Bool
    let isConnected: Bool
    let isSuspended: Bool
    let format: FormatSnapshot
    let effects: EffectSnapshot
}

struct VisionCandidateInventory: Codable {
    let id: String
    let request: String
    let configuration: String
    let supportedComputeStageDevices: [String: [String]]
}

struct InventoryDocument: Codable {
    let version: Int
    let generatedAt: String
    let host: HostSnapshot
    let cameraAuthorization: String
    let cameras: [CameraSnapshot]
    let candidates: [VisionCandidateInventory]
}

struct CaptureMetadata: Codable {
    let version: Int
    let capturedAt: String
    let clipID: String
    let lighting: String
    let sourceFile: String
    let sourceSHA256: String
    let sourceBytes: Int64
    let durationSeconds: Double
    let host: HostSnapshot
    let camera: CameraSnapshot
    let phases: [PhaseDefinition]
    let captureNotes: [String]
}

struct ExperimentManifest: Codable {
    let version: Int
    let experimentID: String
    let clips: [ClipSpecification]
}

struct ClipSpecification: Codable {
    let id: String
    let source: String
    let captureMetadata: String?
    let cameraClass: String
    let cameraName: String
    let lighting: String
    let phases: [PhaseDefinition]?
    let regions: [RegionSpecification]
}

struct RegionSpecification: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case person
        case chair
        case microphone
        case background
    }

    let label: String
    let kind: Kind
    let startSeconds: Double
    let endSeconds: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct RegionFrameMeasurement: Codable {
    let kind: String
    let binaryCoverageFraction: Double
    let meanMaskValue: Double
}

struct MaskFrameMeasurement: Codable {
    let binaryCoverageFraction: Double
    let meanMaskValue: Double
    let temporalXORFraction: Double?
    let temporalIntersectionOverUnion: Double?
    let boundaryFraction: Double
    let regions: [String: RegionFrameMeasurement]
}

struct FrameMeasurement: Codable {
    let frameIndex: Int
    let presentationSeconds: Double
    let sourceGapSeconds: Double?
    let estimatedMissingSourceFrames: Int
    let normalizationMilliseconds: Double
    let personMilliseconds: Double
    let foregroundMilliseconds: Double
    let renderingMilliseconds: Double
    let totalMilliseconds: Double
    let person: MaskFrameMeasurement
    let foreground: MaskFrameMeasurement
    let foregroundInstanceCount: Int
    let foregroundInstanceCoverage: [String: Double]
    let residentMemoryBytes: UInt64
    let thermalState: String
}

struct NumericDistribution: Codable {
    let count: Int
    let minimum: Double
    let mean: Double
    let median: Double
    let percentile95: Double
    let maximum: Double
}

struct RegionSummary: Codable {
    let kind: String
    let binaryCoverage: NumericDistribution
    let meanMaskValue: NumericDistribution
    let exactZeroCoverageFrames: Int
}

struct CandidateSummary: Codable {
    let processingMilliseconds: NumericDistribution
    let binaryCoverage: NumericDistribution
    let temporalXOR: NumericDistribution?
    let temporalIntersectionOverUnion: NumericDistribution?
    let boundaryFraction: NumericDistribution
    let regions: [String: RegionSummary]
}

struct ClipSummary: Codable {
    let clipID: String
    let cameraClass: String
    let cameraName: String
    let lighting: String
    let sourceWidth: Int
    let sourceHeight: Int
    let nominalFramesPerSecond: Double
    let sourceDurationSeconds: Double
    let framesProcessed: Int
    let estimatedMissingSourceFrames: Int
    let wallClockSeconds: Double
    let effectiveProcessingFramesPerSecond: Double
    let peakResidentMemoryBytes: UInt64
    let person: CandidateSummary
    let foreground: CandidateSummary
    let totalFrameMilliseconds: NumericDistribution
    let limitations: [String]
}

struct ArtifactRecord: Codable {
    let path: String
    let sha256: String
    let bytes: Int64
}

struct ProcessedClipRecord: Codable {
    let clipID: String
    let source: ArtifactRecord
    let synchronizedComparison: ArtifactRecord
    let rawMeasurements: ArtifactRecord
    let measurementSummary: ArtifactRecord
    let visualReviewWorksheet: ArtifactRecord
    let summary: ClipSummary
}

struct RunManifest: Codable {
    let version: Int
    let generatedAt: String
    let experimentID: String
    let prototypeBranch: String
    let prototypeCommit: String
    let host: HostSnapshot
    let candidates: [VisionCandidateInventory]
    let clips: [ProcessedClipRecord]
    let coverageGaps: [String]
    let pressureEvidence: String
    let costBoundary: String
    let verdictBoundary: String
}
