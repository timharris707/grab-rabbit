@preconcurrency import AVFoundation
import AppKit
import Foundation

final class MovieCaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let lock = NSLock()
    private var didStart = false
    private var finishResult: Result<Void, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Error>] = []

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        lock.lock()
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let result: Result<Void, Error>
        if let error {
            let nsError = error as NSError
            let finished = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
            result = finished ? .success(()) : .failure(error)
        } else {
            result = .success(())
        }

        lock.lock()
        finishResult = result
        let waiters = finishWaiters
        finishWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(with: result) }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didStart {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func waitUntilFinished() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let finishResult {
                lock.unlock()
                continuation.resume(with: finishResult)
            } else {
                finishWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

func ensureCameraAuthorization() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        return true
    case .notDetermined:
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    case .denied, .restricted:
        return false
    @unknown default:
        return false
    }
}

func captureClip(deviceID: String, clipID: String, lighting: String, outputDirectory: URL) async throws -> CaptureMetadata {
    guard clipID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
        throw ProbeError.invalidArguments("clip-id may contain letters, numbers, period, underscore, and hyphen only")
    }
    guard !lighting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ProbeError.invalidArguments("lighting must describe the visible lighting condition")
    }
    guard await ensureCameraAuthorization() else {
        throw ProbeError.cameraAccessDenied
    }
    guard let device = discoverCameras().first(where: { $0.uniqueID == deviceID }) else {
        let available = discoverCameras().map { "\($0.localizedName) [\($0.uniqueID)]" }.joined(separator: "\n")
        throw ProbeError.missingCamera("No connected camera has unique ID \(deviceID). Available cameras:\n\(available)")
    }

    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let movieURL = outputDirectory.appendingPathComponent("\(clipID).mov")
    let metadataURL = outputDirectory.appendingPathComponent("\(clipID).capture.json")
    guard !FileManager.default.fileExists(atPath: movieURL.path),
          !FileManager.default.fileExists(atPath: metadataURL.path) else {
        throw ProbeError.captureFailed("Refusing to overwrite existing evidence for clip \(clipID)")
    }

    let session = AVCaptureSession()
    let movieOutput = AVCaptureMovieFileOutput()
    let captureDelegate = MovieCaptureDelegate()

    session.beginConfiguration()
    if session.canSetSessionPreset(.hd1920x1080) {
        session.sessionPreset = .hd1920x1080
    } else {
        session.sessionPreset = .high
    }

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
        throw ProbeError.captureFailed("The selected camera cannot be added to the capture session")
    }
    session.addInput(input)
    guard session.canAddOutput(movieOutput) else {
        throw ProbeError.captureFailed("A movie output cannot be added for the selected camera")
    }
    session.addOutput(movieOutput)
    session.commitConfiguration()

    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            continuation.resume()
        }
    }
    guard session.isRunning else {
        throw ProbeError.captureFailed("The capture session did not start")
    }
    defer { session.stopRunning() }

    movieOutput.startRecording(to: movieURL, recordingDelegate: captureDelegate)
    await captureDelegate.waitUntilStarted()

    print("Recording started. Keep one person, the actual chair back, and the actual Shure microphone visible.")
    print("Keep this lighting condition fixed for the entire clip: \(lighting)")
    let phases = PhaseDefinition.standard
    for (index, phase) in phases.enumerated() {
        if index > 0 {
            let delay = phase.startSeconds - phases[index - 1].startSeconds
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        NSSound.beep()
        print("[\(Int(phase.startSeconds))s–\(Int(phase.endSeconds))s] \(phase.label)")
    }
    let remaining = phases.last!.endSeconds - phases.last!.startSeconds
    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))

    movieOutput.stopRecording()
    try await captureDelegate.waitUntilFinished()
    session.stopRunning()

    let asset = AVURLAsset(url: movieURL)
    let duration = try await asset.load(.duration).seconds
    let attributes = try FileManager.default.attributesOfItem(atPath: movieURL.path)
    let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let metadata = CaptureMetadata(
        version: 1,
        capturedAt: nowString(),
        clipID: clipID,
        lighting: lighting,
        sourceFile: movieURL.lastPathComponent,
        sourceSHA256: try sha256(of: movieURL),
        sourceBytes: bytes,
        durationSeconds: duration,
        host: hostSnapshot(),
        camera: cameraSnapshot(device),
        phases: phases,
        captureNotes: [
            "Video only; the Shure microphone is a required visible foreground object, not an audio source in this clip.",
            "The operator physically performed the printed phases; the tool does not infer that the required person, chair, microphone, glasses, motion, occlusion, or lighting was actually present.",
            "Capture was explicitly started by a human. No cloud service, paid API, or downloaded model was used.",
        ]
    )
    try writeJSON(metadata, to: metadataURL)
    print("Captured \(String(format: "%.3f", duration)) seconds to \(movieURL.path)")
    print("Capture metadata: \(metadataURL.path)")
    return metadata
}
