//
//  RecordingMediaChoiceTests.swift
//  QuickRecorderTests
//

import XCTest

final class RecordingMediaChoiceTests: XCTestCase {
    private struct MatrixCombination {
        let fastStart: Bool
        let systemAudio: Bool
        let microphone: Bool
    }

    /// All eight fastStart × systemAudio × microphone combinations.
    private var allCombinations: [MatrixCombination] {
        var combinations = [MatrixCombination]()
        for fastStart in [false, true] {
            for systemAudio in [false, true] {
                for microphone in [false, true] {
                    combinations.append(MatrixCombination(
                        fastStart: fastStart,
                        systemAudio: systemAudio,
                        microphone: microphone
                    ))
                }
            }
        }
        return combinations
    }

    // The screen and window entry points differ only in stream filter, never in
    // audio handling: both resolve one RecordingMediaChoice in prepRecord and the
    // shared record() path reads only that object. The matrix therefore covers
    // both entry points by exercising the resolution logic all of them share;
    // the tripwire tests below pin that sharing in the sources.

    func testMatrixHonorsExplicitSystemAudioChoiceInAllEightCombinations() {
        for combination in allCombinations {
            let choice = RecordingMediaChoice.resolve(
                systemAudioEnabled: combination.systemAudio,
                microphoneEnabled: combination.microphone,
                fastStart: combination.fastStart
            )
            XCTAssertEqual(
                choice.systemAudio,
                combination.systemAudio,
                "System audio must follow the explicit setting (fastStart=\(combination.fastStart), mic=\(combination.microphone))"
            )
            XCTAssertEqual(
                choice.capturesSystemAudio(audioOnly: false),
                combination.systemAudio,
                "Screen/window streams must capture system audio iff explicitly enabled (fastStart=\(combination.fastStart))"
            )
        }
    }

    func testMatrixHonorsExplicitMicrophoneChoiceInAllEightCombinations() {
        for combination in allCombinations {
            let choice = RecordingMediaChoice.resolve(
                systemAudioEnabled: combination.systemAudio,
                microphoneEnabled: combination.microphone,
                fastStart: combination.fastStart
            )
            XCTAssertEqual(
                choice.microphone,
                combination.microphone,
                "Microphone must follow the explicit setting (fastStart=\(combination.fastStart), sysAudio=\(combination.systemAudio))"
            )
        }
    }

    func testFastStartNeverChangesTheResolvedChoice() {
        for systemAudio in [false, true] {
            for microphone in [false, true] {
                let normal = RecordingMediaChoice.resolve(
                    systemAudioEnabled: systemAudio,
                    microphoneEnabled: microphone,
                    fastStart: false
                )
                let fast = RecordingMediaChoice.resolve(
                    systemAudioEnabled: systemAudio,
                    microphoneEnabled: microphone,
                    fastStart: true
                )
                XCTAssertEqual(normal, fast, "fastStart must have no effect on media choices")
            }
        }
    }

    func testBothSourcesResolveWhenBothAreEnabled() {
        for fastStart in [false, true] {
            let choice = RecordingMediaChoice.resolve(
                systemAudioEnabled: true,
                microphoneEnabled: true,
                fastStart: fastStart
            )
            XCTAssertTrue(choice.systemAudio)
            XCTAssertTrue(choice.microphone)
            XCTAssertTrue(choice.capturesSystemAudio(audioOnly: false))
        }
    }

    func testAudioOnlySessionsAlwaysCaptureSystemAudio() {
        for combination in allCombinations {
            let choice = RecordingMediaChoice.resolve(
                systemAudioEnabled: combination.systemAudio,
                microphoneEnabled: combination.microphone,
                fastStart: combination.fastStart
            )
            XCTAssertTrue(choice.capturesSystemAudio(audioOnly: true))
        }
    }

    // MARK: - Source tripwires binding the engine to the immutable choice

    func testRecordEngineResolvesOneChoiceAtTheSharedStartPath() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")

        XCTAssertTrue(engineSource.contains("RecordingMediaChoice.resolve("))
        XCTAssertTrue(engineSource.contains("systemAudioEnabled: recordWinSound"))
        XCTAssertTrue(engineSource.contains("microphoneEnabled: recordMic"))
        XCTAssertEqual(
            engineSource.components(separatedBy: "RecordingMediaChoice.resolve(").count - 1,
            1,
            "All start paths must share the single resolve point in prepRecord"
        )
    }

    func testRecordPathReadsAudioDecisionsOnlyFromTheImmutableChoice() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let recordSource = try sourceSlice(
            engineSource,
            after: "func record(",
            before: "private func discardCaptureAfterFailedStart"
        )

        XCTAssertTrue(recordSource.contains("conf.capturesAudio = mediaChoice.capturesSystemAudio(audioOnly: audioOnly)"))
        XCTAssertTrue(recordSource.contains("if mediaChoice.microphone { try startMicRecording(session: session) }"))
        XCTAssertTrue(recordSource.contains("microphoneInput: mediaChoice.microphone ? SCContext.micInput : nil"))
        XCTAssertFalse(recordSource.contains("fastStart ||"), "fastStart must not feed any decision expression")
        XCTAssertFalse(recordSource.contains("|| fastStart"), "fastStart must not feed any decision expression")
        XCTAssertFalse(recordSource.contains("recordWinSound"), "record() must not re-read the mutable system-audio setting")
        XCTAssertFalse(recordSource.contains("recordMic"), "record() must not re-read the mutable microphone setting")
    }

    func testWriterConfigurationFollowsTheImmutableChoice() throws {
        let engineSource = try projectSource("QuickRecorder/RecordEngine.swift")
        let initVideoSource = try sourceSlice(
            engineSource,
            after: "func initVideo",
            before: "func startMicRecording"
        )
        let prepareAudioSource = try sourceSlice(
            engineSource,
            after: "func prepareAudioRecording",
            before: "extension NSScreen"
        )

        XCTAssertTrue(initVideoSource.contains("remuxAudio && mediaChoice.microphone && mediaChoice.systemAudio"))
        XCTAssertTrue(initVideoSource.contains("recordsMicrophone: mediaChoice.microphone"))
        XCTAssertTrue(initVideoSource.contains("if mediaChoice.microphone {"))
        XCTAssertFalse(initVideoSource.contains("recordMic"))
        XCTAssertFalse(initVideoSource.contains("recordWinSound"))
        XCTAssertTrue(prepareAudioSource.contains("if mediaChoice.microphone && SCContext.streamType == .systemaudio"))
    }

    func testQuickStartPathsShareThePrepRecordEntryWithTheSelectors() throws {
        let appSource = try projectSource("QuickRecorder/QuickRecorderApp.swift")
        let screenSelectorSource = try projectSource("QuickRecorder/ViewModel/ScreenSelector.swift")
        let windowSelectorSource = try projectSource("QuickRecorder/ViewModel/WinSelector.swift")

        // Quick-current-screen and quick-topmost enter through the same
        // prepRecord as the normal selectors; only prepRecord resolves media.
        XCTAssertTrue(appSource.contains("prepRecord(type: \"display\", screens: SCContext.getSCDisplayWithMouse(), windows: nil, applications: nil, fastStart: true)"))
        XCTAssertTrue(appSource.contains("fastStart: true,"))
        XCTAssertTrue(screenSelectorSource.contains("prepRecord(type: \"display\""))
        XCTAssertTrue(windowSelectorSource.contains("prepRecord("))
        XCTAssertFalse(appSource.contains("RecordingMediaChoice"), "Start paths must not resolve their own media choices")
        XCTAssertFalse(screenSelectorSource.contains("RecordingMediaChoice"), "Start paths must not resolve their own media choices")
        XCTAssertFalse(windowSelectorSource.contains("RecordingMediaChoice"), "Start paths must not resolve their own media choices")
    }

    // MARK: - Helpers

    private func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceSlice(
        _ source: String,
        after startMarker: String,
        before endMarker: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let startRange = try XCTUnwrap(
            source.range(of: startMarker),
            "Missing source marker: \(startMarker)",
            file: file,
            line: line
        )
        let remainder = source[startRange.upperBound...]
        let endRange = try XCTUnwrap(
            remainder.range(of: endMarker),
            "Missing source marker after \(startMarker): \(endMarker)",
            file: file,
            line: line
        )
        return String(remainder[..<endRange.lowerBound])
    }
}
