import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct WindowCaptureMatte {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

enum WindowCapturePrivacyError: Error {
    case unsupportedPixelFormat(OSType)
    case unavailableBaseAddress
    case pixelBufferAllocationFailed(CVReturn)
    case pixelBufferLockFailed(CVReturn)
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
}

enum WindowCapturePrivacy {
    static let opaqueMatte = WindowCaptureMatte(red: 0, green: 0, blue: 0)
    static let exteriorSentinel: UInt32 = 0x00ff4f00

    // This is the production WindowCapturePrivacy algorithm: sanitize only the
    // exterior scan band and matte every non-opaque pixel before it is retainable.
    static func sanitize(
        _ pixelBuffer: CVPixelBuffer,
        matte: WindowCaptureMatte = opaqueMatte
    ) throws {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA else {
            throw WindowCapturePrivacyError.unsupportedPixelFormat(pixelFormat)
        }
        let lock = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lock == kCVReturnSuccess else {
            throw WindowCapturePrivacyError.pixelBufferLockFailed(lock)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let scanDepth = min(64, max(1, min(width, height) / 2))
        for y in 0..<height {
            guard y < scanDepth || y >= height - scanDepth else { continue }
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where x < scanDepth || x >= width - scanDepth {
                sanitizePixel(row.advanced(by: x * 4), matte: matte)
            }
        }
    }

    private static func sanitizePixel(
        _ pixel: UnsafeMutablePointer<UInt8>,
        matte: WindowCaptureMatte
    ) {
        let alpha = pixel[3]
        guard alpha < 255 else { return }
        if alpha == 0 {
            pixel[0] = matte.blue
            pixel[1] = matte.green
            pixel[2] = matte.red
        } else {
            let inverseAlpha = 255 - Int(alpha)
            pixel[0] = composite(pixel[0], over: matte.blue, inverseAlpha: inverseAlpha)
            pixel[1] = composite(pixel[1], over: matte.green, inverseAlpha: inverseAlpha)
            pixel[2] = composite(pixel[2], over: matte.red, inverseAlpha: inverseAlpha)
        }
        pixel[3] = 255
    }

    private static func composite(_ source: UInt8, over matte: UInt8, inverseAlpha: Int) -> UInt8 {
        UInt8(min(255, Int(source) + (Int(matte) * inverseAlpha + 127) / 255))
    }
}

final class PixelBufferCopier {
    func copy(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard pixelFormat == kCVPixelFormatType_32BGRA else {
            throw WindowCapturePrivacyError.unsupportedPixelFormat(pixelFormat)
        }
        var destination: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else {
            throw WindowCapturePrivacyError.pixelBufferAllocationFailed(status)
        }
        let sourceLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLock == kCVReturnSuccess else {
            throw WindowCapturePrivacyError.pixelBufferLockFailed(sourceLock)
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let destinationLock = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLock == kCVReturnSuccess else {
            throw WindowCapturePrivacyError.pixelBufferLockFailed(destinationLock)
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let copiedBytesPerRow = width * 4
        for row in 0..<height {
            destinationBase.advanced(by: row * destinationBytesPerRow).copyMemory(
                from: sourceBase.advanced(by: row * sourceBytesPerRow),
                byteCount: copiedBytesPerRow
            )
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }
}

struct SanitizedWindowFrame {
    let pixelBuffer: CVPixelBuffer
    let sourcePTS: CMTime
    let arrivalUptimeNanoseconds: UInt64
    let sequence: Int

    fileprivate init(
        pixelBuffer: CVPixelBuffer,
        sourcePTS: CMTime,
        arrivalUptimeNanoseconds: UInt64,
        sequence: Int
    ) {
        self.pixelBuffer = pixelBuffer
        self.sourcePTS = sourcePTS
        self.arrivalUptimeNanoseconds = arrivalUptimeNanoseconds
        self.sequence = sequence
    }
}

enum SanitizedWindowFrameFactory {
    static func make(
        from rawSample: CMSampleBuffer,
        copier: PixelBufferCopier,
        sequence: Int
    ) throws -> SanitizedWindowFrame {
        guard let rawBuffer = rawSample.imageBuffer else {
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }
        let copiedBuffer = try copier.copy(rawBuffer)
        try WindowCapturePrivacy.sanitize(copiedBuffer)
        return SanitizedWindowFrame(
            pixelBuffer: copiedBuffer,
            sourcePTS: rawSample.presentationTimeStamp,
            arrivalUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            sequence: sequence
        )
    }

    static func sentinelProbe() throws -> Int {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw WindowCapturePrivacyError.pixelBufferAllocationFailed(status)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw WindowCapturePrivacyError.unavailableBaseAddress
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<16 {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<16 { row[x] = WindowCapturePrivacy.exteriorSentinel }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        try WindowCapturePrivacy.sanitize(buffer)
        return countSentinelPixels(buffer)
    }

    static func countSentinelPixels(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var count = 0
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width where row[x] == WindowCapturePrivacy.exteriorSentinel { count += 1 }
        }
        return count
    }

    static func countNonOpaqueExteriorPixels(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let scanDepth = min(64, max(1, min(width, height) / 2))
        var count = 0
        for y in 0..<height where y < scanDepth || y >= height - scanDepth {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where x < scanDepth || x >= width - scanDepth {
                if row[x * 4 + 3] < 255 { count += 1 }
            }
        }
        return count
    }
}

struct LiveCameraFrame {
    let pixelBuffer: CVPixelBuffer
    let sourcePTS: CMTime
    let arrivalUptimeNanoseconds: UInt64
    let sequence: Int
}

final class LiveFrameCache {
    private let lock = NSLock()
    private var cameraFrame: LiveCameraFrame?
    private var windowFrame: SanitizedWindowFrame?

    func storeCamera(_ frame: LiveCameraFrame) {
        lock.lock()
        cameraFrame = frame
        lock.unlock()
    }

    // Raw ScreenCaptureKit samples have no cache API. The type system forces
    // copy + WindowCapturePrivacy sanitization before retention.
    func storeWindow(_ frame: SanitizedWindowFrame) {
        lock.lock()
        windowFrame = frame
        lock.unlock()
    }

    func snapshot() -> (camera: LiveCameraFrame?, window: SanitizedWindowFrame?) {
        lock.lock()
        defer { lock.unlock() }
        return (cameraFrame, windowFrame)
    }
}
