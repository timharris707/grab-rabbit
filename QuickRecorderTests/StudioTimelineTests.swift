import CoreMedia
import Foundation
import XCTest

final class StudioTimelineTests: XCTestCase {
    func testElapsedTimeIsZeroAtTheStartOfTheTimeline() {
        let clock = StudioTestClock()
        let timeline = StudioTimeline(clock: clock)

        XCTAssertEqual(timeline.activeElapsedSeconds(), 0, accuracy: 1e-9)
    }

    func testElapsedTimeFollowsTheInjectedClock() {
        let clock = StudioTestClock()
        let timeline = StudioTimeline(clock: clock)

        clock.advance(seconds: 2.5)

        XCTAssertEqual(timeline.activeElapsedSeconds(), 2.5, accuracy: 1e-6)
    }

    func testPausedTimeIsSubtractedFromTheWallClock() {
        let clock = StudioTestClock()
        let timeline = StudioTimeline(clock: clock)

        clock.advance(seconds: 1)
        timeline.setPaused(true)
        clock.advance(seconds: 10)
        timeline.setPaused(false)
        clock.advance(seconds: 1)

        XCTAssertEqual(timeline.activeElapsedSeconds(), 2, accuracy: 1e-6)
    }

    func testElapsedTimeStandsStillWhilePaused() {
        let clock = StudioTestClock()
        let timeline = StudioTimeline(clock: clock)

        clock.advance(seconds: 1)
        timeline.setPaused(true)
        let atPause = timeline.activeElapsedSeconds()
        clock.advance(seconds: 5)

        XCTAssertEqual(timeline.activeElapsedSeconds(), atPause, accuracy: 1e-6)
        XCTAssertTrue(timeline.isPaused)
    }

    func testTimelineNeverMovesBackwardsAcrossRepeatedPauses() {
        let clock = StudioTestClock()
        let timeline = StudioTimeline(clock: clock)
        var readings = [Double]()

        for _ in 0..<5 {
            clock.advance(seconds: 0.5)
            readings.append(timeline.activeElapsedSeconds())
            timeline.setPaused(true)
            clock.advance(seconds: 3)
            readings.append(timeline.activeElapsedSeconds())
            timeline.setPaused(false)
            readings.append(timeline.activeElapsedSeconds())
        }

        XCTAssertEqual(readings, readings.sorted())
        XCTAssertEqual(timeline.activeElapsedSeconds(), 2.5, accuracy: 1e-6)
    }

    func testRedundantPauseAndResumeRequestsAreIgnored() {
        let clock = StudioTestClock()
        let timeline = StudioTimeline(clock: clock)

        XCTAssertFalse(timeline.setPaused(false))
        XCTAssertTrue(timeline.setPaused(true))
        XCTAssertFalse(timeline.setPaused(true))
        clock.advance(seconds: 4)
        XCTAssertTrue(timeline.setPaused(false))
        clock.advance(seconds: 1)

        XCTAssertEqual(timeline.activeElapsedSeconds(), 1, accuracy: 1e-6)
    }

    func testPresentationTimeUsesTheSixtyThousandTimescale() {
        let time = StudioTimeline.presentationTime(seconds: 1.5)

        XCTAssertEqual(StudioTimeline.timescale, 60_000)
        XCTAssertEqual(time.timescale, 60_000)
        XCTAssertEqual(time.value, 90_000)
    }

    func testFixedClockIntervalMatchesTheRequestedFrameRate() {
        XCTAssertEqual(StudioFixedClockSchedule.interval(framesPerSecond: 60), 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(StudioFixedClockSchedule.interval(framesPerSecond: 30), 1.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(StudioFixedClockSchedule.interval(framesPerSecond: 0), 1.0, accuracy: 1e-12)
    }

    func testFixedClockLeewayIsOneMillisecond() {
        XCTAssertEqual(StudioFixedClockSchedule.leeway, DispatchTimeInterval.milliseconds(1))
    }

    func testRetimeMovesTheBufferToTheRequestedWallClockSecond() throws {
        let sample = try StudioTestBuffers.makeAudioSample(sampleCount: 8, startSeconds: 123.5)

        let retimed = try XCTUnwrap(StudioAudioRetimer.retime(sample, toSeconds: 2))

        XCTAssertEqual(retimed.presentationTimeStamp.seconds, 2, accuracy: 1e-6)
        XCTAssertEqual(retimed.presentationTimeStamp.timescale, StudioTimeline.timescale)
    }

    func testRetimePreservesIntraBufferSampleOffsets() throws {
        let sampleCount = 16
        let sample = try StudioTestBuffers.makeAudioSample(
            sampleCount: sampleCount,
            startSeconds: 40
        )
        let original = try StudioTestBuffers.timingEntries(of: sample)

        let retimed = try XCTUnwrap(StudioAudioRetimer.retime(sample, toSeconds: 0.25))
        let adjusted = try StudioTestBuffers.timingEntries(of: retimed)

        XCTAssertEqual(adjusted.count, original.count)
        XCTAssertEqual(CMSampleBufferGetNumSamples(retimed), sampleCount)
        for index in original.indices {
            let originalOffset = original[index].presentationTimeStamp - original[0].presentationTimeStamp
            let adjustedOffset = adjusted[index].presentationTimeStamp - adjusted[0].presentationTimeStamp
            XCTAssertEqual(
                adjustedOffset.seconds,
                originalOffset.seconds,
                accuracy: 1e-9,
                "sample \(index) lost its offset inside the buffer"
            )
            XCTAssertEqual(adjusted[index].duration, original[index].duration)
        }
    }

    func testRetimedAudioStaysMonotonicAcrossPauseAndResume() throws {
        let clock = StudioTestClock()
        let timeline = StudioTimeline(clock: clock)
        var times = [CMTime]()

        for step in 0..<3 {
            clock.advance(seconds: 0.1)
            let sample = try StudioTestBuffers.makeAudioSample(
                sampleCount: 4,
                startSeconds: Double(step) * 7
            )
            let seconds = timeline.activeElapsedSeconds()
            times.append(try XCTUnwrap(StudioAudioRetimer.retime(sample, toSeconds: seconds))
                .presentationTimeStamp)
            if step == 0 {
                timeline.setPaused(true)
                clock.advance(seconds: 30)
                timeline.setPaused(false)
            }
        }

        XCTAssertEqual(times.map(\.seconds), times.map(\.seconds).sorted())
        XCTAssertEqual(times.last?.seconds ?? -1, 0.3, accuracy: 1e-6)
    }

    func testRetimeHandlesABufferCarryingASingleTimingEntry() throws {
        let sample = try StudioTestBuffers.makeAudioSample(sampleCount: 1, startSeconds: 9)

        let retimed = try XCTUnwrap(StudioAudioRetimer.retime(sample, toSeconds: 0.5))

        XCTAssertEqual(try StudioTestBuffers.timingEntries(of: retimed).count, 1)
        XCTAssertEqual(retimed.presentationTimeStamp.seconds, 0.5, accuracy: 1e-6)
    }

    // The shape a real audio capture callback delivers: a long run of samples
    // described by one timing entry. Reading the entry count as the sample count
    // hands Core Media a mostly zeroed timing array, and the buffer that comes back
    // has no usable duration. This test is the guard on that.
    func testRetimeKeepsTheDurationOfACaptureShapedBuffer() throws {
        let sampleCount = 1024
        let sampleRate = 48_000.0
        let sample = try StudioTestBuffers.makeAudioSample(
            sampleCount: sampleCount,
            startSeconds: 300,
            sampleRate: sampleRate,
            timingEntryCount: 1
        )
        XCTAssertEqual(try StudioTestBuffers.timingEntries(of: sample).count, 1)

        let retimed = try XCTUnwrap(StudioAudioRetimer.retime(sample, toSeconds: 2))

        let duration = CMSampleBufferGetDuration(retimed)
        XCTAssertTrue(duration.isValid, "the retimed buffer lost a valid duration")
        XCTAssertTrue(duration.isNumeric, "the retimed buffer duration is not a number")
        XCTAssertFalse(duration.seconds.isNaN, "the retimed buffer duration is NaN")
        XCTAssertEqual(duration.seconds, Double(sampleCount) / sampleRate, accuracy: 1e-9)
        XCTAssertEqual(CMSampleBufferGetNumSamples(retimed), sampleCount)
        XCTAssertEqual(retimed.presentationTimeStamp.seconds, 2, accuracy: 1e-6)
    }
}
