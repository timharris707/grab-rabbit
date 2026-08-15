//
//  RecordingOutputJob.swift
//  QuickRecorder
//

import Darwin
import Foundation

enum RecordingOutputReservationError: LocalizedError {
    case invalidDirectory(URL)
    case exhaustedNames(URL)
    case reservationFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidDirectory(let directory):
            return "The recording directory is unavailable: \(directory.path)"
        case .exhaustedNames(let directory):
            return "Unable to choose a unique recording name in: \(directory.path)"
        case .reservationFailed(let url, let reason):
            return "Unable to reserve \(url.lastPathComponent): \(reason)"
        }
    }
}

enum RecordingExportError: LocalizedError, Equatable {
    enum Stage: String, Equatable {
        case first
        case second
        case conversion
    }

    case preparation(stage: Stage, message: String)
    case failed(stage: Stage, message: String)
    case cancelled(stage: Stage)
    case missingOutput(path: String)
    case publicationFailed(path: String, message: String)
    case cleanupFailed(original: String, remainingPaths: [String])

    var errorDescription: String? {
        switch self {
        case .preparation(let stage, let message):
            return "Unable to prepare the \(stage.rawValue) export stage: \(message)"
        case .failed(let stage, let message):
            return "The \(stage.rawValue) export stage failed: \(message)"
        case .cancelled(let stage):
            return "The \(stage.rawValue) export stage was cancelled."
        case .missingOutput(let path):
            return "The recording did not produce a valid output at: \(path)"
        case .publicationFailed(let path, let message):
            return "Unable to publish the recording at \(path): \(message)"
        case .cleanupFailed(let original, let remainingPaths):
            return "\(original) Cleanup also failed for: \(remainingPaths.joined(separator: ", "))"
        }
    }
}

final class RecordingOutputJob {
    enum Lifecycle: Equatable {
        case recording
        case postprocessing
        case terminal
    }

    struct Layout {
        enum Kind: Equatable {
            case single
            case conversion
            case videoRemux
            case package(automaticallyExports: Bool)
        }

        let kind: Kind
        let inputSuffix: String
        let intermediateSuffixes: [String]
        let finalSuffix: String
        let recordsMicrophone: Bool
        let requiredPackageMembers: [String]
        let audioQualityKbps: Int?

        static func single(
            fileExtension: String,
            recordsMicrophone: Bool = false,
            audioQualityKbps: Int? = nil
        ) -> Layout {
            let suffix = normalizedSuffix(fileExtension)
            return Layout(
                kind: .single,
                inputSuffix: suffix,
                intermediateSuffixes: [],
                finalSuffix: suffix,
                recordsMicrophone: recordsMicrophone,
                requiredPackageMembers: [],
                audioQualityKbps: audioQualityKbps
            )
        }

        static func conversion(
            inputExtension: String,
            finalExtension: String,
            audioQualityKbps: Int? = nil
        ) -> Layout {
            Layout(
                kind: .conversion,
                inputSuffix: normalizedSuffix(inputExtension),
                intermediateSuffixes: [],
                finalSuffix: normalizedSuffix(finalExtension),
                recordsMicrophone: false,
                requiredPackageMembers: [],
                audioQualityKbps: audioQualityKbps
            )
        }

        static func videoRemux(fileExtension: String) -> Layout {
            let suffix = normalizedSuffix(fileExtension)
            return Layout(
                kind: .videoRemux,
                inputSuffix: suffix + suffix + suffix,
                intermediateSuffixes: [suffix + suffix],
                finalSuffix: suffix,
                recordsMicrophone: true,
                requiredPackageMembers: [],
                audioQualityKbps: nil
            )
        }

        static func package(
            fileExtension: String,
            requiredMembers: [String],
            automaticallyExports: Bool,
            audioQualityKbps: Int? = nil
        ) -> Layout {
            let suffix = normalizedSuffix(fileExtension)
            return Layout(
                kind: .package(automaticallyExports: automaticallyExports),
                inputSuffix: suffix,
                intermediateSuffixes: [],
                finalSuffix: suffix,
                recordsMicrophone: true,
                requiredPackageMembers: requiredMembers,
                audioQualityKbps: audioQualityKbps
            )
        }

        private static func normalizedSuffix(_ fileExtension: String) -> String {
            fileExtension.hasPrefix(".") ? fileExtension : ".\(fileExtension)"
        }
    }

    let kind: Layout.Kind
    let recordsMicrophone: Bool
    let audioQualityKbps: Int?
    let inputURL: URL
    let intermediateURLs: [URL]
    let stagedOutputURL: URL
    let finalURL: URL
    let reservationURL: URL

    private let fileManager: FileManager
    private let isPackage: Bool
    private let requiredPackageMembers: [String]
    private let terminalLock = NSLock()
    private var terminalResult: Result<URL, RecordingExportError>?
    private var lifecycleStorage = Lifecycle.recording
    private var didDeliverTerminal = false

    var lifecycle: Lifecycle {
        terminalLock.lock()
        defer { terminalLock.unlock() }
        return lifecycleStorage
    }

    private init(
        layout: Layout,
        inputURL: URL,
        intermediateURLs: [URL],
        stagedOutputURL: URL,
        finalURL: URL,
        reservationURL: URL,
        fileManager: FileManager,
        isPackage: Bool
    ) {
        kind = layout.kind
        recordsMicrophone = layout.recordsMicrophone
        audioQualityKbps = layout.audioQualityKbps
        self.inputURL = inputURL
        self.intermediateURLs = intermediateURLs
        self.stagedOutputURL = stagedOutputURL
        self.finalURL = finalURL
        self.reservationURL = reservationURL
        self.fileManager = fileManager
        self.isPackage = isPackage
        self.requiredPackageMembers = layout.requiredPackageMembers
    }

    static func reserve(
        in directory: URL,
        prefix: String,
        date: Date = Date(),
        layout: Layout,
        fileManager: FileManager = .default
    ) throws -> RecordingOutputJob {
        let formatter = DateFormatter()
        formatter.dateFormat = "y-MM-dd HH.mm.ss"
        return try reserve(
            in: directory,
            preferredStem: prefix + formatter.string(from: date),
            layout: layout,
            fileManager: fileManager
        )
    }

    static func reserve(
        in directory: URL,
        preferredStem: String,
        layout: Layout,
        fileManager: FileManager = .default
    ) throws -> RecordingOutputJob {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RecordingOutputReservationError.invalidDirectory(directory)
        }

        for attempt in 0..<10_000 {
            let stem = attempt == 0 ? preferredStem : "\(preferredStem) \(attempt + 1)"
            let baseURL = directory.appendingPathComponent(stem)
            let finalURL = URL(fileURLWithPath: baseURL.path + layout.finalSuffix)
            if itemExists(at: finalURL) { continue }

            let reservationURL = directory.appendingPathComponent(
                ".\(stem).quickrecorder-job-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(
                    at: reservationURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw RecordingOutputReservationError.reservationFailed(reservationURL, error.localizedDescription)
            }

            let isPackage: Bool
            if case .package = layout.kind {
                isPackage = true
                do {
                    try fileManager.createDirectory(
                        at: finalURL,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    try? fileManager.removeItem(at: reservationURL)
                    if itemExists(at: finalURL) { continue }
                    throw RecordingOutputReservationError.reservationFailed(finalURL, error.localizedDescription)
                }
            } else {
                isPackage = false
                do {
                    guard try createExclusiveFile(at: finalURL) else {
                        try? fileManager.removeItem(at: reservationURL)
                        continue
                    }
                } catch {
                    try? fileManager.removeItem(at: reservationURL)
                    throw RecordingOutputReservationError.reservationFailed(finalURL, error.localizedDescription)
                }
            }

            let inputURL: URL
            let intermediateURLs: [URL]
            let stagedOutputURL: URL
            if isPackage {
                intermediateURLs = []
                stagedOutputURL = reservationURL.appendingPathComponent(
                    "output\(layout.finalSuffix)",
                    isDirectory: true
                )
                do {
                    try fileManager.createDirectory(
                        at: stagedOutputURL,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    try? fileManager.removeItem(at: reservationURL)
                    try? fileManager.removeItem(at: finalURL)
                    throw RecordingOutputReservationError.reservationFailed(
                        stagedOutputURL,
                        error.localizedDescription
                    )
                }
                inputURL = stagedOutputURL
            } else {
                inputURL = reservationURL.appendingPathComponent("input\(layout.inputSuffix)")
                intermediateURLs = layout.intermediateSuffixes.enumerated().map { index, suffix in
                    reservationURL.appendingPathComponent("intermediate-\(index + 1)\(suffix)")
                }
                stagedOutputURL = layout.kind == .single
                    ? inputURL
                    : reservationURL.appendingPathComponent("output\(layout.finalSuffix)")
            }

            return RecordingOutputJob(
                layout: layout,
                inputURL: inputURL,
                intermediateURLs: intermediateURLs,
                stagedOutputURL: stagedOutputURL,
                finalURL: finalURL,
                reservationURL: reservationURL,
                fileManager: fileManager,
                isPackage: isPackage
            )
        }

        throw RecordingOutputReservationError.exhaustedNames(directory)
    }

    // Success atomically publishes one final artifact. Failure/cancellation removes every path reserved by this job.
    func finishExport(_ result: Result<Void, RecordingExportError>) -> Result<URL, RecordingExportError> {
        terminalLock.lock()
        defer { terminalLock.unlock() }
        if let terminalResult { return terminalResult }
        if lifecycleStorage == .recording { lifecycleStorage = .postprocessing }

        let completed: Result<URL, RecordingExportError>
        switch result {
        case .success:
            if isPackage {
                completed = finishPackage()
            } else {
                completed = publishStagedOutput()
            }
        case .failure(let error):
            completed = cleanupAfterFailure(error)
        }
        terminalResult = completed
        lifecycleStorage = .terminal
        return completed
    }

    @discardableResult
    func finishExport(
        _ result: Result<Void, RecordingExportError>,
        deliveringTo completion: (Result<URL, RecordingExportError>) -> Void
    ) -> Result<URL, RecordingExportError> {
        let completed = finishExport(result)
        terminalLock.lock()
        let shouldDeliver = !didDeliverTerminal
        didDeliverTerminal = true
        terminalLock.unlock()
        if shouldDeliver { completion(completed) }
        return completed
    }

    @discardableResult
    func beginPostprocessing() -> Bool {
        terminalLock.lock()
        defer { terminalLock.unlock() }
        switch lifecycleStorage {
        case .recording:
            lifecycleStorage = .postprocessing
            return true
        case .postprocessing:
            return true
        case .terminal:
            return false
        }
    }

    func finishSingleOutput() -> Result<URL, RecordingExportError> {
        finishExport(.success(()))
    }

    func finishPackageAfterWriter(
        _ writerResult: Result<Void, RecordingExportError>,
        onTerminal: (Result<URL, RecordingExportError>) -> Void
    ) -> Result<URL, RecordingExportError> {
        finishExport(writerResult, deliveringTo: onTerminal)
    }

    func discardOutputs(reason: RecordingExportError) -> RecordingExportError {
        switch finishExport(.failure(reason)) {
        case .success:
            return reason
        case .failure(let error):
            return error
        }
    }

    private func finishPackage() -> Result<URL, RecordingExportError> {
        guard !requiredPackageMembers.isEmpty else {
            return cleanupAfterFailure(.missingOutput(path: finalURL.path))
        }
        for member in requiredPackageMembers {
            let memberURL = stagedOutputURL.appendingPathComponent(member)
            guard isNonemptyRegularFile(memberURL) else {
                return cleanupAfterFailure(.missingOutput(path: memberURL.path))
            }
        }
        do {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: stagedOutputURL)
        } catch {
            return cleanupAfterFailure(.publicationFailed(
                path: finalURL.path,
                message: error.localizedDescription
            ))
        }
        guard isDirectory(finalURL) else {
            return cleanupAfterFailure(.missingOutput(path: finalURL.path))
        }
        for member in requiredPackageMembers {
            let memberURL = finalURL.appendingPathComponent(member)
            guard isNonemptyRegularFile(memberURL) else {
                return cleanupAfterFailure(.missingOutput(path: memberURL.path))
            }
        }
        let failures = remove([reservationURL])
        guard failures.isEmpty else {
            return .failure(.cleanupFailed(
                original: "The recording export completed.",
                remainingPaths: failures.map(\.path).sorted()
            ))
        }
        return .success(finalURL)
    }

    private func publishStagedOutput() -> Result<URL, RecordingExportError> {
        guard isNonemptyRegularFile(stagedOutputURL) else {
            return cleanupAfterFailure(.missingOutput(path: stagedOutputURL.path))
        }
        do {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: stagedOutputURL)
        } catch {
            return cleanupAfterFailure(.publicationFailed(path: finalURL.path, message: error.localizedDescription))
        }
        guard isNonemptyRegularFile(finalURL) else {
            return cleanupAfterFailure(.missingOutput(path: finalURL.path))
        }
        let failures = remove([reservationURL])
        guard failures.isEmpty else {
            return .failure(.cleanupFailed(
                original: "The recording export completed.",
                remainingPaths: failures.map(\.path).sorted()
            ))
        }
        return .success(finalURL)
    }

    private func cleanupAfterFailure(_ error: RecordingExportError) -> Result<URL, RecordingExportError> {
        let failures = remove([reservationURL, finalURL])
        guard failures.isEmpty else {
            return .failure(.cleanupFailed(
                original: error.localizedDescription,
                remainingPaths: failures.map(\.path).sorted()
            ))
        }
        return .failure(error)
    }

    private func isNonemptyRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func remove(_ urls: [URL]) -> [URL] {
        var failures = [URL]()
        for url in urls where Self.itemExists(at: url) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failures.append(url)
            }
        }
        return failures
    }

    private static func itemExists(at url: URL) -> Bool {
        var fileStatus = stat()
        return url.path.withCString { path in
            Darwin.lstat(path, &fileStatus) == 0
        }
    }

    private static func createExclusiveFile(at url: URL) throws -> Bool {
        let (descriptor, openErrno): (Int32, Int32) = url.path.withCString { path in
            let result = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            return (result, errno)
        }
        guard descriptor >= 0 else {
            if openErrno == EEXIST { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(openErrno))
        }
        guard Darwin.close(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return true
    }
}
