import XCTest

final class TranscriptRendererTests: XCTestCase {

    private func transcript(_ segments: [TranscriptSegment], duration: TimeInterval = 30) -> Transcript {
        Transcript(
            segments: segments,
            locale: "en-US",
            sourceName: "sample.m4a",
            trackOrdinal: 0,
            duration: duration
        )
    }

    private func segment(_ text: String, start: TimeInterval, end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            text: text,
            start: start,
            end: end,
            words: [TranscribedWord(text: text, start: start, end: end)]
        )
    }

    private func render(_ format: OutputFormat, _ transcript: Transcript) -> String {
        TranscriptRenderer(format: format, limits: .default).render(transcript)
    }

    // MARK: - Timecodes

    func testSubRipUsesACommaBeforeMilliseconds() {
        XCTAssertEqual(TranscriptRenderer.subRipTimecode(2.58), "00:00:02,580")
        XCTAssertEqual(TranscriptRenderer.subRipTimecode(3661.5), "01:01:01,500")
    }

    func testWebVTTUsesAPeriodBeforeMilliseconds() {
        XCTAssertEqual(TranscriptRenderer.webVTTTimecode(2.58), "00:00:02.580")
        XCTAssertEqual(TranscriptRenderer.webVTTTimecode(3661.5), "01:01:01.500")
    }

    func testTimedTextTimecodeTruncatesRatherThanRounds() {
        // Rounding up would label a line with a time later than the words it marks.
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(2.9), "00:02")
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(59.999), "00:59")
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(3599.9), "59:59")
    }

    func testTimedTextTimecodeIsMinutesAndSecondsUnderAnHour() {
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(0), "00:00")
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(90), "01:30")
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(3599), "59:59")
    }

    func testTimedTextTimecodeAddsAZeroPaddedHourFromOneHourOn() {
        // Spotify documents HH:MM:SS but not H:MM:SS, so the hour is always two digits.
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(3600), "01:00:00")
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(3734), "01:02:14")
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(36000), "10:00:00")
    }

    func testTimecodesClampNonFiniteAndNegativeValues() {
        XCTAssertEqual(TranscriptRenderer.subRipTimecode(-5), "00:00:00,000")
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(-5), "00:00")
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(.nan), "00:00")
        XCTAssertEqual(TranscriptRenderer.timedTextTimecode(.infinity), "00:00")
    }

    // MARK: - Formats

    func testPlainTextIsOneLinePerSegment() {
        let output = render(.txt, transcript([
            segment("First line.", start: 0, end: 1),
            segment("Second line.", start: 2, end: 3),
        ]))
        XCTAssertEqual(output, "First line.\nSecond line.\n")
    }

    func testTimedTextPrefixesEachLineWithItsStart() {
        // No brackets or other punctuation between time and text: YouTube and Spotify both parse
        // `00:00 Title` lines as chapters, and Spotify allows at most one mark between the two.
        let output = render(.timed, transcript([
            segment("First line.", start: 0, end: 1),
            segment("Second line.", start: 62.4, end: 64),
            segment("Past the hour.", start: 3734.2, end: 3736),
        ], duration: 3740))
        XCTAssertEqual(output, "00:00 First line.\n01:02 Second line.\n01:02:14 Past the hour.\n")
    }

    func testSubRipNumbersCuesFromOne() {
        let output = render(.srt, transcript([
            segment("First.", start: 0, end: 1),
            segment("Second.", start: 2, end: 3),
        ]))
        XCTAssertTrue(output.hasPrefix("1\n00:00:00,000 --> 00:00:01,000\nFirst."), output)
        XCTAssertTrue(output.contains("2\n00:00:02,000 --> 00:00:03,000\nSecond."), output)
    }

    func testWebVTTStartsWithTheRequiredHeader() {
        let output = render(.vtt, transcript([segment("Only.", start: 0, end: 1)]))
        XCTAssertTrue(output.hasPrefix("WEBVTT\n\n"), output)
        XCTAssertTrue(output.contains("00:00:00.000 --> 00:00:01.000"), output)
    }

    func testJSONCarriesMetadataSegmentsAndWords() throws {
        let output = render(.json, transcript([segment("Hello.", start: 1.5, end: 2.5)]))
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsed["locale"] as? String, "en-US")
        XCTAssertEqual(parsed["source"] as? String, "sample.m4a")
        XCTAssertEqual(parsed["track"] as? Int, 0)

        let segments = try XCTUnwrap(parsed["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0]["text"] as? String, "Hello.")
        XCTAssertEqual(segments[0]["start"] as? Double, 1.5)

        let words = try XCTUnwrap(segments[0]["words"] as? [[String: Any]])
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0]["text"] as? String, "Hello.")
    }

    func testEveryFormatRendersAnEmptyTranscriptWithoutCrashing() throws {
        for format in OutputFormat.allCases {
            let output = render(format, transcript([]))
            switch format {
            case .txt, .timed, .srt:
                // Nothing was recognized, so there is nothing to write. An empty file is the
                // honest result and stays safe to concatenate or pipe.
                XCTAssertTrue(output.isEmpty, "\(format.rawValue) produced \(output.debugDescription)")
            case .vtt:
                // A WebVTT file without its header is malformed, so the header is emitted even with
                // no cues.
                XCTAssertTrue(output.hasPrefix("WEBVTT"), output)
            case .json:
                // Must stay parseable: a consumer piping into jq needs a document with an empty
                // segments array, not an empty file.
                let parsed = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
                )
                XCTAssertEqual(try XCTUnwrap(parsed["segments"] as? [Any]).count, 0)
            }
        }
    }

    func testOnlyTimelineFormatsRequestWordTimings() {
        XCTAssertFalse(OutputFormat.txt.needsWordTimings)
        XCTAssertFalse(OutputFormat.timed.needsWordTimings)
        XCTAssertTrue(OutputFormat.srt.needsWordTimings)
        XCTAssertTrue(OutputFormat.vtt.needsWordTimings)
        XCTAssertTrue(OutputFormat.json.needsWordTimings)
    }

    func testSubtitlesFallBackToSegmentsWhenWordTimingsAreAbsent() {
        // Without word timings there is nothing finer than the recognizer's own boundaries to split
        // on, so the segments must be used as-is rather than dropped.
        let noWords = TranscriptSegment(text: "No timings here.", start: 0, end: 4, words: [])
        let output = render(.srt, transcript([noWords]))
        XCTAssertTrue(output.contains("No timings here."), output)
        XCTAssertTrue(output.contains("00:00:00,000 --> 00:00:04,000"), output)
    }
}
