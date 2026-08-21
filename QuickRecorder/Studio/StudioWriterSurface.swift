import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum StudioAudioTrack: Equatable, CaseIterable {
    case systemAudio
    case microphone
}

enum StudioWriterError: Error, Equatable {
    case pixelBufferPoolUnavailable
    case pixelBufferAllocationFailed(CVReturn)
}

// The writer surface the render engine appends to. Production backs it with an
// AVAssetWriter pixel-buffer adaptor; tests back it with a recorder.
protocol StudioWriterSurface: AnyObject {
    var isReadyForVideo: Bool { get }
    func makeOutputPixelBuffer() throws -> CVPixelBuffer
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> Bool
    func isReady(for track: StudioAudioTrack) -> Bool
    func appendAudio(_ sample: CMSampleBuffer, to track: StudioAudioTrack) -> Bool
}

final class StudioAssetWriterSurface: StudioWriterSurface {
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?

    init(
        videoInput: AVAssetWriterInput,
        videoAdaptor: AVAssetWriterInputPixelBufferAdaptor,
        systemAudioInput: AVAssetWriterInput?,
        microphoneInput: AVAssetWriterInput?
    ) {
        self.videoInput = videoInput
        self.videoAdaptor = videoAdaptor
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
    }

    var isReadyForVideo: Bool { videoInput.isReadyForMoreMediaData }

    func makeOutputPixelBuffer() throws -> CVPixelBuffer {
        guard let pool = videoAdaptor.pixelBufferPool else {
            throw StudioWriterError.pixelBufferPoolUnavailable
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw StudioWriterError.pixelBufferAllocationFailed(status)
        }
        return buffer
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> Bool {
        videoAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }

    func isReady(for track: StudioAudioTrack) -> Bool {
        input(for: track)?.isReadyForMoreMediaData ?? false
    }

    func appendAudio(_ sample: CMSampleBuffer, to track: StudioAudioTrack) -> Bool {
        input(for: track)?.append(sample) ?? false
    }

    private func input(for track: StudioAudioTrack) -> AVAssetWriterInput? {
        switch track {
        case .systemAudio: systemAudioInput
        case .microphone: microphoneInput
        }
    }
}

// Audio is re-stamped from the same wall clock as video. Every sample in the buffer
// is shifted by the same delta, so intra-buffer sample offsets survive the move and
// the buffer's internal ordering is untouched.
enum StudioAudioRetimer {
    static func retime(_ sample: CMSampleBuffer, toSeconds seconds: Double) -> CMSampleBuffer? {
        guard CMSampleBufferGetNumSamples(sample) > 0 else { return nil }

        // A buffer may carry one timing entry for every sample or a single entry for
        // the whole run, so the entry count is asked for rather than assumed.
        var entriesNeeded = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entriesNeeded
        ) == noErr, entriesNeeded > 0 else { return nil }

        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: entriesNeeded)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: entriesNeeded,
            arrayToFill: &timing,
            entriesNeededOut: nil
        ) == noErr else { return nil }

        let firstPresentationTime = timing[0].presentationTimeStamp
        let target = StudioTimeline.presentationTime(seconds: seconds)
        for index in timing.indices {
            timing[index].presentationTimeStamp =
                target + (timing[index].presentationTimeStamp - firstPresentationTime)
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp =
                    target + (timing[index].decodeTimeStamp - firstPresentationTime)
            }
        }

        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjusted
        ) == noErr else { return nil }
        return adjusted
    }
}
