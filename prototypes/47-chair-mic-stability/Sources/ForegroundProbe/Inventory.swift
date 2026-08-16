import AVFoundation
import CoreML
import CoreMedia
import CoreVideo
import Foundation
import Vision

func discoverCameras() -> [AVCaptureDevice] {
    let session = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video,
        position: .unspecified
    )
    var seen = Set<String>()
    return session.devices.filter { seen.insert($0.uniqueID).inserted }
}

func cameraSnapshot(_ device: AVCaptureDevice) -> CameraSnapshot {
    let description = device.activeFormat.formatDescription
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    let frameDuration = device.activeVideoMinFrameDuration
    let fps = frameDuration.isValid && frameDuration.seconds > 0 ? 1 / frameDuration.seconds : 0
    let mediaSubtype = CMFormatDescriptionGetMediaSubType(description)

    let cameraClass: String
    if device.isContinuityCamera {
        cameraClass = "continuity-camera"
    } else if device.deviceType == .builtInWideAngleCamera {
        cameraClass = "built-in"
    } else {
        cameraClass = "external"
    }

    return CameraSnapshot(
        name: device.localizedName,
        uniqueID: device.uniqueID,
        modelID: device.modelID,
        manufacturer: device.manufacturer,
        deviceType: device.deviceType.rawValue,
        cameraClass: cameraClass,
        isContinuityCamera: device.isContinuityCamera,
        isConnected: device.isConnected,
        isSuspended: device.isSuspended,
        format: FormatSnapshot(
            width: dimensions.width,
            height: dimensions.height,
            nominalFramesPerSecond: fps,
            pixelFormat: fourCCString(mediaSubtype)
        ),
        effects: EffectSnapshot(
            backgroundReplacementEnabled: AVCaptureDevice.isBackgroundReplacementEnabled,
            backgroundReplacementActive: device.isBackgroundReplacementActive,
            centerStageEnabled: AVCaptureDevice.isCenterStageEnabled,
            centerStageActive: device.isCenterStageActive,
            portraitEffectEnabled: AVCaptureDevice.isPortraitEffectEnabled,
            portraitEffectActive: device.isPortraitEffectActive,
            studioLightEnabled: AVCaptureDevice.isStudioLightEnabled,
            studioLightActive: device.isStudioLightActive
        )
    )
}

func candidateInventory() -> [VisionCandidateInventory] {
    let person = GeneratePersonSegmentationRequest()
    person.qualityLevel = .accurate
    person.outputPixelFormatType = kCVPixelFormatType_OneComponent8
    let foreground = GenerateForegroundInstanceMaskRequest()

    func computeDevices<Request: VisionRequest>(_ request: Request) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: request.supportedComputeStageDevices.map { stage, devices in
            (String(describing: stage), devices.map { String(describing: $0) }.sorted())
        })
    }

    return [
        VisionCandidateInventory(
            id: "P0",
            request: "GeneratePersonSegmentationRequest",
            configuration: "quality=accurate; output=OneComponent8; stateful; every source frame",
            supportedComputeStageDevices: computeDevices(person)
        ),
        VisionCandidateInventory(
            id: "P1",
            request: "GenerateForegroundInstanceMaskRequest",
            configuration: "all foreground instances unioned; per-frame instance IDs also rendered; no cross-frame identity assumed",
            supportedComputeStageDevices: computeDevices(foreground)
        ),
    ]
}

func authorizationStatusString() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .notDetermined: return "not-determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
}

func inventoryDocument() -> InventoryDocument {
    InventoryDocument(
        version: 1,
        generatedAt: nowString(),
        host: hostSnapshot(),
        cameraAuthorization: authorizationStatusString(),
        cameras: discoverCameras().map(cameraSnapshot).sorted { $0.name < $1.name },
        candidates: candidateInventory()
    )
}
