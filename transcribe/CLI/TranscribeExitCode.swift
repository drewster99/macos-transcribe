/// Process exit codes, following the `sysexits.h` conventions where one applies so that shell
/// callers can distinguish "you asked for something impossible" from "this file is unusable" from
/// "the system refused".
enum TranscribeExitCode: Int32 {
    /// Bad flags, or a combination of flags that cannot be honored.
    case usage = 64
    /// The input is not a media file, has no audio tracks, or cannot be decoded.
    case unusableInput = 65
    /// The input path does not exist or cannot be read.
    case unreadableInput = 66
    /// The input is DRM-protected.
    case protectedContent = 69
    /// Transcription started but did not complete.
    case transcriptionFailed = 70
    /// Speech Recognition authorization was denied or restricted.
    case notAuthorized = 77
    /// The requested locale is unsupported, or its model could not be installed.
    case localeUnavailable = 78
}

/// An error that carries both a human-readable message and the exit code to leave with.
///
/// Conforming to `CustomStringConvertible` rather than `LocalizedError` is deliberate: routing
/// through `LocalizedError` would prefix the message with "The operation couldn't be completed".
struct TranscribeError: Error, CustomStringConvertible {
    let description: String
    let exitCode: TranscribeExitCode

    init(_ description: String, code: TranscribeExitCode) {
        self.description = description
        self.exitCode = code
    }
}

extension TranscribeError {
    /// A hint appended to messages where the user's next action is not obvious from the failure
    /// alone. Kept separate so the failure and the remedy read as distinct sentences.
    static func message(_ failure: String, hint: String, code: TranscribeExitCode) -> TranscribeError {
        TranscribeError("\(failure)\n  \(hint)", code: code)
    }
}
