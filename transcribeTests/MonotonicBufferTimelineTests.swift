import CoreMedia
import XCTest

final class MonotonicBufferTimelineTests: XCTestCase {

    private let sampleRate: Double = 16000

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: CMTimeScale(sampleRate))
    }

    private func frames(_ count: Int) -> CMTime {
        CMTime(value: CMTimeValue(count), timescale: CMTimeScale(sampleRate))
    }

    func testTimestampsAlreadyInOrderPassThroughUnchanged() {
        var timeline = MonotonicBufferTimeline(sampleRate: sampleRate)
        let first = timeline.startTime(for: .zero, frameCount: 1600)
        let second = timeline.startTime(for: time(0.1), frameCount: 1600)
        XCTAssertEqual(first, .zero)
        XCTAssertEqual(second, time(0.1))
    }

    func testSubFrameRegressionIsSnappedForward() {
        var timeline = MonotonicBufferTimeline(sampleRate: sampleRate)
        _ = timeline.startTime(for: .zero, frameCount: 1600)

        // Half a frame earlier than where the previous buffer ended: container rounding, not a real
        // seek backwards.
        let expectedNext = frames(1600)
        let halfFrameEarly = CMTimeSubtract(expectedNext, CMTime(value: 1, timescale: CMTimeScale(sampleRate * 2)))

        let corrected = timeline.startTime(for: halfFrameEarly, frameCount: 1600)
        XCTAssertEqual(corrected, expectedNext, "a sub-frame wobble should be snapped to the expected start")
    }

    func testExactlyOneFrameOfRegressionIsStillSnapped() {
        var timeline = MonotonicBufferTimeline(sampleRate: sampleRate)
        _ = timeline.startTime(for: .zero, frameCount: 1600)

        let expectedNext = frames(1600)
        let oneFrameEarly = CMTimeSubtract(expectedNext, frames(1))
        XCTAssertEqual(timeline.startTime(for: oneFrameEarly, frameCount: 1600), expectedNext)
    }

    func testLargeBackwardJumpIsPassedThrough() {
        var timeline = MonotonicBufferTimeline(sampleRate: sampleRate)
        _ = timeline.startTime(for: time(10), frameCount: 1600)

        // A real fault in the file, not rounding. Silently moving it would hide the problem and
        // shift every timestamp after it.
        let wayBack = time(2)
        XCTAssertEqual(timeline.startTime(for: wayBack, frameCount: 1600), wayBack)
    }

    func testForwardGapIsPreserved() {
        var timeline = MonotonicBufferTimeline(sampleRate: sampleRate)
        _ = timeline.startTime(for: .zero, frameCount: 1600)

        // Real silence. Closing the gap would desynchronize everything that follows.
        let afterSilence = time(5)
        XCTAssertEqual(timeline.startTime(for: afterSilence, frameCount: 1600), afterSilence)
    }

    func testOutputNeverRegressesAcrossAWobblyStream() {
        var timeline = MonotonicBufferTimeline(sampleRate: sampleRate)
        var previous = CMTime.negativeInfinity
        var cursor = CMTime.zero

        for index in 0..<200 {
            // Alternate a half-frame early and a half-frame late around the true position.
            let wobble = CMTime(value: 1, timescale: CMTimeScale(sampleRate * 2))
            let reported = index.isMultiple(of: 2)
                ? CMTimeSubtract(cursor, wobble)
                : CMTimeAdd(cursor, wobble)

            let start = timeline.startTime(for: reported, frameCount: 512)
            XCTAssertGreaterThanOrEqual(CMTimeCompare(start, previous), 0, "buffer \(index) went backwards")
            previous = start
            cursor = CMTimeAdd(cursor, frames(512))
        }
    }

    func testZeroSampleRateLeavesTimestampsAlone() {
        // A degenerate format cannot define a frame duration, so there is nothing to snap to and the
        // decoder's own timestamps are the best available answer.
        var timeline = MonotonicBufferTimeline(sampleRate: 0)
        XCTAssertEqual(timeline.startTime(for: time(3), frameCount: 100), time(3))
        XCTAssertEqual(timeline.startTime(for: time(1), frameCount: 100), time(1))
    }

    func testFirstBufferIsNeverAdjusted() {
        var timeline = MonotonicBufferTimeline(sampleRate: sampleRate)
        // A non-zero start is normal for audio positioned by an edit list.
        XCTAssertEqual(timeline.startTime(for: time(3), frameCount: 1600), time(3))
    }
}
