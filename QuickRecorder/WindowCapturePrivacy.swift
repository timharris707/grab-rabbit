import AVFoundation
import CoreGraphics
import CoreVideo

enum WindowCaptureMode: String, CaseIterable {
    case transparent
    case opaque

    var title: String {
        switch self {
        case .transparent: "Transparent"
        case .opaque: "Compatible"
        }
    }

    var tradeoff: String {
        switch self {
        case .transparent:
            "Transparent corners · ProRes 4444 MOV · larger files"
        case .opaque:
            "Opaque privacy matte · selected H.264/H.265 format · smaller files"
        }
    }
}

struct WindowCaptureMatte: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct WindowCaptureOutputProfile: Equatable {
    let fileExtension: String
    let fileType: AVFileType
    let codec: AVVideoCodecType
    let preservesAlpha: Bool
}

enum WindowCapturePrivacyError: Error {
    case unsupportedPixelFormat(OSType)
    case unavailableBaseAddress
}

enum WindowCapturePrivacy {
    // Opaque window capture uses one fixed sRGB black privacy matte so no desktop
    // color can enter the compatibility encode path.
    static let opaqueMatte = WindowCaptureMatte(red: 0, green: 0, blue: 0)

    static func outputProfile(
        mode: WindowCaptureMode,
        compatibilityFileType: AVFileType,
        compatibilityCodec: AVVideoCodecType
    ) -> WindowCaptureOutputProfile {
        switch mode {
        case .transparent:
            WindowCaptureOutputProfile(
                fileExtension: "mov",
                fileType: .mov,
                codec: .proRes4444,
                preservesAlpha: true
            )
        case .opaque:
            WindowCaptureOutputProfile(
                fileExtension: compatibilityFileType == .mp4 ? "mp4" : "mov",
                fileType: compatibilityFileType,
                codec: compatibilityCodec,
                preservesAlpha: false
            )
        }
    }

    static func pixelDimensions(
        contentRect: CGRect,
        pointPixelScale: CGFloat,
        highResolution: Bool
    ) -> (width: Int, height: Int) {
        let scale = highResolution ? pointPixelScale : 1
        return (
            width: max(1, Int((contentRect.width * scale).rounded())),
            height: max(1, Int((contentRect.height * scale).rounded()))
        )
    }

    static func backgroundColor(
        mode: WindowCaptureMode,
        matte: WindowCaptureMatte
    ) -> CGColor {
        switch mode {
        case .transparent:
            CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        case .opaque:
            CGColor(
                red: CGFloat(matte.red) / 255,
                green: CGFloat(matte.green) / 255,
                blue: CGFloat(matte.blue) / 255,
                alpha: 1
            )
        }
    }

    static func videoSettings(
        profile: WindowCaptureOutputProfile,
        width: Int,
        height: Int,
        compressionProperties: [String: Any]
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: profile.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if profile.codec != .proRes4444 {
            settings[AVVideoCompressionPropertiesKey] = compressionProperties
        }
        return settings
    }

    static func sanitize(
        _ pixelBuffer: CVPixelBuffer,
        mode: WindowCaptureMode,
        matte: WindowCaptureMatte
    ) throws {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA else {
            throw WindowCapturePrivacyError.unsupportedPixelFormat(pixelFormat)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
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
                sanitizePixel(row.advanced(by: x * 4), mode: mode, matte: matte)
            }
        }
    }

    private static func sanitizePixel(
        _ pixel: UnsafeMutablePointer<UInt8>,
        mode: WindowCaptureMode,
        matte: WindowCaptureMatte
    ) {
        let alpha = pixel[3]
        guard alpha < 255 else { return }

        switch mode {
        case .transparent:
            if alpha == 0 {
                pixel[0] = 0
                pixel[1] = 0
                pixel[2] = 0
            }
        case .opaque:
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
    }

    private static func composite(_ source: UInt8, over matte: UInt8, inverseAlpha: Int) -> UInt8 {
        UInt8(min(255, Int(source) + (Int(matte) * inverseAlpha + 127) / 255))
    }
}
