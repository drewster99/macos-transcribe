import CoreMedia
import Foundation

/// Keeps successive buffer start times from stepping backwards.
///
/// Decoders occasionally report a presentation timestamp a hair before where the previous buffer
/// ended, because `CMTime` values from a container's timescale do not always land exactly on the
/// output sample grid. The recognizer rejects audio whose timestamps regress, so those sub-frame
/// wobbles are snapped forward.
///
/// Genuine gaps are left alone in both directions. A forward gap is real silence, and a large
/// backward jump is a real fault in the file; moving either would shift every timestamp after it and
/// silently desynchronize the transcript from the media.
struct MonotonicBufferTimeline {

    let sampleRate: Double

    /// Where the next buffer is expected to begin, based on the previous one.
    private var expectedNextStart: CMTime?

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// The start time to use for a buffer, given what the decoder reported.
    ///
    /// - Parameters:
    ///   - presentationTime: The timestamp the decoder reported for this buffer.
    ///   - frameCount: How many frames the buffer holds, used to project the next expected start.
    mutating func startTime(for presentationTime: CMTime, frameCount: Int) -> CMTime {
        guard sampleRate > 0 else { return presentationTime }
        let timescale = CMTimeScale(sampleRate)
        var start = presentationTime

        if let expected = expectedNextStart, CMTimeCompare(presentationTime, expected) < 0 {
            let regression = CMTimeAbsoluteValue(CMTimeSubtract(expected, presentationTime))
            let oneFrame = CMTime(value: 1, timescale: timescale)
            if CMTimeCompare(regression, oneFrame) <= 0 {
                start = expected
            }
        }

        expectedNextStart = CMTimeAdd(start, CMTime(value: CMTimeValue(frameCount), timescale: timescale))
        return start
    }
}
