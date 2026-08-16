import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Vision

private struct VideoGeometry {
    let encodedWidth: Int
    let encodedHeight: Int
    let uprightWidth: Int
    let uprightHeight: Int
    let preferredTransform: CGAffineTransform
    let transformedBounds: CGRect
}

private struct MaskBytes {
    let width: Int
    let height: Int
    let values: [UInt8]
}

private final class CandidateAccumulator {
    let candidateID: String
    var processingMilliseconds: [Double] = []
    var binaryCoverage: [Double] = []
    var meanMaskValue: [Double] = []
    var temporalXOR: [Double] = []
    var temporalIntersectionOverUnion: [Double] = []
    var boundaryFraction: [Double] = []
    var regionKinds: [String: String] = [:]
    var regionBinaryCoverage: [String: [Double]] = [:]
    var regionMeanMaskValue: [String: [Double]] = [:]

    init(candidateID: String) {
        self.candidateID = candidateID
    }

    func append(milliseconds: Double, measurement: MaskFrameMeasurement) {
        processingMilliseconds.append(milliseconds)
        binaryCoverage.append(measurement.binaryCoverageFraction)
        meanMaskValue.append(measurement.meanMaskValue)
        if let value = measurement.temporalXORFraction { temporalXOR.append(value) }
        if let value = measurement.temporalIntersectionOverUnion { temporalIntersectionOverUnion.append(value) }
        boundaryFraction.append(measurement.boundaryFraction)
        for (label, region) in measurement.regions {
            regionKinds[label] = region.kind
            regionBinaryCoverage[label, default: []].append(region.binaryCoverageFraction)
            regionMeanMaskValue[label, default: []].append(region.meanMaskValue)
        }
    }

    func summary() -> CandidateSummary {
        let regions = Dictionary(uniqueKeysWithValues: regionKinds.keys.sorted().map { label in
            let coverage = regionBinaryCoverage[label, default: []]
            return (
                label,
                RegionSummary(
                    kind: regionKinds[label] ?? "unknown",
                    binaryCoverage: distribution(coverage),
                    meanMaskValue: distribution(regionMeanMaskValue[label, default: []]),
                    exactZeroCoverageFrames: coverage.filter { $0 == 0 }.count
                )
            )
        })
        return CandidateSummary(
            processingMilliseconds: distribution(processingMilliseconds),
            binaryCoverage: distribution(binaryCoverage),
            temporalXOR: temporalXOR.isEmpty ? nil : distribution(temporalXOR),
            temporalIntersectionOverUnion: temporalIntersectionOverUnion.isEmpty ? nil : distribution(temporalIntersectionOverUnion),
            boundaryFraction: distribution(boundaryFraction),
            regions: regions
        )
    }
}

private final class ComparisonWriter {
    static let panelWidth = 960
    static let panelHeight = 540

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(outputURL: URL, framesPerSecond: Double, context: CIContext) throws {
        self.context = context
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let bitrate = 18_000_000
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Self.panelWidth * 3,
                AVVideoHeightKey: Self.panelHeight * 2,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: max(1, Int(framesPerSecond.rounded())),
                    AVVideoMaxKeyFrameIntervalKey: max(1, Int((framesPerSecond * 2).rounded())),
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.panelWidth * 3,
                kCVPixelBufferHeightKey as String: Self.panelHeight * 2,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(input) else {
            throw ProbeError.processingFailed("Cannot add the synchronized comparison video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ProbeError.processingFailed("Cannot start the synchronized comparison writer")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(
        source: CIImage,
        personMask: CIImage,
        personComposite: CIImage,
        foregroundInstances: CIImage,
        foregroundMask: CIImage,
        foregroundComposite: CIImage,
        presentationTime: CMTime
    ) throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw writer.error ?? ProbeError.processingFailed("The synchronized comparison writer failed")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw ProbeError.processingFailed("The synchronized comparison pixel-buffer pool is unavailable")
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
              let output else {
            throw ProbeError.processingFailed("Cannot allocate a synchronized comparison frame")
        }

        let width = Self.panelWidth
        let height = Self.panelHeight
        let canvasBounds = CGRect(x: 0, y: 0, width: width * 3, height: height * 2)
        var canvas = CIImage(color: .black).cropped(to: canvasBounds)
        let panels: [(CIImage, CGRect, CIColor)] = [
            (source, CGRect(x: 0, y: height, width: width, height: height), .gray),
            (personMask, CGRect(x: width, y: height, width: width, height: height), .green),
            (personComposite, CGRect(x: width * 2, y: height, width: width, height: height), .green),
            (foregroundInstances, CGRect(x: 0, y: 0, width: width, height: height), .blue),
            (foregroundMask, CGRect(x: width, y: 0, width: width, height: height), .blue),
            (foregroundComposite, CGRect(x: width * 2, y: 0, width: width, height: height), .blue),
        ]
        for (image, rectangle, markerColor) in panels {
            canvas = fit(image, into: rectangle).composited(over: canvas)
            let marker = CIImage(color: markerColor).cropped(
                to: CGRect(x: rectangle.minX, y: rectangle.minY, width: rectangle.width, height: 6)
            )
            canvas = marker.composited(over: canvas)
        }
        context.render(canvas, to: output, bounds: canvasBounds, colorSpace: colorSpace)
        guard adaptor.append(output, withPresentationTime: presentationTime) else {
            throw writer.error ?? ProbeError.processingFailed("Cannot append a synchronized comparison frame")
        }
    }

    func finish() async throws {
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? ProbeError.processingFailed("The synchronized comparison writer did not finish")
        }
    }

    private func fit(_ image: CIImage, into rectangle: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            return CIImage(color: .black).cropped(to: rectangle)
        }
        let scale = min(rectangle.width / extent.width, rectangle.height / extent.height)
        let zeroBased = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        let scaled = zeroBased.transformed(by: .init(scaleX: scale, y: scale))
        let translated = scaled.transformed(by: .init(
            translationX: rectangle.midX - scaled.extent.midX,
            y: rectangle.midY - scaled.extent.midY
        ))
        return translated.cropped(to: rectangle)
    }
}

func processExperiment(manifestURL: URL, outputDirectory: URL) async throws -> RunManifest {
    let decoder = JSONDecoder()
    let manifest = try decoder.decode(ExperimentManifest.self, from: Data(contentsOf: manifestURL))
    try validate(manifest)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let runManifestURL = outputDirectory.appendingPathComponent("run-manifest.json")
    guard !FileManager.default.fileExists(atPath: runManifestURL.path) else {
        throw ProbeError.processingFailed("Refusing to overwrite an existing run manifest at \(runManifestURL.path)")
    }

    guard let metalDevice = MTLCreateSystemDefaultDevice() else {
        throw ProbeError.processingFailed("No Metal device is available for native mask composition")
    }
    let context = CIContext(mtlDevice: metalDevice)
    let baseDirectory = manifestURL.deletingLastPathComponent()
    var processed: [ProcessedClipRecord] = []
    for clip in manifest.clips {
        processed.append(try await processClip(
            clip,
            baseDirectory: baseDirectory,
            outputDirectory: outputDirectory,
            context: context
        ))
    }

    var gaps: [String] = []
    let cameraClasses = Set(manifest.clips.map(\.cameraClass))
    if !cameraClasses.contains("continuity-camera") {
        gaps.append("No Continuity Camera/iPhone clip is present.")
    }
    if cameraClasses.subtracting(["continuity-camera"]).isEmpty {
        gaps.append("No second camera class is present alongside Continuity Camera.")
    }
    if Set(manifest.clips.map(\.lighting)).count < 2 {
        gaps.append("Fewer than two lighting conditions are present.")
    }
    gaps.append("The tool cannot prove that a person, hair/clothing, glasses, the actual chair back, or the actual Shure microphone was physically present; the visual review must confirm each dimension.")

    let environment = ProcessInfo.processInfo.environment
    let pressureURL = outputDirectory.appendingPathComponent("powermetrics.txt")
    let pressureEvidence = FileManager.default.fileExists(atPath: pressureURL.path)
        ? pressureURL.path
        : "MISSING: rerun through scripts/run-with-pressure.sh to capture host CPU/GPU/ANE pressure"
    let runManifest = RunManifest(
        version: 1,
        generatedAt: nowString(),
        experimentID: manifest.experimentID,
        prototypeBranch: environment["GRAB_RABBIT_PROTOTYPE_BRANCH"] ?? "unrecorded",
        prototypeCommit: environment["GRAB_RABBIT_PROTOTYPE_COMMIT"] ?? "unrecorded",
        host: hostSnapshot(),
        candidates: candidateInventory(),
        clips: processed,
        coverageGaps: gaps,
        pressureEvidence: pressureEvidence,
        costBoundary: "One offline pass per source clip runs only native P0 and P1. No paid API, cloud model, credential change, model download, or repeated model-call loop is used.",
        verdictBoundary: "Raw measurements and full synchronized videos do not define a pass threshold. Tim records person-only, automatic quality-gated inclusion, or a justified user-assisted path on issue #47 after visual review."
    )
    try writeJSON(runManifest, to: runManifestURL)
    return runManifest
}

private func validate(_ manifest: ExperimentManifest) throws {
    guard manifest.version == 1 else {
        throw ProbeError.invalidManifest("Unsupported experiment manifest version \(manifest.version)")
    }
    guard !manifest.experimentID.isEmpty else {
        throw ProbeError.invalidManifest("experimentID is required")
    }
    guard !manifest.clips.isEmpty else {
        throw ProbeError.invalidManifest("At least one source clip is required")
    }
    var ids = Set<String>()
    for clip in manifest.clips {
        guard ids.insert(clip.id).inserted else {
            throw ProbeError.invalidManifest("Duplicate clip id \(clip.id)")
        }
        guard !clip.source.isEmpty, !clip.cameraClass.isEmpty, !clip.cameraName.isEmpty, !clip.lighting.isEmpty else {
            throw ProbeError.invalidManifest("Clip \(clip.id) is missing source, camera, or lighting identity")
        }
        let kinds = Set(clip.regions.map(\.kind))
        let required = Set(RegionSpecification.Kind.allCases)
        guard kinds.isSuperset(of: required) else {
            let missing = required.subtracting(kinds).map(\.rawValue).sorted().joined(separator: ", ")
            throw ProbeError.invalidManifest("Clip \(clip.id) is missing required measurement regions: \(missing)")
        }
        for region in clip.regions {
            guard region.startSeconds >= 0, region.endSeconds > region.startSeconds,
                  region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
                  region.x + region.width <= 1, region.y + region.height <= 1 else {
                throw ProbeError.invalidManifest("Clip \(clip.id) has invalid normalized region \(region.label)")
            }
        }
    }
}

private func processClip(
    _ clip: ClipSpecification,
    baseDirectory: URL,
    outputDirectory: URL,
    context: CIContext
) async throws -> ProcessedClipRecord {
    let sourceURL = resolvePath(clip.source, relativeTo: baseDirectory)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        throw ProbeError.invalidManifest("Source clip does not exist: \(sourceURL.path)")
    }
    let phases = try validateCaptureMetadataIfPresent(clip, sourceURL: sourceURL, baseDirectory: baseDirectory)
    let comparisonURL = outputDirectory.appendingPathComponent("\(clip.id)-synchronized-comparison.mov")
    let measurementsURL = outputDirectory.appendingPathComponent("\(clip.id)-measurements.jsonl")
    let summaryURL = outputDirectory.appendingPathComponent("\(clip.id)-measurement-summary.json")
    let reviewURL = outputDirectory.appendingPathComponent("\(clip.id)-visual-review.csv")
    for url in [comparisonURL, measurementsURL, summaryURL, reviewURL] where FileManager.default.fileExists(atPath: url.path) {
        throw ProbeError.processingFailed("Refusing to overwrite existing evidence at \(url.path)")
    }

    let asset = AVURLAsset(url: sourceURL)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw ProbeError.processingFailed("Clip \(clip.id) has no video track")
    }
    let naturalSize = try await track.load(.naturalSize)
    let preferredTransform = try await track.load(.preferredTransform)
    let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized
    let geometry = VideoGeometry(
        encodedWidth: Int(naturalSize.width.rounded()),
        encodedHeight: Int(naturalSize.height.rounded()),
        uprightWidth: Int(abs(transformed.width).rounded()),
        uprightHeight: Int(abs(transformed.height).rounded()),
        preferredTransform: preferredTransform,
        transformedBounds: transformed
    )
    guard geometry.uprightWidth > 0, geometry.uprightHeight > 0 else {
        throw ProbeError.processingFailed("Clip \(clip.id) has invalid video dimensions")
    }
    let nominalFPSValue = Double(try await track.load(.nominalFrameRate))
    let minFrameDuration = try await track.load(.minFrameDuration)
    let nominalFPS = nominalFPSValue > 0 ? nominalFPSValue : (minFrameDuration.seconds > 0 ? 1 / minFrameDuration.seconds : 30)
    let sourceDuration = try await asset.load(.duration).seconds

    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    readerOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(readerOutput) else {
        throw ProbeError.processingFailed("Cannot read decoded frames from clip \(clip.id)")
    }
    reader.add(readerOutput)
    guard reader.startReading() else {
        throw reader.error ?? ProbeError.processingFailed("Cannot start reading clip \(clip.id)")
    }

    FileManager.default.createFile(atPath: measurementsURL.path, contents: nil)
    let measurementHandle = try FileHandle(forWritingTo: measurementsURL)
    defer { try? measurementHandle.close() }
    let comparisonWriter = try ComparisonWriter(outputURL: comparisonURL, framesPerSecond: nominalFPS, context: context)
    let personRequest = GeneratePersonSegmentationRequest()
    personRequest.qualityLevel = .accurate
    personRequest.outputPixelFormatType = kCVPixelFormatType_OneComponent8
    let foregroundRequest = GenerateForegroundInstanceMaskRequest()
    let personAccumulator = CandidateAccumulator(candidateID: "P0")
    let foregroundAccumulator = CandidateAccumulator(candidateID: "P1")
    var totalTimes: [Double] = []
    var previousPerson: MaskBytes?
    var previousForeground: MaskBytes?
    var previousPTS: CMTime?
    var firstPTS: CMTime?
    var frameIndex = 0
    var estimatedMissingFrames = 0
    var peakResidentMemory: UInt64 = 0
    let runStart = DispatchTime.now().uptimeNanoseconds

    while let sample = readerOutput.copyNextSampleBuffer() {
        autoreleasepool {
            // The async Vision calls are outside this autorelease pool via the helper below.
        }
        let frameStart = DispatchTime.now().uptimeNanoseconds
        guard let encodedBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw ProbeError.processingFailed("Clip \(clip.id) frame \(frameIndex) has no image buffer")
        }
        let normalizationStart = DispatchTime.now().uptimeNanoseconds
        let uprightBuffer = try normalize(
            encodedBuffer,
            geometry: geometry,
            context: context
        )
        let normalizationMilliseconds = millisecondsSince(normalizationStart)
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let normalizedSample = try sampleBuffer(imageBuffer: uprightBuffer, copyingTimingFrom: sample)
        let handler = ImageRequestHandler(normalizedSample)

        let personStart = DispatchTime.now().uptimeNanoseconds
        let personObservation = try await handler.perform(personRequest)
        let personImage = CIImage(cgImage: try personObservation.cgImage)
        let personMaskBuffer = try maskPixelBuffer(
            from: personImage,
            width: geometry.uprightWidth,
            height: geometry.uprightHeight,
            context: context
        )
        let personMilliseconds = millisecondsSince(personStart)

        let foregroundStart = DispatchTime.now().uptimeNanoseconds
        let foregroundObservation = try await handler.perform(foregroundRequest)
        let foregroundMaskBuffer: CVPixelBuffer
        var instanceImage = CIImage(color: .black).cropped(
            to: CGRect(x: 0, y: 0, width: geometry.uprightWidth, height: geometry.uprightHeight)
        )
        var instanceCoverage: [String: Double] = [:]
        let instanceCount: Int
        if let foregroundObservation {
            instanceCount = foregroundObservation.allInstances.count
            let union = try foregroundObservation.generateScaledMask(
                for: foregroundObservation.allInstances,
                scaledToImageFrom: handler
            )
            foregroundMaskBuffer = try maskPixelBuffer(
                from: CIImage(cvPixelBuffer: union),
                width: geometry.uprightWidth,
                height: geometry.uprightHeight,
                context: context
            )
            for instance in foregroundObservation.allInstances {
                let selected = try foregroundObservation.generateScaledMask(
                    for: IndexSet(integer: instance),
                    scaledToImageFrom: handler
                )
                let normalized = try maskPixelBuffer(
                    from: CIImage(cvPixelBuffer: selected),
                    width: geometry.uprightWidth,
                    height: geometry.uprightHeight,
                    context: context
                )
                let bytes = try maskBytes(normalized)
                instanceCoverage[String(instance)] = Double(bytes.values.filter { $0 >= 128 }.count) / Double(bytes.values.count)
                let color = instanceColor(instance)
                let colored = CIImage(color: color).cropped(to: instanceImage.extent)
                let mask = CIImage(cvPixelBuffer: normalized)
                instanceImage = colored.applyingFilter(
                    "CIBlendWithMask",
                    parameters: [kCIInputBackgroundImageKey: instanceImage, kCIInputMaskImageKey: mask]
                )
            }
        } else {
            instanceCount = 0
            foregroundMaskBuffer = try blackMaskBuffer(
                width: geometry.uprightWidth,
                height: geometry.uprightHeight,
                context: context
            )
        }
        let foregroundMilliseconds = millisecondsSince(foregroundStart)

        let personBytes = try maskBytes(personMaskBuffer)
        let foregroundBytes = try maskBytes(foregroundMaskBuffer)
        let seconds = presentation.seconds.isFinite ? presentation.seconds : Double(frameIndex) / nominalFPS
        let activeRegions = clip.regions.filter { seconds >= $0.startSeconds && seconds < $0.endSeconds }
        let personMeasurement = measureMask(personBytes, previous: previousPerson, regions: activeRegions)
        let foregroundMeasurement = measureMask(foregroundBytes, previous: previousForeground, regions: activeRegions)
        previousPerson = personBytes
        previousForeground = foregroundBytes

        let gap: Double?
        let missing: Int
        if let previousPTS {
            let value = CMTimeSubtract(presentation, previousPTS).seconds
            gap = value.isFinite ? value : nil
            missing = value.isFinite ? max(0, Int((value * nominalFPS).rounded()) - 1) : 0
        } else {
            gap = nil
            missing = 0
            firstPTS = presentation
        }
        previousPTS = presentation
        estimatedMissingFrames += missing

        let renderingStart = DispatchTime.now().uptimeNanoseconds
        let sourceImage = CIImage(cvPixelBuffer: uprightBuffer)
        let personMaskImage = displayMask(CIImage(cvPixelBuffer: personMaskBuffer))
        let foregroundMaskImage = displayMask(CIImage(cvPixelBuffer: foregroundMaskBuffer))
        let checkerboard = checkerboardBackground(extent: sourceImage.extent)
        let personComposite = sourceImage.applyingFilter(
            "CIBlendWithMask",
            parameters: [kCIInputBackgroundImageKey: checkerboard, kCIInputMaskImageKey: CIImage(cvPixelBuffer: personMaskBuffer)]
        )
        let foregroundComposite = sourceImage.applyingFilter(
            "CIBlendWithMask",
            parameters: [kCIInputBackgroundImageKey: checkerboard, kCIInputMaskImageKey: CIImage(cvPixelBuffer: foregroundMaskBuffer)]
        )
        let outputPTS = CMTimeSubtract(presentation, firstPTS ?? presentation)
        try comparisonWriter.append(
            source: sourceImage,
            personMask: personMaskImage,
            personComposite: personComposite,
            foregroundInstances: instanceImage,
            foregroundMask: foregroundMaskImage,
            foregroundComposite: foregroundComposite,
            presentationTime: outputPTS
        )
        let renderingMilliseconds = millisecondsSince(renderingStart)
        let totalMilliseconds = millisecondsSince(frameStart)
        let memory = residentMemoryBytes()
        peakResidentMemory = max(peakResidentMemory, memory)
        let frame = FrameMeasurement(
            frameIndex: frameIndex,
            presentationSeconds: seconds,
            sourceGapSeconds: gap,
            estimatedMissingSourceFrames: missing,
            normalizationMilliseconds: normalizationMilliseconds,
            personMilliseconds: personMilliseconds,
            foregroundMilliseconds: foregroundMilliseconds,
            renderingMilliseconds: renderingMilliseconds,
            totalMilliseconds: totalMilliseconds,
            person: personMeasurement,
            foreground: foregroundMeasurement,
            foregroundInstanceCount: instanceCount,
            foregroundInstanceCoverage: instanceCoverage,
            residentMemoryBytes: memory,
            thermalState: thermalStateString()
        )
        try appendJSONLine(frame, to: measurementHandle)
        personAccumulator.append(milliseconds: personMilliseconds, measurement: personMeasurement)
        foregroundAccumulator.append(milliseconds: foregroundMilliseconds, measurement: foregroundMeasurement)
        totalTimes.append(totalMilliseconds)
        frameIndex += 1
    }

    guard reader.status == .completed else {
        throw reader.error ?? ProbeError.processingFailed("Reading clip \(clip.id) did not complete")
    }
    guard frameIndex > 0 else {
        throw ProbeError.processingFailed("Clip \(clip.id) yielded zero video frames")
    }
    try await comparisonWriter.finish()
    try measurementHandle.synchronize()

    let wallClock = millisecondsSince(runStart) / 1_000
    let summary = ClipSummary(
        clipID: clip.id,
        cameraClass: clip.cameraClass,
        cameraName: clip.cameraName,
        lighting: clip.lighting,
        sourceWidth: geometry.uprightWidth,
        sourceHeight: geometry.uprightHeight,
        nominalFramesPerSecond: nominalFPS,
        sourceDurationSeconds: sourceDuration,
        framesProcessed: frameIndex,
        estimatedMissingSourceFrames: estimatedMissingFrames,
        wallClockSeconds: wallClock,
        effectiveProcessingFramesPerSecond: Double(frameIndex) / wallClock,
        peakResidentMemoryBytes: peakResidentMemory,
        person: personAccumulator.summary(),
        foreground: foregroundAccumulator.summary(),
        totalFrameMilliseconds: distribution(totalTimes),
        limitations: [
            "Normalized rectangular regions provide reproducible sampling, not pixel-accurate object ground truth; visual review remains controlling.",
            "Temporal XOR and IoU include intentional subject/object motion and are raw change measures, not automatic flicker verdicts.",
            "Processing is serial offline replay on every source frame. Its throughput and latency do not claim live capture/writer performance.",
            "Foreground instance colors follow each frame's raw instance index specifically to reveal, not conceal, index instability.",
            "No numeric quality threshold or support verdict is inferred by this prototype.",
        ]
    )
    try writeJSON(summary, to: summaryURL)
    try writeReviewWorksheet(clip: clip, phases: phases, to: reviewURL)

    return ProcessedClipRecord(
        clipID: clip.id,
        source: try artifactRecord(for: sourceURL),
        synchronizedComparison: try artifactRecord(for: comparisonURL),
        rawMeasurements: try artifactRecord(for: measurementsURL),
        measurementSummary: try artifactRecord(for: summaryURL),
        visualReviewWorksheet: try artifactRecord(for: reviewURL),
        summary: summary
    )
}

private func validateCaptureMetadataIfPresent(
    _ clip: ClipSpecification,
    sourceURL: URL,
    baseDirectory: URL
) throws -> [PhaseDefinition] {
    if let metadataPath = clip.captureMetadata {
        let metadataURL = resolvePath(metadataPath, relativeTo: baseDirectory)
        let metadata = try JSONDecoder().decode(CaptureMetadata.self, from: Data(contentsOf: metadataURL))
        guard metadata.clipID == clip.id else {
            throw ProbeError.invalidManifest("Capture metadata clip id does not match \(clip.id)")
        }
        guard metadata.camera.cameraClass == clip.cameraClass,
              metadata.camera.name == clip.cameraName,
              metadata.lighting == clip.lighting else {
            throw ProbeError.invalidManifest("Capture metadata camera/lighting identity does not match clip \(clip.id)")
        }
        guard metadata.sourceSHA256 == (try sha256(of: sourceURL)) else {
            throw ProbeError.invalidManifest("Source hash does not match capture metadata for clip \(clip.id)")
        }
        return metadata.phases
    }
    guard let phases = clip.phases, !phases.isEmpty else {
        throw ProbeError.invalidManifest("Clip \(clip.id) needs captureMetadata or an explicit phase list")
    }
    return phases
}

private func normalize(_ buffer: CVPixelBuffer, geometry: VideoGeometry, context: CIContext) throws -> CVPixelBuffer {
    let output = try pixelBuffer(width: geometry.uprightWidth, height: geometry.uprightHeight, format: kCVPixelFormatType_32BGRA)
    let source = CIImage(cvPixelBuffer: buffer)
    let transformed = source.transformed(by: geometry.preferredTransform)
    let zeroBased = transformed.transformed(by: .init(
        translationX: -geometry.transformedBounds.minX,
        y: -geometry.transformedBounds.minY
    ))
    context.render(
        zeroBased,
        to: output,
        bounds: CGRect(x: 0, y: 0, width: geometry.uprightWidth, height: geometry.uprightHeight),
        colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return output
}

private func sampleBuffer(imageBuffer: CVPixelBuffer, copyingTimingFrom sample: CMSampleBuffer) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescriptionOut: &format
    )
    guard formatStatus == noErr, let format else {
        throw ProbeError.processingFailed("Cannot create a normalized frame format description (\(formatStatus))")
    }
    var timing = CMSampleTimingInfo(
        duration: CMSampleBufferGetDuration(sample),
        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
        decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sample)
    )
    var normalized: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &normalized
    )
    guard sampleStatus == noErr, let normalized else {
        throw ProbeError.processingFailed("Cannot create a timestamped normalized sample (\(sampleStatus))")
    }
    return normalized
}

private func pixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        throw ProbeError.processingFailed("Cannot allocate pixel buffer \(width)x\(height) format \(fourCCString(format))")
    }
    return buffer
}

private func maskPixelBuffer(from image: CIImage, width: Int, height: Int, context: CIContext) throws -> CVPixelBuffer {
    let output = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_OneComponent8)
    let extent = image.extent
    let zeroBased = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
    let scaled = zeroBased.transformed(by: .init(
        scaleX: CGFloat(width) / max(1, extent.width),
        y: CGFloat(height) / max(1, extent.height)
    ))
    context.render(
        scaled,
        to: output,
        bounds: CGRect(x: 0, y: 0, width: width, height: height),
        colorSpace: CGColorSpaceCreateDeviceGray()
    )
    return output
}

private func blackMaskBuffer(width: Int, height: Int, context: CIContext) throws -> CVPixelBuffer {
    try maskPixelBuffer(
        from: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)),
        width: width,
        height: height,
        context: context
    )
}

private func maskBytes(_ buffer: CVPixelBuffer) throws -> MaskBytes {
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else {
        throw ProbeError.processingFailed("Expected OneComponent8 mask, got \(fourCCString(CVPixelBufferGetPixelFormatType(buffer)))")
    }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw ProbeError.processingFailed("Mask has no readable base address")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    var values = [UInt8](repeating: 0, count: width * height)
    for row in 0..<height {
        let source = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        values.withUnsafeMutableBytes { destination in
            destination.baseAddress!.advanced(by: row * width).copyMemory(from: source, byteCount: width)
        }
    }
    return MaskBytes(width: width, height: height, values: values)
}

private func measureMask(
    _ current: MaskBytes,
    previous: MaskBytes?,
    regions: [RegionSpecification]
) -> MaskFrameMeasurement {
    let total = current.values.count
    var binaryCount = 0
    var sum = 0
    var boundary = 0
    for y in 0..<current.height {
        for x in 0..<current.width {
            let index = y * current.width + x
            let value = current.values[index]
            let foreground = value >= 128
            if foreground { binaryCount += 1 }
            sum += Int(value)
            if x + 1 < current.width, foreground != (current.values[index + 1] >= 128) { boundary += 1 }
            if y + 1 < current.height, foreground != (current.values[index + current.width] >= 128) { boundary += 1 }
        }
    }

    var xorFraction: Double?
    var intersectionOverUnion: Double?
    if let previous, previous.width == current.width, previous.height == current.height {
        var xor = 0
        var intersection = 0
        var union = 0
        for index in current.values.indices {
            let a = current.values[index] >= 128
            let b = previous.values[index] >= 128
            if a != b { xor += 1 }
            if a && b { intersection += 1 }
            if a || b { union += 1 }
        }
        xorFraction = Double(xor) / Double(total)
        intersectionOverUnion = union == 0 ? 1 : Double(intersection) / Double(union)
    }

    var regionMeasurements: [String: RegionFrameMeasurement] = [:]
    for region in regions {
        let x0 = max(0, min(current.width - 1, Int((region.x * Double(current.width)).rounded(.down))))
        let y0 = max(0, min(current.height - 1, Int((region.y * Double(current.height)).rounded(.down))))
        let x1 = max(x0 + 1, min(current.width, Int(((region.x + region.width) * Double(current.width)).rounded(.up))))
        let y1 = max(y0 + 1, min(current.height, Int(((region.y + region.height) * Double(current.height)).rounded(.up))))
        var selectedCount = 0
        var selectedSum = 0
        let selectedTotal = (x1 - x0) * (y1 - y0)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let value = current.values[y * current.width + x]
                if value >= 128 { selectedCount += 1 }
                selectedSum += Int(value)
            }
        }
        regionMeasurements[region.label] = RegionFrameMeasurement(
            kind: region.kind.rawValue,
            binaryCoverageFraction: Double(selectedCount) / Double(selectedTotal),
            meanMaskValue: Double(selectedSum) / Double(selectedTotal * 255)
        )
    }

    return MaskFrameMeasurement(
        binaryCoverageFraction: Double(binaryCount) / Double(total),
        meanMaskValue: Double(sum) / Double(total * 255),
        temporalXORFraction: xorFraction,
        temporalIntersectionOverUnion: intersectionOverUnion,
        boundaryFraction: Double(boundary) / Double(max(1, total * 2)),
        regions: regionMeasurements
    )
}

private func checkerboardBackground(extent: CGRect) -> CIImage {
    let filter = CIFilter(name: "CICheckerboardGenerator", parameters: [
        "inputColor0": CIColor(red: 0.06, green: 0.12, blue: 0.25),
        "inputColor1": CIColor(red: 0.75, green: 0.1, blue: 0.58),
        "inputWidth": 32,
        "inputSharpness": 1,
    ])
    return (filter?.outputImage ?? CIImage(color: .magenta)).cropped(to: extent)
}

private func displayMask(_ mask: CIImage) -> CIImage {
    mask.applyingFilter("CIFalseColor", parameters: [
        "inputColor0": CIColor.black,
        "inputColor1": CIColor.white,
    ])
}

private func instanceColor(_ index: Int) -> CIColor {
    let colors: [CIColor] = [
        .init(red: 0.96, green: 0.25, blue: 0.21),
        .init(red: 0.20, green: 0.72, blue: 0.35),
        .init(red: 0.18, green: 0.55, blue: 0.96),
        .init(red: 0.98, green: 0.73, blue: 0.18),
        .init(red: 0.67, green: 0.32, blue: 0.91),
        .init(red: 0.16, green: 0.83, blue: 0.82),
    ]
    return colors[abs(index) % colors.count]
}

private func writeReviewWorksheet(clip: ClipSpecification, phases: [PhaseDefinition], to url: URL) throws {
    let header = "clip_id,camera_class,camera_name,lighting,phase,start_seconds,end_seconds,candidate,object,present_and_visible,frames_reviewed,partial_cutoff_events,flicker_events,disappearance_events,edge_failure_events,false_inclusion_events,reviewer,notes\n"
    let objects = ["person", "hair-clothing", "glasses-if-worn", "chair-back", "shure-microphone", "background"]
    var body = header
    for phase in phases {
        for candidate in ["P0-person", "P1-all-foreground"] {
            for object in objects {
                let values = [
                    clip.id,
                    clip.cameraClass,
                    clip.cameraName,
                    clip.lighting,
                    phase.label,
                    String(phase.startSeconds),
                    String(phase.endSeconds),
                    candidate,
                    object,
                    "", "", "", "", "", "", "", "", "",
                ]
                body += values.map(csvEscape).joined(separator: ",") + "\n"
            }
        }
    }
    try body.write(to: url, atomically: true, encoding: .utf8)
}

private func csvEscape(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}
