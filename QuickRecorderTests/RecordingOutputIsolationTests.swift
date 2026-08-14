import XCTest

final class RecordingOutputIsolationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let frozenDate = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testDelayedJobCannotDeleteNextRecording() throws {
        let first = try makeRemuxJob()
        materialize(first.inputURL, contents: "first input")
        let exporter = DelayedTwoStageExporter()
        var terminalResult: Result<URL, RecordingExportError>?
        var terminalCount = 0
        XCTAssertEqual(first.lifecycle, .recording)
        exporter.export(first) { result in
            terminalResult = result
            terminalCount += 1
        }
        XCTAssertEqual(first.lifecycle, .postprocessing)
        XCTAssertNil(terminalResult)

        let second = try makeRemuxJob()
        materialize(second.inputURL, contents: "second input")
        XCTAssertEqual(first.lifecycle, .postprocessing)
        XCTAssertEqual(second.lifecycle, .recording)

        exporter.completeFirst(.success(()))
        XCTAssertNil(terminalResult)
        XCTAssertEqual(first.lifecycle, .postprocessing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.intermediateURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.inputURL.path))
        exporter.completeSecond(.success(()))
        let result = try XCTUnwrap(terminalResult)

        XCTAssertEqual(try result.get(), first.finalURL)
        XCTAssertEqual(first.lifecycle, .terminal)
        XCTAssertEqual(second.lifecycle, .recording)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.inputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.intermediateURLs[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.reservationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.finalURL.path))
        XCTAssertEqual(try Data(contentsOf: first.finalURL), Data("second-stage output".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.inputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.reservationURL.path))

        try Data("still writable".utf8).write(to: second.inputURL)
        XCTAssertEqual(try Data(contentsOf: second.inputURL), Data("still writable".utf8))
        _ = first.finishExport(.success(())) { _ in terminalCount += 1 }
        XCTAssertEqual(terminalCount, 1)
        _ = second.discardOutputs(reason: .cancelled(stage: .first))
        XCTAssertEqual(second.lifecycle, .terminal)
    }

    func testDelayedTwoStageFailureAndCancellationCleanOnlyOwnedPaths() throws {
        let terminalErrors: [RecordingExportError] = [
            .failed(stage: .first, message: "first-stage failure"),
            .cancelled(stage: .first),
            .failed(stage: .second, message: "second-stage failure"),
            .cancelled(stage: .second),
        ]

        for terminalError in terminalErrors {
            let job = try makeRemuxJob()
            materialize(job.inputURL, contents: "sensitive recording")
            let exporter = DelayedTwoStageExporter()
            var terminalResult: Result<URL, RecordingExportError>?
            exporter.export(job) { terminalResult = $0 }

            switch terminalError {
            case .failed(stage: .first, message: _), .cancelled(stage: .first):
                exporter.completeFirst(.failure(terminalError))
            case .failed(stage: .second, message: _), .cancelled(stage: .second):
                exporter.completeFirst(.success(()))
                XCTAssertNil(terminalResult)
                XCTAssertEqual(job.lifecycle, .postprocessing)
                exporter.completeSecond(.failure(terminalError))
            default:
                XCTFail("The delayed exporter only models first- and second-stage outcomes.")
            }

            guard case .failure(let returnedError) = terminalResult else {
                return XCTFail("A failed or cancelled delayed export must remain a typed failure.")
            }
            XCTAssertEqual(returnedError, terminalError)
            XCTAssertEqual(job.lifecycle, .terminal)
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
        }
    }

    func testSameSecondOutputsAreDistinct() throws {
        let firstRecording = try makeRemuxJob()
        let secondRecording = try makeRemuxJob()
        let firstFrame = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            prefix: "Capturing at ",
            date: frozenDate,
            layout: .single(fileExtension: "png")
        )
        let secondFrame = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            prefix: "Capturing at ",
            date: frozenDate,
            layout: .single(fileExtension: "png")
        )

        XCTAssertNotEqual(firstRecording.finalURL, secondRecording.finalURL)
        XCTAssertNotEqual(firstFrame.finalURL, secondFrame.finalURL)
        XCTAssertNotEqual(firstRecording.reservationURL, secondRecording.reservationURL)
        XCTAssertNotEqual(firstFrame.reservationURL, secondFrame.reservationURL)

        for job in [firstRecording, secondRecording, firstFrame, secondFrame] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.reservationURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.finalURL.path))
            XCTAssertThrowsError(try Data("collision".utf8).write(to: job.finalURL, options: .withoutOverwriting))
            _ = job.discardOutputs(reason: .cancelled(stage: .first))
        }
    }

    func testConcurrentSameSecondReservationsAreDistinct() throws {
        let directory = try XCTUnwrap(temporaryDirectory)
        let date = frozenDate
        let results = ThreadSafeJobResults()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            results.append(Result {
                try RecordingOutputJob.reserve(
                    in: directory,
                    prefix: "Recording at ",
                    date: date,
                    layout: .videoRemux(fileExtension: "mp4")
                )
            })
        }

        let completed = results.values
        XCTAssertEqual(completed.count, 16)
        let jobs = try completed.map { try $0.get() }
        XCTAssertEqual(Set(jobs.map(\.finalURL)).count, 16)
        XCTAssertEqual(Set(jobs.map(\.reservationURL)).count, 16)
        for job in jobs {
            _ = job.discardOutputs(reason: .cancelled(stage: .first))
        }
    }

    func testFailedOrCancelledExportLeavesNoUnownedResidue() throws {
        let terminalErrors: [RecordingExportError] = [
            .failed(stage: .first, message: "first-stage failure"),
            .cancelled(stage: .first),
            .failed(stage: .second, message: "second-stage failure"),
            .cancelled(stage: .second),
            .failed(stage: .conversion, message: "conversion failure"),
            .cancelled(stage: .conversion),
        ]

        for terminalError in terminalErrors {
            let job = try makeRemuxJob()
            let stagedURLs = Set([job.inputURL, job.stagedOutputURL] + job.intermediateURLs)
            for url in stagedURLs { materialize(url, contents: "sensitive recording") }
            XCTAssertEqual(job.lifecycle, .recording)
            XCTAssertTrue(job.beginPostprocessing())
            XCTAssertEqual(job.lifecycle, .postprocessing)

            let result = job.finishExport(.failure(terminalError))

            switch result {
            case .success:
                XCTFail("A failed or cancelled export must remain a typed failure.")
            case .failure(let returnedError):
                XCTAssertEqual(returnedError, terminalError)
            }
            for url in stagedURLs { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
            XCTAssertEqual(job.lifecycle, .terminal)
        }
    }

    func testFinalizationKindIsImmutableAfterSettingsChange() throws {
        var remuxEnabled = true
        let videoJob = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            prefix: "Recording at ",
            date: frozenDate,
            layout: makeVideoLayout(remuxEnabled: remuxEnabled)
        )
        remuxEnabled = false

        var audioFormat = "mp3"
        var audioQualityKbps = 256
        let audioJob = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            prefix: "Recording at ",
            date: frozenDate,
            layout: audioFormat == "mp3"
                ? .conversion(
                    inputExtension: "m4a",
                    finalExtension: "mp3",
                    audioQualityKbps: audioQualityKbps
                )
                : .single(fileExtension: audioFormat)
        )
        audioFormat = "aac"
        audioQualityKbps = 64

        XCTAssertFalse(remuxEnabled)
        XCTAssertEqual(audioFormat, "aac")
        XCTAssertEqual(videoJob.kind, .videoRemux)
        XCTAssertEqual(audioJob.kind, .conversion)
        XCTAssertEqual(audioJob.audioQualityKbps, 256)
        XCTAssertEqual(audioQualityKbps, 64)
        _ = videoJob.discardOutputs(reason: .cancelled(stage: .first))
        _ = audioJob.discardOutputs(reason: .cancelled(stage: .conversion))
    }

    func testExistingExternalOutputIsNeverClaimedOrDeleted() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "y-MM-dd HH.mm.ss"
        let externalURL = temporaryDirectory
            .appendingPathComponent("Recording at \(formatter.string(from: frozenDate)).mp4")
        materialize(externalURL, contents: "external")

        let job = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            prefix: "Recording at ",
            date: frozenDate,
            layout: .single(fileExtension: "mp4")
        )

        XCTAssertNotEqual(job.finalURL, externalURL)
        _ = job.discardOutputs(reason: .cancelled(stage: .first))
        XCTAssertEqual(try Data(contentsOf: externalURL), Data("external".utf8))
    }

    func testDanglingSymlinkOutputNameIsSkippedAndPreserved() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "y-MM-dd HH.mm.ss"
        let symlinkURL = temporaryDirectory
            .appendingPathComponent("Recording at \(formatter.string(from: frozenDate)).mp4")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: temporaryDirectory.appendingPathComponent("missing-target")
        )

        let job = try makeRemuxJob()

        XCTAssertNotEqual(job.finalURL, symlinkURL)
        _ = job.discardOutputs(reason: .cancelled(stage: .first))
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path))
    }

    func testSuccessfulFinalizationRequiresProducedArtifact() throws {
        let job = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            prefix: "Capturing at ",
            date: frozenDate,
            layout: .single(fileExtension: "png")
        )

        let result = job.finishSingleOutput()

        guard case .failure(.missingOutput(let path)) = result else {
            return XCTFail("Missing output must remain a typed failure.")
        }
        XCTAssertEqual(path, job.stagedOutputURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
    }

    func testPreparationFailureRemainsTypedAndCleansOwnedPaths() throws {
        let job = try makeRemuxJob()
        materialize(job.inputURL, contents: "sensitive recording")
        let preparationError = RecordingExportError.preparation(
            stage: .first,
            message: "unsupported format"
        )

        let result = job.finishExport(.failure(preparationError))

        guard case .failure(let returnedError) = result else {
            return XCTFail("Preparation failure must remain a typed failure.")
        }
        XCTAssertEqual(returnedError, preparationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.inputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
    }

    func testAutomaticPackageExportAvoidsExistingSameStemOutput() throws {
        let preferredStem = "Recording at package-time"
        let externalURL = temporaryDirectory.appendingPathComponent("\(preferredStem).mp3")
        materialize(externalURL, contents: "external")
        let job = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            preferredStem: preferredStem,
            layout: .conversion(inputExtension: "m4a", finalExtension: "mp3")
        )
        materialize(job.inputURL, contents: "rendered audio")
        materialize(job.stagedOutputURL, contents: "converted audio")

        let outputURL = try job.finishExport(.success(())).get()

        XCTAssertNotEqual(outputURL, externalURL)
        XCTAssertEqual(try Data(contentsOf: externalURL), Data("external".utf8))
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("converted audio".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
    }

    func testFailedAutomaticMP3ConversionLeavesNoResidue() throws {
        let job = try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            preferredStem: "Recording at package-time",
            layout: .conversion(inputExtension: "m4a", finalExtension: "mp3")
        )
        materialize(job.inputURL, contents: "rendered audio")
        materialize(job.stagedOutputURL, contents: "partial mp3")
        let conversionError = RecordingExportError.failed(
            stage: .conversion,
            message: "encoder failed"
        )

        let result = job.finishExport(.failure(conversionError))

        guard case .failure(let returnedError) = result else {
            return XCTFail("Failed conversion must remain a typed failure.")
        }
        XCTAssertEqual(returnedError, conversionError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.inputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.stagedOutputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
    }

    func testPackageCannotFinalizeWithOnlyInfoMember() throws {
        let job = try makePackageJob()
        materialize(packageMember("info.json", in: job), contents: "{}")
        let writer = DelayedPackageWriter()
        var readyCount = 0
        var terminalCount = 0
        var result: Result<URL, RecordingExportError>?
        XCTAssertTrue(job.beginPostprocessing())
        writer.finish { writerResult in
            result = job.finishPackageAfterWriter(writerResult) { terminalResult in
                terminalCount += 1
                if case .success = terminalResult { readyCount += 1 }
            }
        }

        XCTAssertNil(result)
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(terminalCount, 0)
        XCTAssertEqual(job.lifecycle, .postprocessing)
        writer.complete(.success(()))

        guard case .failure(.missingOutput(let path)) = result else {
            return XCTFail("An info-only package must not finalize.")
        }
        XCTAssertTrue(path.hasSuffix("sys.m4a"))
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(job.lifecycle, .terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
    }

    func testPackageStagesPrivatelyAndPublishesAtomically() throws {
        let job = try makePackageJob()

        XCTAssertEqual(job.inputURL, job.stagedOutputURL)
        XCTAssertTrue(job.inputURL.path.hasPrefix(job.reservationURL.path + "/"))
        let reservationMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: job.reservationURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        let packageMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: job.inputURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(reservationMode, 0o700)
        XCTAssertEqual(packageMode, 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.finalURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: job.finalURL.path), [])

        materializeRequiredPackageMembers(in: job)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageMember("info.json", in: job).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: job.finalURL.appendingPathComponent("info.json").path
        ))

        _ = job.beginPostprocessing()
        let outputURL = try job.finishPackageAfterWriter(.success(())) { _ in }.get()

        XCTAssertEqual(outputURL, job.finalURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
        for member in ["info.json", "sys.m4a", "mic.m4a"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: job.finalURL.appendingPathComponent(member).path
            ))
        }
    }

    func testPackageCannotFinalizeWithoutMicMember() throws {
        let job = try makePackageJob()
        materialize(packageMember("info.json", in: job), contents: "{}")
        materialize(packageMember("sys.m4a", in: job), contents: "system audio")
        let writer = DelayedPackageWriter()
        var readyCount = 0
        var terminalCount = 0
        var result: Result<URL, RecordingExportError>?
        XCTAssertTrue(job.beginPostprocessing())
        writer.finish { writerResult in
            result = job.finishPackageAfterWriter(writerResult) { terminalResult in
                terminalCount += 1
                if case .success = terminalResult { readyCount += 1 }
            }
        }

        XCTAssertNil(result)
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(terminalCount, 0)
        XCTAssertEqual(job.lifecycle, .postprocessing)
        writer.complete(.success(()))

        guard case .failure(.missingOutput(let path)) = result else {
            return XCTFail("A package without finalized microphone audio must not finalize.")
        }
        XCTAssertTrue(path.hasSuffix("mic.m4a"))
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(job.lifecycle, .terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
    }

    func testPackageCannotFinalizeWithOnlySystemAudioMember() throws {
        let job = try makePackageJob()
        materialize(packageMember("sys.m4a", in: job), contents: "system audio")
        var readyCount = 0
        var terminalCount = 0

        _ = job.beginPostprocessing()
        let result = job.finishPackageAfterWriter(.success(())) { terminalResult in
            terminalCount += 1
            if case .success = terminalResult { readyCount += 1 }
        }

        guard case .failure(.missingOutput(let path)) = result else {
            return XCTFail("A system-audio-only package must not finalize.")
        }
        XCTAssertTrue(path.hasSuffix("info.json"))
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(job.lifecycle, .terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
    }

    func testDelayedPackageWriterPublishesReadyOnceAfterCompleteMembers() throws {
        let job = try makePackageJob()
        materializeRequiredPackageMembers(in: job)
        let writer = DelayedPackageWriter()
        var readyCount = 0
        var terminalCount = 0
        var result: Result<URL, RecordingExportError>?
        XCTAssertEqual(job.lifecycle, .recording)
        XCTAssertTrue(job.beginPostprocessing())
        writer.finish { writerResult in
            result = job.finishPackageAfterWriter(writerResult) { terminalResult in
                terminalCount += 1
                if case .success = terminalResult { readyCount += 1 }
            }
        }

        XCTAssertNil(result)
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(terminalCount, 0)
        XCTAssertEqual(job.lifecycle, .postprocessing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.reservationURL.path))
        writer.complete(.success(()))

        XCTAssertEqual(try result?.get(), job.finalURL)
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(job.lifecycle, .terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
        _ = job.finishPackageAfterWriter(.success(())) { terminalResult in
            terminalCount += 1
            if case .success = terminalResult { readyCount += 1 }
        }
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(terminalCount, 1)
    }

    func testPackageWriterFailureCleansAllOwnedPathsWithoutBecomingReady() throws {
        let job = try makePackageJob()
        materializeRequiredPackageMembers(in: job)
        let writer = DelayedPackageWriter()
        let writerError = RecordingExportError.failed(stage: .first, message: "writer failed")
        var readyCount = 0
        var terminalCount = 0
        var result: Result<URL, RecordingExportError>?
        XCTAssertTrue(job.beginPostprocessing())
        writer.finish { writerResult in
            result = job.finishPackageAfterWriter(writerResult) { terminalResult in
                terminalCount += 1
                if case .success = terminalResult { readyCount += 1 }
            }
        }

        XCTAssertNil(result)
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(terminalCount, 0)
        XCTAssertEqual(job.lifecycle, .postprocessing)
        writer.complete(.failure(writerError))

        guard case .failure(let returnedError) = result else {
            return XCTFail("Writer failure must remain a typed failure.")
        }
        XCTAssertEqual(returnedError, writerError)
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(job.lifecycle, .terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.reservationURL.path))
    }

    func testPackageMembersMustBeNonemptyRegularFiles() throws {
        let emptyMemberJob = try makePackageJob()
        materialize(packageMember("info.json", in: emptyMemberJob), contents: "{}")
        materialize(packageMember("sys.m4a", in: emptyMemberJob), contents: "system audio")
        materialize(packageMember("mic.m4a", in: emptyMemberJob), contents: "")
        _ = emptyMemberJob.beginPostprocessing()
        let emptyResult = emptyMemberJob.finishPackageAfterWriter(.success(())) { result in
            if case .success = result { XCTFail("An empty required member must not become ready.") }
        }
        guard case .failure(.missingOutput(let emptyPath)) = emptyResult else {
            return XCTFail("An empty required member must fail validation.")
        }
        XCTAssertTrue(emptyPath.hasSuffix("mic.m4a"))

        let symlinkMemberJob = try makePackageJob()
        materialize(packageMember("info.json", in: symlinkMemberJob), contents: "{}")
        materialize(packageMember("sys.m4a", in: symlinkMemberJob), contents: "system audio")
        let externalAudio = temporaryDirectory.appendingPathComponent("external.m4a")
        materialize(externalAudio, contents: "external audio")
        try FileManager.default.createSymbolicLink(
            at: packageMember("mic.m4a", in: symlinkMemberJob),
            withDestinationURL: externalAudio
        )
        _ = symlinkMemberJob.beginPostprocessing()
        let symlinkResult = symlinkMemberJob.finishPackageAfterWriter(.success(())) { result in
            if case .success = result { XCTFail("A symlinked required member must not become ready.") }
        }
        guard case .failure(.missingOutput(let symlinkPath)) = symlinkResult else {
            return XCTFail("A symlinked required member must fail validation.")
        }
        XCTAssertTrue(symlinkPath.hasSuffix("mic.m4a"))
        XCTAssertEqual(try Data(contentsOf: externalAudio), Data("external audio".utf8))
    }

    func testWindowCaptureCompatibilityRemainsWindowOnly() throws {
        let source = try projectSource("QuickRecorder/RecordEngine.swift")

        XCTAssertTrue(source.contains("SCContext.streamType = .window"))
        XCTAssertTrue(source.contains("SCContentFilter(desktopIndependentWindow: includ[0])"))
    }

    func testCombinedAndSeparateAudioTrackCompatibilityRemainsAvailable() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let settingsSource = try projectSource("QuickRecorder/ViewModel/SettingsView.swift")

        XCTAssertTrue(appSource.contains("\"remuxAudio\": isMacOS12 ? false : true"))
        XCTAssertTrue(settingsSource.contains("SToggle(\"Record Microphone to Main Track\", isOn: $remuxAudio)"))
        XCTAssertTrue(engineSource.contains("remuxAudio && recordMic && recordWinSound"))
        XCTAssertTrue(engineSource.contains("? .videoRemux(fileExtension: fileEnding)"))
        XCTAssertTrue(engineSource.contains("SCContext.vW.add(SCContext.awInput)"))
        XCTAssertTrue(engineSource.contains("SCContext.vW.add(SCContext.micInput)"))
    }

    func testVideoContainerCodecAndQuickWindowCompatibilityRemainAvailable() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")
        let initVideoSource = try XCTUnwrap(
            engineSource.components(separatedBy: "func initVideo").last?
                .components(separatedBy: "func startMicRecording").first
        )

        XCTAssertTrue(appSource.contains("enum VideoFormat: String { case mov, mp4 }"))
        XCTAssertTrue(appSource.contains("enum Encoder: String { case h264, h265 }"))
        XCTAssertTrue(appSource.contains("prepRecord(type: \"window\", screens: SCContext.getSCDisplayWithMouse(), windows: [scWindow], applications: nil, fastStart: true)"))
        XCTAssertTrue(initVideoSource.contains("AVVideoCodecType.hevc"))
        XCTAssertTrue(initVideoSource.contains("AVVideoCodecType.h264"))
        XCTAssertTrue(initVideoSource.contains("shouldOptimizeForNetworkUse = true"))
        XCTAssertTrue(contextSource.contains("exportSession.shouldOptimizeForNetworkUse = true"))
        XCTAssertTrue(contextSource.contains("outputJob?.inputURL.path ?? filePath"))
        XCTAssertFalse(initVideoSource.contains("fastStart"))
    }

    func testRemuxCallbacksOwnOnlyJobURLs() throws {
        let contextSource = try projectSource("QuickRecorder/SCContext.swift")
        let remuxSource = try XCTUnwrap(
            contextSource.components(separatedBy: "static func mixAudioTracks(job:").last
        )

        XCTAssertTrue(remuxSource.contains("AVAsset(url: job.inputURL)"))
        XCTAssertTrue(remuxSource.contains("job.intermediateURLs.first"))
        XCTAssertTrue(remuxSource.contains("exportSession.outputURL = job.stagedOutputURL"))
        XCTAssertTrue(remuxSource.contains("job.finishExport(result, deliveringTo: completion)"))
        XCTAssertFalse(remuxSource.contains("filePath"))
    }

    private func makeRemuxJob() throws -> RecordingOutputJob {
        try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            prefix: "Recording at ",
            date: frozenDate,
            layout: .videoRemux(fileExtension: "mp4")
        )
    }

    private func makeVideoLayout(remuxEnabled: Bool) -> RecordingOutputJob.Layout {
        remuxEnabled ? .videoRemux(fileExtension: "mp4") : .single(fileExtension: "mp4")
    }

    private func makePackageJob() throws -> RecordingOutputJob {
        try RecordingOutputJob.reserve(
            in: temporaryDirectory,
            prefix: "Recording at ",
            date: frozenDate,
            layout: .package(
                fileExtension: "qma",
                requiredMembers: ["info.json", "sys.m4a", "mic.m4a"],
                automaticallyExports: true
            )
        )
    }

    private func packageMember(_ name: String, in job: RecordingOutputJob) -> URL {
        job.inputURL.appendingPathComponent(name)
    }

    private func materializeRequiredPackageMembers(in job: RecordingOutputJob) {
        materialize(packageMember("info.json", in: job), contents: "{}")
        materialize(packageMember("sys.m4a", in: job), contents: "system audio")
        materialize(packageMember("mic.m4a", in: job), contents: "microphone audio")
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func materialize(_ url: URL, contents: String) {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8)))
    }
}

private final class DelayedPackageWriter {
    private var completion: ((Result<Void, RecordingExportError>) -> Void)?

    func finish(_ completion: @escaping (Result<Void, RecordingExportError>) -> Void) {
        self.completion = completion
    }

    func complete(_ result: Result<Void, RecordingExportError>) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

private final class DelayedTwoStageExporter {
    private var firstCompletion: ((Result<Void, RecordingExportError>) -> Void)?
    private var secondCompletion: ((Result<Void, RecordingExportError>) -> Void)?

    func export(
        _ job: RecordingOutputJob,
        completion: @escaping (Result<URL, RecordingExportError>) -> Void
    ) {
        guard job.beginPostprocessing() else {
            _ = job.finishExport(
                .failure(.preparation(
                    stage: .first,
                    message: "The job is already terminal."
                )),
                deliveringTo: completion
            )
            return
        }
        firstCompletion = { [weak self] result in
            switch result {
            case .success:
                do {
                    try Data("first-stage output".utf8).write(to: job.intermediateURLs[0])
                } catch {
                    _ = job.finishExport(
                        .failure(.failed(
                            stage: .first,
                            message: error.localizedDescription
                        )),
                        deliveringTo: completion
                    )
                    return
                }
                self?.secondCompletion = { result in
                    switch result {
                    case .success:
                        do {
                            try Data("second-stage output".utf8).write(to: job.stagedOutputURL)
                            _ = job.finishExport(.success(()), deliveringTo: completion)
                        } catch {
                            _ = job.finishExport(
                                .failure(.failed(
                                    stage: .second,
                                    message: error.localizedDescription
                                )),
                                deliveringTo: completion
                            )
                        }
                    case .failure(let error):
                        _ = job.finishExport(.failure(error), deliveringTo: completion)
                    }
                }
            case .failure(let error):
                _ = job.finishExport(.failure(error), deliveringTo: completion)
            }
        }
    }

    func completeFirst(_ result: Result<Void, RecordingExportError>) {
        let completion = firstCompletion
        firstCompletion = nil
        completion?(result)
    }

    func completeSecond(_ result: Result<Void, RecordingExportError>) {
        let completion = secondCompletion
        secondCompletion = nil
        completion?(result)
    }
}

private final class ThreadSafeJobResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [Result<RecordingOutputJob, Error>]()

    var values: [Result<RecordingOutputJob, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ result: Result<RecordingOutputJob, Error>) {
        lock.lock()
        storage.append(result)
        lock.unlock()
    }
}
