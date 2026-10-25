import Foundation

/// Serializes a transcript in the requested format.
struct TranscriptRenderer {

    let format: OutputFormat
    let limits: TranscriptSegmenter.Limits

    func render(_ transcript: Transcript) -> String {
        switch format {
        case .txt: renderPlainText(transcript)
        case .timed: renderTimedText(transcript)
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

    /// One line per result, prefixed with the time it starts.
    ///
    /// The line shape is the one YouTube and Spotify parse as chapters, so any line can be pasted
    /// into an episode description as-is. Nothing sits between the time and the text, because
    /// Spotify allows at most one punctuation mark there and YouTube expects none.
    private func renderTimedText(_ transcript: Transcript) -> String {
        guard !transcript.isEmpty else { return "" }
        return transcript.segments
            .map { "\(Self.timedTextTimecode($0.start)) \($0.text)" }
            .joined(separator: "\n") + "\n"
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

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            // Every field is a String, Double, or array of those, so this cannot fail for any input
            // the program can produce. Reaching it means the payload types changed into something
            // unencodable, which is a programming error rather than a runtime condition.
            fatalError("Transcript JSON encoding failed: \(error)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            fatalError("JSONEncoder produced output that is not valid UTF-8")
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

    /// `MM:SS` under an hour, `HH:MM:SS` from an hour on, truncated rather than rounded so the label
    /// never points past the words it marks.
    ///
    /// Both are formats Spotify documents for description chapters and YouTube parses. The hour is
    /// zero-padded because Spotify lists `HH:MM:SS` but not `H:MM:SS`.
    static func timedTextTimecode(_ seconds: TimeInterval) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(clamped)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let wholeSeconds = total % 60
        guard hours > 0 else { return String(format: "%02d:%02d", minutes, wholeSeconds) }
        return String(format: "%02d:%02d:%02d", hours, minutes, wholeSeconds)
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
