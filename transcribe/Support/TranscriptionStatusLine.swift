import Foundation

/// The text of one transcription status line, either the live progress indicator or the summary
/// written once the transcript is complete.
///
/// Kept separate from `StderrReporter` so the layout can be tested without a terminal, and takes
/// the tool version as a value so tests do not depend on the plist embedded in the binary.
struct TranscriptionStatusLine {

    enum Phase {
        case transcribing
        case complete

        var label: String {
            switch self {
            case .transcribing: "TRANSCRIBING:"
            case .complete: "COMPLETE:"
            }
        }
    }

    let phase: Phase

    /// How far into the media the analyzer has been fed.
    let processed: Duration

    /// Total media duration, or nil when the file does not report a usable one.
    let total: Duration?

    /// Wall-clock time since transcription began.
    let elapsed: Duration

    let toolVersion: String

    /// Below this much wall-clock time, a live speed is mostly noise from the first buffers arriving
    /// before the analyzer has settled into its pace, and can read as hundreds of times realtime.
    /// The closing summary is exempt: by then the figure covers the whole run and is exact.
    static let minimumElapsedForLiveSpeed = Duration.seconds(1)

    /// The labels are padded to one width so the timecodes of the final line sit directly under
    /// those of the progress line it replaces.
    private static let labelWidth = max(Phase.transcribing.label.count, Phase.complete.label.count)

    var text: String {
        let paddedLabel = phase.label.padding(toLength: Self.labelWidth, withPad: " ", startingAt: 0)
        let position = "\(Self.timecode(processed)) / \(total.map(Self.timecode) ?? "--:--:--")"
        let prefix = "(MacOS Transcribe v\(toolVersion)) \(paddedLabel) \(position) @ \(speedText) speed"
        // Without a duration there is no denominator, and inventing one would be a wrong number.
        guard let percent = percentComplete else { return prefix }
        return prefix + String(format: " - %3d%%", percent)
    }

    /// Media time processed per unit of wall-clock time, formatted like `21.2X`.
    var speedText: String {
        let hasMeaningfulSpeed = switch phase {
        case .transcribing: elapsed >= Self.minimumElapsedForLiveSpeed
        case .complete: elapsed > .zero
        }
        guard hasMeaningfulSpeed else { return "--.-X" }
        return String(format: "%4.1fX", processed / elapsed)
    }

    /// Rounded down, so the indicator never claims 100% while audio remains to be read.
    var percentComplete: Int? {
        guard let total, total > .zero else { return nil }
        let fraction = min(1.0, max(0.0, processed / total))
        return Int((fraction * 100).rounded(.down))
    }

    /// Formats a duration as `HH:MM:SS`.
    static func timecode(_ duration: Duration) -> String {
        let totalSeconds = Int(duration.components.seconds)
        return String(format: "%02d:%02d:%02d",
                      totalSeconds / 3600,
                      (totalSeconds % 3600) / 60,
                      totalSeconds % 60)
    }
}
