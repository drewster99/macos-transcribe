import Foundation
import Speech

/// Obtains permission to use speech recognition.
enum SpeechAuthorization {

    /// Requests authorization, returning normally only if it was granted.
    ///
    /// The prompt is attributed to whatever launched this tool — usually Terminal — because a
    /// command-line binary is not its own responsible process. That is why the denial messages
    /// below name the terminal application rather than `transcribe`.
    static func requireAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }

        switch status {
        case .authorized:
            return
        case .denied:
            throw TranscribeError.message(
                "Speech Recognition access was denied.",
                hint: "Grant it in System Settings > Privacy & Security > Speech Recognition, "
                    + "for the app running this command (usually your terminal).",
                code: .notAuthorized
            )
        case .restricted:
            throw TranscribeError(
                "Speech Recognition is restricted on this Mac and cannot be enabled here.",
                code: .notAuthorized
            )
        case .notDetermined:
            // The request completed without resolving, which happens when nothing can present the
            // prompt. Re-running from an interactive terminal gives it somewhere to appear.
            throw TranscribeError.message(
                "Speech Recognition permission was not granted.",
                hint: "Run transcribe once from an interactive terminal so macOS can show the prompt.",
                code: .notAuthorized
            )
        @unknown default:
            throw TranscribeError(
                "Speech Recognition returned an unrecognized authorization status.",
                code: .notAuthorized
            )
        }
    }
}
