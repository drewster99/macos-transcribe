import AVFoundation
import CoreMedia
import Foundation

/// Pulls decoded audio sample buffers from a media file, one at a time.
///
/// This exists as a protocol to isolate the one thing about the ingest path that is not fully
/// determined by the API contract: whether `AVAssetReaderOutput.Provider.next()` keeps its blocking
/// demux and decode work off the caller's thread. If it turns out not to, the replacement is a
/// dedicated-serial-queue implementation behind this same single method, and nothing else in the
/// pipeline moves.
protocol SampleSource: AnyObject {
    /// The next decoded buffer, or nil at a clean end of stream.
    ///
    /// Throws rather than returning nil if the reader failed, so a truncated file cannot be
    /// mistaken for a complete one.
    func nextSample() async throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?

    /// Stops reading and releases the reader. Safe to call more than once.
    func finish()
}

/// Reads through `AVAssetReaderOutput.Provider`, the macOS 26 replacement for
/// `copyNextSampleBuffer()`, which is deprecated in Swift.
final class ProviderSampleSource: SampleSource {

    private let reader: AVAssetReader
    private let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    private var isFinished = false

    init(asset: AVURLAsset, track: AVAssetTrack, outputSettings: [String: Any]) throws {
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscribeError(
                "Could not open the file for reading: \(error.localizedDescription)",
                code: .unusableInput
            )
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        // Sample buffers are consumed as they arrive; copying them again would double the work for
        // no benefit.
        output.alwaysCopiesSampleData = false
        provider = reader.outputProvider(for: output)
        try reader.start()
    }

    func nextSample() async throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>? {
        guard !isFinished else { return nil }

        let sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?
        do {
            sample = try await provider.next()
        } catch is CancellationError {
            isFinished = true
            throw CancellationError()
        } catch {
            // A damaged or truncated file surfaces here, as a decode error partway through the
            // track. Reported as a read failure rather than passed through raw, because the
            // framework's wording ("invalid sample cursor") describes its own bookkeeping and says
            // nothing a user can act on.
            isFinished = true
            throw TranscribeError.message(
                "Reading the audio failed partway through: \(error.localizedDescription)",
                hint: "The file may be truncated or damaged.",
                code: .unusableInput
            )
        }

        if sample == nil {
            isFinished = true
            try confirmCleanEndOfStream()
        }
        return sample
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        reader.cancelReading()
    }

    /// Distinguishes a real end of stream from a read that stopped early.
    ///
    /// The reader reports both by running out of samples, so without this check a mid-file I/O
    /// error or a truncated download yields a short transcript that looks complete — a silent
    /// wrong answer, which is worse than a loud failure.
    private func confirmCleanEndOfStream() throws {
        switch reader.status {
        case .completed:
            return
        case .failed:
            let detail = reader.error?.localizedDescription ?? "unknown error"
            throw TranscribeError.message(
                "Reading the audio failed partway through: \(detail)",
                hint: "The file may be truncated or damaged.",
                code: .unusableInput
            )
        case .cancelled:
            throw CancellationError()
        case .reading, .unknown:
            throw TranscribeError(
                "The audio reader stopped unexpectedly before the end of the track.",
                code: .transcriptionFailed
            )
        @unknown default:
            throw TranscribeError(
                "The audio reader reported an unrecognized status.",
                code: .transcriptionFailed
            )
        }
    }
}
