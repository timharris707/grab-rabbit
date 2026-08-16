import AVFoundation
import CoreImage
import Dispatch
import Metal
import ScreenCaptureKit
import Vision

func probeCamera(
    device: AVCaptureDevice,
    output: AVCaptureVideoDataOutput,
    delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
    serialQueue: DispatchQueue
) {
    _ = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.continuityCamera, .external],
        mediaType: .video,
        position: .unspecified
    )
    _ = device.isContinuityCamera
    output.setSampleBufferDelegate(delegate, queue: serialQueue)
}

func probeVision() {
    _ = VNGeneratePersonSegmentationRequest()
    _ = VNGenerateForegroundInstanceMaskRequest()
    _ = VNGeneratePersonInstanceMaskRequest()
    _ = VNInstanceMaskObservation.self
    _ = VNTrackObjectRequest.self
    _ = VNGenerateOpticalFlowRequest.self
    _ = VNTrackOpticalFlowRequest.self
    _ = VNSequenceRequestHandler()
}

func probeScreenCapture(configuration: SCStreamConfiguration) {
    _ = SCStreamOutputType.microphone
    configuration.captureMicrophone = true
    configuration.microphoneCaptureDeviceID = "probe-device-id"
    _ = SCStreamFrameInfo.presenterOverlayContentRect
    configuration.presenterOverlayPrivacyAlertSetting = .system
}

func probeVideoEffects(device: AVCaptureDevice) {
    _ = AVCaptureDevice.isBackgroundReplacementEnabled
    _ = device.isBackgroundReplacementActive
    _ = AVCaptureDevice.isCenterStageEnabled
    _ = device.isCenterStageActive
    _ = AVCaptureDevice.isStudioLightEnabled
    _ = device.isStudioLightActive
    _ = AVCaptureDevice.isPortraitEffectEnabled
    _ = device.isPortraitEffectActive
    AVCaptureDevice.showSystemUserInterface(.videoEffects)
}

func probeWriter(
    input: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    pixelBuffer: CVPixelBuffer,
    presentationTime: CMTime
) {
    input.expectsMediaDataInRealTime = true
    _ = input.isReadyForMoreMediaData
    _ = adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
}

func probeComposition(pixelBuffer: CVPixelBuffer, metalDevice: MTLDevice) {
    _ = CIImage(cvPixelBuffer: pixelBuffer)
    _ = CIContext(mtlDevice: metalDevice)
    _ = MTLCreateSystemDefaultDevice()
}
