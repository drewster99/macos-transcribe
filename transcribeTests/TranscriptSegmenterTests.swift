import XCTest

final class TranscriptSegmenterTests: XCTestCase {

    private let limits = TranscriptSegmenter.Limits.default

    /// Builds evenly spaced words, each `duration` long with `gap` of silence after it.
    private func words(_ texts: [String], duration: TimeInterval = 0.3, gap: TimeInterval = 0.05) -> [TranscribedWord] {
        var result: [TranscribedWord] = []
        var cursor: TimeInterval = 0
        for text in texts {
            result.append(TranscribedWord(text: text, start: cursor, end: cursor + duration))
            cursor += duration + gap
        }
        return result
    }

    func testEmptyInputProducesNoCues() {
        XCTAssertTrue(TranscriptSegmenter.makeCues(from: [], limits: limits).isEmpty)
    }

    func testSentencePunctuationEndsACue() {
        let cues = TranscriptSegmenter.makeCues(from: words(["Hello", "there.", "Next", "one."]), limits: limits)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello there.")
        XCTAssertEqual(cues[1].text, "Next one.")
    }

    func testClosingQuoteAfterPunctuationStillEndsACue() {
        let cues = TranscriptSegmenter.makeCues(from: words(["\"Stop.\"", "Then", "go."]), limits: limits)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "\"Stop.\"")
    }

    func testDecimalPointInsideAWordDoesNotEndACue() {
        // "3.5" ends with a digit, not punctuation, so it must not be treated as a sentence end.
        let cues = TranscriptSegmenter.makeCues(from: words(["about", "3.5", "seconds"]), limits: limits)
        XCTAssertEqual(cues.count, 1)
    }

    func testLongPauseEndsACue() {
        var spoken = words(["one", "two"], gap: 0.05)
        // A gap at or beyond pauseGap after "two".
        spoken.append(TranscribedWord(text: "three", start: spoken[1].end + limits.pauseGap, end: spoken[1].end + limits.pauseGap + 0.3))
        let cues = TranscriptSegmenter.makeCues(from: spoken, limits: limits)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "one two")
    }

    func testHardWordCapBoundsCueLength() {
        // No punctuation and no pauses: only the caps can end a cue. Without them a recognition run
        // that returns unpunctuated text would become one cue as long as the recording.
        let unpunctuated = words(Array(repeating: "word", count: 60), duration: 0.05, gap: 0.0)
        let cues = TranscriptSegmenter.makeCues(from: unpunctuated, limits: limits)
        XCTAssertFalse(cues.isEmpty)
        for cue in cues {
            XCTAssertLessThanOrEqual(cue.words.count, limits.hardWordCap)
        }
    }

    func testMaximumCueDurationBoundsCueSpan() {
        let long = words(Array(repeating: "word", count: 40), duration: 1.0, gap: 0.0)
        let cues = TranscriptSegmenter.makeCues(from: long, limits: limits)
        for cue in cues {
            // One word can exceed the limit on its own; the cue must not keep growing past it.
            XCTAssertLessThanOrEqual(cue.end - cue.start, limits.maximumCueDuration + 1.0)
        }
    }

    func testEveryWordSurvivesSegmentation() {
        let spoken = words(["alpha", "bravo.", "charlie", "delta", "echo.", "foxtrot"])
        let cues = TranscriptSegmenter.makeCues(from: spoken, limits: limits)
        XCTAssertEqual(cues.flatMap(\.words).map(\.text), spoken.map(\.text))
    }

    func testCueBoundsMatchItsWords() {
        let cues = TranscriptSegmenter.makeCues(from: words(["one", "two."]), limits: limits)
        let cue = try? XCTUnwrap(cues.first)
        XCTAssertEqual(cue?.start, cues.first?.words.first?.start)
        XCTAssertEqual(cue?.end, cues.first?.words.last?.end)
    }

    func testOverridingKeepsSoftCapBelowHardCap() {
        // A soft cap at or above the hard cap could never fire, silently disabling pause-based
        // splitting for anyone who lowered --max-words-per-cue.
        let tightened = limits.overriding(maximumCueDuration: 3.0, hardWordCap: 4)
        XCTAssertLessThan(tightened.softWordCap, tightened.hardWordCap)
        XCTAssertEqual(tightened.maximumCueDuration, 3.0)
        XCTAssertEqual(tightened.hardWordCap, 4)
    }

    func testOverridingWithHardCapOfOneStaysValid() {
        let extreme = limits.overriding(maximumCueDuration: 1.0, hardWordCap: 1)
        XCTAssertGreaterThanOrEqual(extreme.softWordCap, 1)
        let cues = TranscriptSegmenter.makeCues(from: words(["a", "b", "c"]), limits: extreme)
        XCTAssertEqual(cues.count, 3)
    }
}
