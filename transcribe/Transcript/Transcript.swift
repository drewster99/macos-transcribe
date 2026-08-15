import CoreMedia
import Foundation

/// One recognized word and the span of audio it came from.
struct TranscribedWord: Sendable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

/// A contiguous run of words treated as one unit of output: a line of plain text, or one subtitle
/// cue.
struct TranscriptSegment: Sendable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let words: [TranscribedWord]
}

/// A finished transcript and the context needed to describe where it came from.
struct Transcript: Sendable {
    let segments: [TranscriptSegment]
    let locale: String
    let sourceName: String
    let trackOrdinal: Int
    let duration: TimeInterval

    var isEmpty: Bool { segments.isEmpty }

    /// Every word across all segments, in order.
    var allWords: [TranscribedWord] { segments.flatMap(\.words) }
}

extension CMTime {
    /// Seconds, or nil when the time is indefinite, infinite, or invalid.
    ///
    /// Speech results and container metadata can both carry non-numeric times; converting them
    /// blindly yields NaN, which then propagates silently into timestamps and JSON output.
    var numericSeconds: TimeInterval? {
        guard isNumeric else { return nil }
        let value = seconds
        return value.isFinite ? value : nil
    }
}
