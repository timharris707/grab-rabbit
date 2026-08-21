import CoreVideo
import Foundation

// The fail-closed privacy tripwire the cadence prototype proved out. The marker is
// the desktop-exterior probe color; if a pixel of it survives to the frame cache or
// to a composited output frame, the sanitizer did not run and the engine stops
// rather than write desktop pixels into a recording.
enum StudioPrivacySentinel {
    static let markerRed: UInt8 = 0xff
    static let markerGreen: UInt8 = 0x4f
    static let markerBlue: UInt8 = 0x00

    // A 32BGRA pixel read as a little-endian UInt32 is alpha, red, green, blue.
    // The transparent form is what a raw exterior pixel looks like at capture; the
    // opaque form is what it becomes once a compositor forces alpha to full, so
    // both forms have to be scanned for the tripwire to hold end to end.
    static let transparentMarker: UInt32 = marker(alpha: 0x00)
    static let opaqueMarker: UInt32 = marker(alpha: 0xff)

    private static func marker(alpha: UInt8) -> UInt32 {
        (UInt32(alpha) << 24)
            | (UInt32(markerRed) << 16)
            | (UInt32(markerGreen) << 8)
            | UInt32(markerBlue)
    }

    // The exterior scan band matches WindowCapturePrivacy.sanitize so the two agree
    // on which pixels the sanitizer is responsible for.
    static func scanDepth(width: Int, height: Int) -> Int {
        min(64, max(1, min(width, height) / 2))
    }

    // Returns a negative count when the buffer cannot be inspected, which callers
    // treat as a failure exactly like a positive count.
    static func countMarkerPixels(in pixelBuffer: CVPixelBuffer) -> Int {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return -1
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return -1
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return -1 }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var count = 0
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width where row[x] == transparentMarker || row[x] == opaqueMarker {
                count += 1
            }
        }
        return count
    }

    static func countNonOpaqueExteriorPixels(in pixelBuffer: CVPixelBuffer) -> Int {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return -1
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return -1
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return -1 }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let depth = scanDepth(width: width, height: height)
        var count = 0
        for y in 0..<height where y < depth || y >= height - depth {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where x < depth || x >= width - depth {
                if row[x * 4 + 3] < 255 { count += 1 }
            }
        }
        return count
    }
}
