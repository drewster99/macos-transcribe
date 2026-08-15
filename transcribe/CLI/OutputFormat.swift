import ArgumentParser

/// The serialization used for the finished transcript.
enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
    /// One line per finalized recognition result. The default: newline-delimited text is what the
    /// rest of the Unix toolchain expects.
    case txt
    /// SubRip subtitles, cue-segmented from word timings.
    case srt
    /// WebVTT subtitles, cue-segmented from word timings.
    case vtt
    /// Metadata, segments, and per-word timings.
    case json

    /// Whether this format positions text against the media timeline, and therefore needs per-word
    /// audio time ranges collected during transcription.
    var needsWordTimings: Bool {
        switch self {
        case .txt: false
        case .srt, .vtt, .json: true
        }
    }

    /// The file extension conventionally used for this format, without a leading dot.
    var fileExtension: String { rawValue }
}

/// Which audio track to transcribe when the input carries more than one.
///
/// This is an enum rather than a pair of booleans because the three states are mutually exclusive
/// and each implies different reporting: only `.defaultTrack` warns about tracks it skipped.
enum TrackSelection: Equatable {
    /// No track flag was given. Uses the first audio track, and warns when others exist.
    case defaultTrack
    /// `--first-track`: use the first audio track, and stay quiet about the others.
    case firstTrackExplicitly
    /// `--track N`: use the audio track at this zero-based index.
    case index(Int)

    /// The zero-based index of the audio track to read, given how many the file has.
    ///
    /// Returns nil when the requested index is out of range, so the caller can report the actual
    /// track count rather than clamping to something the user did not ask for.
    func resolvedIndex(audioTrackCount: Int) -> Int? {
        switch self {
        case .defaultTrack, .firstTrackExplicitly:
            return audioTrackCount > 0 ? 0 : nil
        case .index(let requested):
            return (0..<audioTrackCount).contains(requested) ? requested : nil
        }
    }

    /// Whether skipped tracks should be reported to the user.
    var warnsAboutUnselectedTracks: Bool { self == .defaultTrack }
}
