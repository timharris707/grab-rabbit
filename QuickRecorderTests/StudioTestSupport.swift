import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// Shared doubles and buffer factories for the studio render engine tests. Every
// seam the engine depends on is replaced here so no test touches the wall clock,
// a capture device, or a real asset writer.

final class StudioTestClock: StudioClock {
    private let lock = NSLock()
    private var value: UInt64

    init(nowNanoseconds: UInt64 = 1_000_000_000) {
        value = nowNanoseconds
    }

    var nowNanoseconds: UInt64 {
        lock.withLock { value }
    }

    func advance(seconds: Double) {
        advance(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
    }

    func advance(nanoseconds: UInt64) {
        lock.withLock { value += nanoseconds }
    }

    func rewind(seconds: Double) {
        let delta = UInt64((seconds * 1_000_000_000).rounded())
        lock.withLock { value = value > delta ? value - delta : 0 }
    }
}

final class StudioManualTriggerSource: StudioRenderTriggerSource {
    private(set) var interval: TimeInterval?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (() -> Void)?

    func start(interval: TimeInterval, handler: @escaping () -> Void) {
        self.interval = interval
        self.handler = handler
        startCount += 1
    }

    func stop() {
        handler = nil
        stopCount += 1
    }

    var isRunning: Bool { handler != nil }

    func fire() {
        handler?()
    }
}

final class StudioStubCompositor: StudioCompositing {
    // When set, the compositor stamps the privacy marker into the output so the
    // post-composite fail-closed scan has something to catch.
    var writesPrivacyMarker = false
    private(set) var composeCount = 0
    private(set) var lastWindowWasPresent = false

    func compose(camera: CVPixelBuffer, window: CVPixelBuffer?, into output: CVPixelBuffer) {
        composeCount += 1
        lastWindowWasPresent = window != nil
        StudioTestBuffers.fill(output, withPixel: 0xff_20_20_20)
        if writesPrivacyMarker {
            StudioTestBuffers.setPixel(
                output,
                x: 0,
                y: 0,
                value: StudioPrivacySentinel.opaqueMarker
            )
        }
    }
}

final class StudioRecordingWriterSurface: StudioWriterSurface {
    let canvas: StudioCanvas
    var isReadyForVideo = true
    var readyTracks: Set<StudioAudioTrack> = Set(StudioAudioTrack.allCases)
    var videoAppendSucceeds = true
    var poolIsUnavailable = false
    private(set) var appendedVideoTimes = [CMTime]()
    private(set) var appendedVideoBuffers = [CVPixelBuffer]()
    private(set) var appendedAudio = [(track: StudioAudioTrack, sample: CMSampleBuffer)]()

    init(canvas: StudioCanvas) {
        self.canvas = canvas
    }

    func makeOutputPixelBuffer() throws -> CVPixelBuffer {
        if poolIsUnavailable { throw StudioWriterError.pixelBufferPoolUnavailable }
        return try StudioTestBuffers.makePixelBuffer(width: canvas.width, height: canvas.height)
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> Bool {
        guard videoAppendSucceeds else { return false }
        appendedVideoTimes.append(presentationTime)
        appendedVideoBuffers.append(pixelBuffer)
        return true
    }

    func isReady(for track: StudioAudioTrack) -> Bool {
        readyTracks.contains(track)
    }

    func appendAudio(_ sample: CMSampleBuffer, to track: StudioAudioTrack) -> Bool {
        appendedAudio.append((track, sample))
        return true
    }

    func appendedAudioTimes(for track: StudioAudioTrack) -> [CMTime] {
        appendedAudio.filter { $0.track == track }.map { $0.sample.presentationTimeStamp }
    }
}

enum StudioTestBufferError: Error {
    case allocationFailed(CVReturn)
    case formatDescriptionFailed(OSStatus)
    case sampleCreationFailed(OSStatus)
    case blockBufferFailed(OSStatus)
    case timingUnavailable
}

enum StudioTestBuffers {
    static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw StudioTestBufferError.allocationFailed(status)
        }
        fill(buffer, withPixel: 0xff_00_00_00)
        return buffer
    }

    static func fill(_ buffer: CVPixelBuffer, withPixel value: UInt32) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] = value }
        }
    }

    static func setPixel(_ buffer: CVPixelBuffer, x: Int, y: Int, value: UInt32) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
        row[x] = value
    }

    static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt32 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
        return row[x]
    }

    static func makeVideoSample(
        from pixelBuffer: CVPixelBuffer,
        presentationSeconds: Double = 0
    ) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw StudioTestBufferError.formatDescriptionFailed(formatStatus)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: presentationSeconds, preferredTimescale: 60_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw StudioTestBufferError.sampleCreationFailed(status)
        }
        return sample
    }

    static func makeVideoSample(
        width: Int,
        height: Int,
        pixel: UInt32 = 0xff_00_00_00,
        presentationSeconds: Double = 0
    ) throws -> CMSampleBuffer {
        let buffer = try makePixelBuffer(width: width, height: height)
        fill(buffer, withPixel: pixel)
        return try makeVideoSample(from: buffer, presentationSeconds: presentationSeconds)
    }

    // A 16-bit mono PCM buffer. By default it carries one timing entry per sample so
    // a retime can be checked for preserving the offsets between samples inside the
    // buffer. Pass a timing entry count of 1 for the shape a real capture callback
    // delivers: many samples described by a single entry.
    static func makeAudioSample(
        sampleCount: Int,
        startSeconds: Double,
        sampleRate: Double = 48_000,
        timingEntryCount: Int? = nil
    ) throws -> CMSampleBuffer {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw StudioTestBufferError.formatDescriptionFailed(formatStatus)
        }

        let byteCount = sampleCount * 2
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else {
            throw StudioTestBufferError.blockBufferFailed(blockStatus)
        }
        CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )

        let sampleDuration = CMTime(value: 1, timescale: CMTimeScale(sampleRate))
        let start = CMTime(seconds: startSeconds, preferredTimescale: CMTimeScale(sampleRate))
        let entryCount = timingEntryCount ?? sampleCount
        var timing = (0..<entryCount).map { index in
            CMSampleTimingInfo(
                duration: sampleDuration,
                presentationTimeStamp: start + CMTimeMultiply(sampleDuration, multiplier: Int32(index)),
                decodeTimeStamp: .invalid
            )
        }
        var sampleSizes = [Int](repeating: 2, count: 1)

        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: entryCount,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw StudioTestBufferError.sampleCreationFailed(status)
        }
        return sample
    }

    static func timingEntries(of sample: CMSampleBuffer) throws -> [CMSampleTimingInfo] {
        var entriesNeeded = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entriesNeeded
        ) == noErr, entriesNeeded > 0 else {
            throw StudioTestBufferError.timingUnavailable
        }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: entriesNeeded)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: entriesNeeded,
            arrayToFill: &timing,
            entriesNeededOut: nil
        ) == noErr else {
            throw StudioTestBufferError.timingUnavailable
        }
        return timing
    }
}
