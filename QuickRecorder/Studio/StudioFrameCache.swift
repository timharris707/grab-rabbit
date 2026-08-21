import CoreMedia
import CoreVideo
import Foundation

enum StudioIngressError: Error, Equatable {
    case missingImageBuffer
    case privacyBoundaryFailed(markerPixels: Int, nonOpaqueExteriorPixels: Int)
}

struct StudioCameraFrame {
    let pixelBuffer: CVPixelBuffer
    let sample: CMSampleBuffer
    let arrivalNanoseconds: UInt64
    let sequence: Int
}

// A window frame can only be constructed by StudioWindowIngress, so the type system
// guarantees that anything the cache holds was copied out of the ScreenCaptureKit
// buffer, sanitized by the production WindowCapturePrivacy pass, and cleared by the
// fail-closed sentinel scan.
struct StudioSanitizedWindowFrame {
    let pixelBuffer: CVPixelBuffer
    let sample: CMSampleBuffer
    let arrivalNanoseconds: UInt64
    let sequence: Int

    fileprivate init(
        pixelBuffer: CVPixelBuffer,
        sample: CMSampleBuffer,
        arrivalNanoseconds: UInt64,
        sequence: Int
    ) {
        self.pixelBuffer = pixelBuffer
        self.sample = sample
        self.arrivalNanoseconds = arrivalNanoseconds
        self.sequence = sequence
    }
}

struct StudioFrameSnapshot {
    let camera: StudioCameraFrame?
    let window: StudioSanitizedWindowFrame?
}

// Latest-frame semantics, never a queue: a new frame replaces the held one outright,
// so the render loop always composites the freshest arrival and a slow render can
// never build a backlog of stale frames.
final class StudioFrameCache {
    private let lock = NSLock()
    private var cameraFrame: StudioCameraFrame?
    private var windowFrame: StudioSanitizedWindowFrame?

    func storeCamera(_ frame: StudioCameraFrame) {
        lock.withLock { cameraFrame = frame }
    }

    func storeWindow(_ frame: StudioSanitizedWindowFrame) {
        lock.withLock { windowFrame = frame }
    }

    func snapshot() -> StudioFrameSnapshot {
        lock.withLock { StudioFrameSnapshot(camera: cameraFrame, window: windowFrame) }
    }
}

// The ingress boundary. Both entry points copy the incoming sample before anything
// retains it; the window path additionally sanitizes and then scans fail-closed.
final class StudioFrameIngress {
    private let cameraCopier = WindowCaptureSampleCopier()
    private let windowCopier = WindowCaptureSampleCopier()
    private let matte: WindowCaptureMatte
    private var cameraSequence = 0
    private var windowSequence = 0

    init(matte: WindowCaptureMatte = WindowCapturePrivacy.opaqueMatte) {
        self.matte = matte
    }

    func makeCameraFrame(
        from sample: CMSampleBuffer,
        arrivalNanoseconds: UInt64
    ) throws -> StudioCameraFrame {
        let copied = try cameraCopier.copy(sample)
        guard let pixelBuffer = copied.imageBuffer else {
            throw StudioIngressError.missingImageBuffer
        }
        defer { cameraSequence += 1 }
        return StudioCameraFrame(
            pixelBuffer: pixelBuffer,
            sample: copied,
            arrivalNanoseconds: arrivalNanoseconds,
            sequence: cameraSequence
        )
    }

    // The studio canvas is opaque, so the window sanitizer always runs in the opaque
    // mode that mattes every non-opaque exterior pixel and forces alpha to full.
    func makeWindowFrame(
        from sample: CMSampleBuffer,
        arrivalNanoseconds: UInt64
    ) throws -> StudioSanitizedWindowFrame {
        let copied = try windowCopier.copy(sample)
        guard let pixelBuffer = copied.imageBuffer else {
            throw StudioIngressError.missingImageBuffer
        }
        try WindowCapturePrivacy.sanitize(pixelBuffer, mode: .opaque, matte: matte)

        let markerPixels = StudioPrivacySentinel.countMarkerPixels(in: pixelBuffer)
        let nonOpaquePixels = StudioPrivacySentinel.countNonOpaqueExteriorPixels(in: pixelBuffer)
        guard markerPixels == 0, nonOpaquePixels == 0 else {
            throw StudioIngressError.privacyBoundaryFailed(
                markerPixels: markerPixels,
                nonOpaqueExteriorPixels: nonOpaquePixels
            )
        }
        defer { windowSequence += 1 }
        return StudioSanitizedWindowFrame(
            pixelBuffer: pixelBuffer,
            sample: copied,
            arrivalNanoseconds: arrivalNanoseconds,
            sequence: windowSequence
        )
    }
}
