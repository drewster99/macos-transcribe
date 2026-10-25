import XCTest

final class TranscriptionStatusLineTests: XCTestCase {

    private func line(
        _ phase: TranscriptionStatusLine.Phase,
        processed: Duration,
        total: Duration?,
        elapsed: Duration
    ) -> String {
        TranscriptionStatusLine(
            phase: phase,
            processed: processed,
            total: total,
            elapsed: elapsed,
            toolVersion: "1.21.0"
        ).text
    }

    private let hourLong = Duration.seconds(4287)

    func testProgressLineLayout() {
        XCTAssertEqual(
            line(.transcribing, processed: .seconds(2777), total: hourLong, elapsed: .seconds(131)),
            "(MacOS Transcribe v1.21.0) TRANSCRIBING: 00:46:17 / 01:11:27 @ 21.2X speed -  64%"
        )
    }

    func testCompletionLineLayout() {
        XCTAssertEqual(
            line(.complete, processed: hourLong, total: hourLong, elapsed: .seconds(212)),
            "(MacOS Transcribe v1.21.0) COMPLETE:     01:11:27 / 01:11:27 @ 20.2X speed - 100%"
        )
    }

    func testCompletionLineAlignsWithTheProgressLineItReplaces() {
        let progress = line(.transcribing, processed: .seconds(60), total: hourLong, elapsed: .seconds(10))
        let complete = line(.complete, processed: hourLong, total: hourLong, elapsed: .seconds(200))
        XCTAssertEqual(progress.count, complete.count)
        XCTAssertEqual(progress.range(of: " / ")?.lowerBound.utf16Offset(in: progress),
                       complete.range(of: " / ")?.lowerBound.utf16Offset(in: complete))
    }

    func testPercentIsRoundedDownSoItNeverReadsFullEarly() {
        let nearlyDone = line(.transcribing, processed: .seconds(4286), total: hourLong, elapsed: .seconds(100))
        XCTAssertTrue(nearlyDone.hasSuffix(" -  99%"), nearlyDone)
    }

    func testPercentIsPaddedToThreeColumns() {
        let early = line(.transcribing, processed: .seconds(300), total: hourLong, elapsed: .seconds(100))
        XCTAssertTrue(early.hasSuffix(" -   6%"), early)
    }

    func testPercentIsClampedWhenPositionPassesTheReportedDuration() {
        let overrun = line(.transcribing, processed: .seconds(4300), total: hourLong, elapsed: .seconds(100))
        XCTAssertTrue(overrun.hasSuffix(" - 100%"), overrun)
    }

    func testSlowSpeedIsPaddedToKeepColumns() {
        let slow = line(.transcribing, processed: .seconds(8), total: hourLong, elapsed: .seconds(10))
        XCTAssertTrue(slow.contains(" @  0.8X speed "), slow)
    }

    func testSpeedIsWithheldUntilEnoughTimeHasPassedToMeanSomething() {
        let justStarted = line(.transcribing, processed: .seconds(30), total: hourLong, elapsed: .milliseconds(200))
        XCTAssertTrue(justStarted.contains(" @ --.-X speed "), justStarted)

        let zeroElapsed = line(.transcribing, processed: .zero, total: hourLong, elapsed: .zero)
        XCTAssertTrue(zeroElapsed.contains(" @ --.-X speed "), zeroElapsed)
    }

    func testCompletionShowsSpeedEvenForARunUnderASecond() {
        let quick = line(.complete, processed: .seconds(12), total: .seconds(12), elapsed: .milliseconds(400))
        XCTAssertTrue(quick.contains(" @ 30.0X speed "), quick)
    }

    func testCompletionWithNoElapsedTimeShowsNoSpeedRatherThanDividingByZero() {
        let instant = line(.complete, processed: .seconds(12), total: .seconds(12), elapsed: .zero)
        XCTAssertTrue(instant.contains(" @ --.-X speed "), instant)
    }

    func testUnknownDurationShowsNoTotalAndNoPercent() {
        XCTAssertEqual(
            line(.transcribing, processed: .seconds(90), total: nil, elapsed: .seconds(9)),
            "(MacOS Transcribe v1.21.0) TRANSCRIBING: 00:01:30 / --:--:-- @ 10.0X speed"
        )
    }

    func testZeroDurationIsTreatedAsUnknown() {
        let degenerate = line(.transcribing, processed: .seconds(5), total: .zero, elapsed: .seconds(5))
        XCTAssertFalse(degenerate.contains("%"), degenerate)
    }

    func testTimecodeCarriesPastTwentyFourHours() {
        XCTAssertEqual(TranscriptionStatusLine.timecode(.seconds(90061)), "25:01:01")
    }
}
