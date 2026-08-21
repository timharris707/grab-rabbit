import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal

struct StudioCanvas: Equatable {
    let width: Int
    let height: Int

    var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    // The camera inset used when a window is also on the canvas. Later slices own
    // the layout envelope; this is the prototype's proven placement.
    var cameraInsetRect: CGRect {
        CGRect(
            x: CGFloat(width) * 0.70,
            y: CGFloat(height) * 0.05,
            width: CGFloat(width) * 0.25,
            height: CGFloat(height) * 0.25
        )
    }
}

enum StudioCompositorError: Error {
    case metalDeviceUnavailable
}

protocol StudioCompositing: AnyObject {
    func compose(camera: CVPixelBuffer, window: CVPixelBuffer?, into output: CVPixelBuffer)
}

// Core Image over a Metal context, as measured in the issue #48 cadence prototype.
final class StudioCoreImageCompositor: StudioCompositing {
    private let canvas: StudioCanvas
    private let context: CIContext
    private let colorSpace: CGColorSpace

    init(canvas: StudioCanvas) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw StudioCompositorError.metalDeviceUnavailable
        }
        self.canvas = canvas
        context = CIContext(mtlDevice: device)
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    // The canvas starts opaque black so no desktop color can show through, then the
    // window fills it and the camera lands in the inset. With no window the camera
    // fills the whole canvas.
    func compose(camera: CVPixelBuffer, window: CVPixelBuffer?, into output: CVPixelBuffer) {
        let bounds = canvas.rect
        var image = CIImage(color: CIColor.black).cropped(to: bounds)
        if let window {
            image = Self.aspectFit(CIImage(cvPixelBuffer: window), in: bounds).composited(over: image)
            image = Self.aspectFit(CIImage(cvPixelBuffer: camera), in: canvas.cameraInsetRect)
                .composited(over: image)
        } else {
            image = Self.aspectFit(CIImage(cvPixelBuffer: camera), in: bounds).composited(over: image)
        }
        context.render(image, to: output, bounds: bounds, colorSpace: colorSpace)
    }

    static func aspectFit(_ image: CIImage, in target: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image.cropped(to: target) }
        let scale = min(target.width / extent.width, target.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled
            .transformed(by: CGAffineTransform(
                translationX: target.midX - scaled.extent.midX,
                y: target.midY - scaled.extent.midY
            ))
            .cropped(to: target)
    }
}
