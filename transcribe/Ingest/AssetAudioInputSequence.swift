import AVFoundation
import CoreMedia
import Foundation
import Speech
import Synchronization

/// Feeds one audio track of a media file to `SpeechAnalyzer`.
///
/// This is a pull sequence: each `next()` decodes exactly one buffer. Because the analyzer drives
/// the pace, memory stays flat no matter how long the file is. Pushing instead — an `AsyncStream`
/// filled by a decoder running far faster than realtime — would either buffer hours of PCM into
/// memory or, with a bounded policy, silently drop audio and produce a confident, wrong transcript.
///
/// The sequence itself holds only `Sendable` values. The reader is non-`Sendable` and is created
/// lazily inside the iterator, so it is born in the consumer's isolation domain and never crosses a
/// boundary — which is what lets this satisfy the `Sendable` requirement of
/// `SpeechAnalyzer.start(inputSequence:)` without an unchecked conformance.
struct AssetAudioInputSequence: AsyncSequence, Sendable {

    typealias Element = AnalyzerInput
    typealias Failure = any Error

    let plan: AudioIngestPlan

    func makeAsyncIterator() -> Iterator {
        Iterator(plan: plan)
    }

    final class Iterator: AsyncIteratorProtocol {

        private let plan: AudioIngestPlan
        private var source: (any SampleSource)?
        private var bufferFactory: PCMBufferFactory
        private var hasStarted = false
        private var hasFinished = false
        private var establishedFormat: CMFormatDescription?

        init(plan: AudioIngestPlan) {
            self.plan = plan
            self.bufferFactory = PCMBufferFactory(format: plan.format.analyzerFormat)
        }

        deinit {
            source?.finish()
        }

        func next() async throws -> AnalyzerInput? {
            if hasFinished { return nil }
            if !hasStarted {
                hasStarted = true
                source = try await makeSource()
            }
            guard let source else { return nil }

            while true {
                // Interruption must throw rather than end the sequence: returning nil here would
                // read as a clean end of input, and the analyzer would finalize a partial
                // transcript as though it were complete.
                //
                // Both checks are needed. The analyzer iterates this sequence from a task it owns,
                // so `Task.isCancelled` does not observe the command's cancellation; the flag
                // carries it across that boundary.
                try plan.interrupts.throwIfInterrupted()
                try Task.checkCancellation()

                guard let sample = try await source.nextSample() else {
                    finish()
                    return nil
                }
                guard let input = try bufferFactory.makeInput(from: sample) else { continue }
                try confirmFormatIsStable(input.formatDescription)

                plan.progress.record(processedThrough: input.startTime)
                return AnalyzerInput(buffer: input.buffer, bufferStartTime: input.startTime)
            }
        }

        private func finish() {
            hasFinished = true
            source?.finish()
            source = nil
        }

        /// Resolves the track and opens the reader.
        ///
        /// The `AVAssetTrack` is fetched and consumed entirely within this call so that a
        /// non-`Sendable` value never escapes into stored state.
        private func makeSource() async throws -> any SampleSource {
            guard let track = try await plan.asset.loadTrack(withTrackID: plan.trackID) else {
                throw TranscribeError(
                    "The selected audio track is no longer present in the file.",
                    code: .unusableInput
                )
            }
            return try ProviderSampleSource(
                asset: plan.asset,
                track: track,
                outputSettings: plan.format.readerOutputSettings
            )
        }

        /// Fails if the decoder starts producing a different format partway through.
        ///
        /// The negotiated format was chosen once, from the track's first format description. If the
        /// track changes format mid-file, every downstream assumption about sample rate and channel
        /// count is void, so this stops rather than transcribing noise.
        private func confirmFormatIsStable(_ formatDescription: CMFormatDescription) throws {
            guard let established = establishedFormat else {
                establishedFormat = formatDescription
                return
            }
            guard established != formatDescription else { return }
            throw TranscribeError(
                "The audio format changed partway through the track, which cannot be transcribed in one pass.",
                code: .unusableInput
            )
        }
    }
}

/// Everything the ingest sequence needs, in `Sendable` form.
struct AudioIngestPlan: Sendable {

    /// `AVURLAsset` is `Sendable`, unlike `AVAsset`, which is what allows this plan to be carried
    /// into the sequence.
    let asset: AVURLAsset

    /// Identifies the track to read. Stored as an ID rather than an `AVAssetTrack` because the
    /// track object is not `Sendable`.
    let trackID: CMPersistentTrackID

    let format: NegotiatedAudioFormat

    let progress: IngestProgress

    /// Observed on every buffer so Ctrl-C stops the read promptly, and stops it by throwing.
    let interrupts: InterruptFlag
}

/// Tracks how far into the media the ingest has read, and reports it.
///
/// Progress is measured at the point audio is fed to the analyzer rather than at the point results
/// come back. Because the analyzer's consumption paces the read, the two stay close — and unlike
/// result timestamps, this keeps advancing through music, silence, and applause, where a
/// result-driven indicator would sit at zero and look hung.
final class IngestProgress: Sendable {

    private let reporter: StderrReporter
    private let totalDuration: Duration?
    private let toolVersion = ToolVersion.current

    /// Taken when the plan is built, just before the analyzer starts, so the reported speed covers
    /// analyzer startup and finalization as well as the read itself.
    private let startedAt = ContinuousClock.now

    /// The furthest position recorded, which stands in for the length of the media in the closing
    /// summary when the file has no usable duration.
    private let furthestProcessed = Mutex(Duration.zero)

    init(reporter: StderrReporter, assetDuration: CMTime) {
        self.reporter = reporter
        // An indefinite or non-numeric duration means there is no denominator to show a percentage
        // against; elapsed time alone is reported instead.
        if assetDuration.isNumeric, assetDuration.seconds > 0 {
            self.totalDuration = .seconds(assetDuration.seconds)
        } else {
            self.totalDuration = nil
        }
    }

    func record(processedThrough timestamp: CMTime) {
        guard timestamp.isNumeric else { return }
        let processed = Duration.seconds(timestamp.seconds)
        furthestProcessed.withLock { $0 = max($0, processed) }
        reporter.reportProgress(status(.transcribing, processed: processed))
    }

    /// Writes the closing summary. Call only once the whole input has been read and every result
    /// collected, since the line states that the media was processed to the end.
    func reportCompletion() {
        let processed = totalDuration ?? furthestProcessed.withLock { $0 }
        reporter.reportCompletion(status(.complete, processed: processed))
    }

    private func status(_ phase: TranscriptionStatusLine.Phase, processed: Duration) -> TranscriptionStatusLine {
        TranscriptionStatusLine(
            phase: phase,
            processed: processed,
            total: totalDuration,
            elapsed: ContinuousClock.now - startedAt,
            toolVersion: toolVersion
        )
    }
}
