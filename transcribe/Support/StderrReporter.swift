import Darwin
import Foundation
import Synchronization

/// All out-of-band communication with the user: warnings, notices, and the progress indicator.
///
/// Everything here goes to stderr so that stdout carries only the transcript and stays safe to
/// redirect or pipe.
final class StderrReporter: Sendable {

    /// Whether the progress indicator is drawn.
    ///
    /// Progress uses carriage returns to overwrite itself, which turns into line noise in a file or
    /// a pipe, so it is drawn only when stderr is a terminal that can handle it.
    private let drawsProgress: Bool

    /// Whether warnings and notices are emitted at all.
    private let isQuiet: Bool

    /// Guards `lastProgressDraw` and `hasPendingProgressLine`, which the progress path reads and
    /// writes from whichever task happens to be feeding audio.
    private let progressState = Mutex(ProgressState())

    private struct ProgressState {
        var lastDraw: ContinuousClock.Instant?
        var hasPendingLine = false
    }

    /// Redrawing faster than this produces flicker without conveying more information.
    private static let minimumRedrawInterval = Duration.milliseconds(100)

    init(quiet: Bool) {
        self.isQuiet = quiet
        // TERM=dumb signals a terminal that cannot handle the cursor control progress relies on.
        let terminalHandlesControlCodes = ProcessInfo.processInfo.environment["TERM"] != "dumb"
        self.drawsProgress = !quiet && isatty(STDERR_FILENO) == 1 && terminalHandlesControlCodes
    }

    /// Reports a condition the user should know about but which does not stop the transcription.
    func warn(_ message: String) {
        guard !isQuiet else { return }
        clearProgressLine()
        write("transcribe: warning: \(message)\n")
    }

    /// Reports normal progress information, such as a model download starting.
    func notice(_ message: String) {
        guard !isQuiet else { return }
        clearProgressLine()
        write("transcribe: \(message)\n")
    }

    /// Reports a fatal condition. Always emitted, even under `--quiet`, because exiting without
    /// saying why is worse than being noisy.
    func error(_ message: String) {
        clearProgressLine()
        write("transcribe: error: \(message)\n")
    }

    /// Draws the transcription progress indicator.
    ///
    /// - Parameters:
    ///   - processed: How much of the media has been fed to the analyzer.
    ///   - total: Total media duration, or nil when the duration is not known.
    func reportProgress(processed: Duration, total: Duration?) {
        guard drawsProgress else { return }

        let shouldDraw = progressState.withLock { state -> Bool in
            let now = ContinuousClock.now
            if let last = state.lastDraw, now - last < Self.minimumRedrawInterval {
                return false
            }
            state.lastDraw = now
            state.hasPendingLine = true
            return true
        }
        guard shouldDraw else { return }

        // A live-streamed or malformed file can report an indefinite duration; showing elapsed time
        // alone is honest, where a percentage would require inventing a denominator.
        guard let total, total > .zero else {
            write("\r\u{1B}[K  \(Self.timecode(processed)) processed")
            return
        }
        let fraction = min(1.0, max(0.0, processed / total))
        let percent = Int((fraction * 100).rounded())
        write("\r\u{1B}[K  \(percent)%  \(Self.timecode(processed)) / \(Self.timecode(total))")
    }

    /// Draws progress for a model download, which reports a completed fraction rather than a
    /// position in a timeline.
    func reportDownloadProgress(fraction: Double, label: String) {
        guard drawsProgress else { return }

        let shouldDraw = progressState.withLock { state -> Bool in
            let now = ContinuousClock.now
            if let last = state.lastDraw, now - last < Self.minimumRedrawInterval {
                return false
            }
            state.lastDraw = now
            state.hasPendingLine = true
            return true
        }
        guard shouldDraw else { return }

        let percent = Int((min(1.0, max(0.0, fraction)) * 100).rounded())
        write("\r\u{1B}[K  \(label) \(percent)%")
    }

    /// Erases the progress indicator.
    ///
    /// Must be called before the process exits by any path — an abandoned progress line would
    /// otherwise sit above the shell prompt or in front of an error message.
    func clearProgressLine() {
        let hadLine = progressState.withLock { state -> Bool in
            defer { state.hasPendingLine = false }
            return state.hasPendingLine
        }
        guard hadLine else { return }
        write("\r\u{1B}[K")
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Formats a duration as `HH:MM:SS`.
    private static func timecode(_ duration: Duration) -> String {
        let totalSeconds = Int(duration.components.seconds)
        return String(format: "%02d:%02d:%02d",
                      totalSeconds / 3600,
                      (totalSeconds % 3600) / 60,
                      totalSeconds % 60)
    }
}
