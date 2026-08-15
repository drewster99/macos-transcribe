import Foundation

/// Serializes a transcript in the requested format.
struct TranscriptRenderer {

    let format: OutputFormat
    let limits: TranscriptSegmenter.Limits

    func render(_ transcript: Transcript) -> String {
        switch format {
        case .txt: renderPlainText(transcript)
        case .srt: renderSubRip(transcript)
        case .vtt: renderWebVTT(transcript)
        case .json: renderJSON(transcript)
        }
    }

    // MARK: - Plain text

    /// One line per finalized recognition result.
    ///
    /// Result boundaries are kept rather than re-segmented: they are roughly utterance-sized, and
    /// newline-delimited output is what the rest of the Unix toolchain expects from a text stream.
    private func renderPlainText(_ transcript: Transcript) -> String {
        guard !transcript.isEmpty else { return "" }
        return transcript.segments.map(\.text).joined(separator: "\n") + "\n"
    }

    // MARK: - Subtitles

    private func renderSubRip(_ transcript: Transcript) -> String {
        let cues = subtitleCues(for: transcript)
        guard !cues.isEmpty else { return "" }

        return cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(Self.subRipTimecode(cue.start)) --> \(Self.subRipTimecode(cue.end))
            \(cue.text)

            """
        }.joined()
    }

    private func renderWebVTT(_ transcript: Transcript) -> String {
        let cues = subtitleCues(for: transcript)
        let body = cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(Self.webVTTTimecode(cue.start)) --> \(Self.webVTTTimecode(cue.end))
            \(cue.text)

            """
        }.joined()
        return "WEBVTT\n\n" + body
    }

    /// Cues for subtitle output.
    ///
    /// Word timings drive the segmentation when present. Without them there is nothing finer than
    /// the recognizer's own result boundaries to split on, so those are used as-is rather than
    /// inventing timings.
    private func subtitleCues(for transcript: Transcript) -> [TranscriptSegment] {
        let words = transcript.allWords
        guard !words.isEmpty else { return transcript.segments }
        return TranscriptSegmenter.makeCues(from: words, limits: limits)
    }

    // MARK: - JSON

    private func renderJSON(_ transcript: Transcript) -> String {
        let payload = TranscriptPayload(
            source: transcript.sourceName,
            locale: transcript.locale,
            track: transcript.trackOrdinal,
            duration: transcript.duration,
            segments: transcript.segments.map { segment in
                SegmentPayload(
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    words: segment.words.map {
                        WordPayload(start: $0.start, end: $0.end, text: $0.text)
                    }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            // Every field is a String, Double, or array of the same, so encoding cannot fail for
            // any input this program can produce.
            fatalError("Transcript JSON encoding failed for a payload of plain values")
        }
        return text + "\n"
    }

    // MARK: - Timecodes

    /// `HH:MM:SS,mmm` — SubRip uses a comma before the milliseconds.
    static func subRipTimecode(_ seconds: TimeInterval) -> String {
        timecode(seconds, millisecondSeparator: ",")
    }

    /// `HH:MM:SS.mmm` — WebVTT uses a period.
    static func webVTTTimecode(_ seconds: TimeInterval) -> String {
        timecode(seconds, millisecondSeparator: ".")
    }

    private static func timecode(_ seconds: TimeInterval, millisecondSeparator: String) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let wholeSeconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d\(millisecondSeparator)%03d",
                      hours, minutes, wholeSeconds, milliseconds)
    }
}

// MARK: - JSON shape

private struct TranscriptPayload: Encodable {
    let source: String
    let locale: String
    let track: Int
    let duration: TimeInterval
    let segments: [SegmentPayload]
}

private struct SegmentPayload: Encodable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let words: [WordPayload]
}

private struct WordPayload: Encodable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}
