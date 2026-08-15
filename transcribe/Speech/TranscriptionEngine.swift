import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Runs `SpeechAnalyzer` over one audio track and collects the result.
struct TranscriptionEngine {

    let reporter: StderrReporter

    /// Transcribes the selected track of `source`.
    func transcribe(
        source: MediaSource,
        track: AudioTrackInfo,
        locale: Locale,
        collectWordTimings: Bool
    ) async throws -> Transcript {

        // Word-level audio ranges cost extra work in the recognizer, so they are requested only for
        // the output formats that position text against the timeline.
        let attributeOptions: Set<SpeechTranscriber.ResultAttributeOption> =
            collectWordTimings ? [.audioTimeRange] : []

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Volatile results are in-progress guesses that get revised. A file is transcribed
            // once and printed at the end, so only finalized results are of any use here.
            reportingOptions: [],
            attributeOptions: attributeOptions
        )

        try await SpeechModelCatalog.ensureModelInstalled(
            for: transcriber,
            locale: locale,
            reporter: reporter
        )

        let negotiated = try await NegotiatedAudioFormat.negotiate(
            for: transcriber,
            sourceFormat: try await naturalFormat(of: track, in: source),
            sourceChannelCount: track.channelCount
        )

        let plan = AudioIngestPlan(
            asset: source.asset,
            trackID: track.trackID,
            format: negotiated,
            progress: IngestProgress(reporter: reporter, assetDuration: source.duration)
        )

        let segments = try await runAnalyzer(transcriber: transcriber, plan: plan)

        return Transcript(
            segments: segments,
            locale: locale.identifier(.bcp47),
            sourceName: source.url.lastPathComponent,
            trackOrdinal: track.ordinal,
            duration: source.duration.numericSeconds ?? 0
        )
    }

    // MARK: - Private

    private func runAnalyzer(
        transcriber: SpeechTranscriber,
        plan: AudioIngestPlan
    ) async throws -> [TranscriptSegment] {

        // Captured before the analyzer starts. If nothing is consuming results, the analyzer
        // eventually stops pulling input to apply back-pressure, and finalizing would then wait
        // forever on audio that is never read.
        let results = transcriber.results
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = ResultCollector()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await result in results {
                        // Only finalized results are collected; with volatile reporting disabled
                        // this should be all of them, but the guard keeps a revised guess from
                        // reaching the transcript if that ever changes.
                        guard result.isFinal else { continue }
                        await collector.append(result)
                    }
                }
                group.addTask {
                    try await analyzer.start(inputSequence: AssetAudioInputSequence(plan: plan))
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                try await group.waitForAll()
            }
        } catch {
            // Reaching here means input stopped early or a module failed. Cancelling rather than
            // finalizing is deliberate: finalizing would emit whatever was recognized so far as a
            // complete transcript, which is a wrong answer that looks like a right one.
            await analyzer.cancelAndFinishNow()
            reporter.clearProgressLine()
            throw mapped(error)
        }

        reporter.clearProgressLine()
        return await collector.segments()
    }

    private func naturalFormat(of track: AudioTrackInfo, in source: MediaSource) async throws -> AVAudioFormat? {
        guard let assetTrack = try await source.asset.loadTrack(withTrackID: track.trackID),
              let formatDescription = try await assetTrack.load(.formatDescriptions).first else {
            return nil
        }
        return AVAudioFormat(cmAudioFormatDescription: formatDescription)
    }

    /// Turns framework errors into messages that say what the user can do about them.
    private func mapped(_ error: Error) -> Error {
        if error is TranscribeError || error is CancellationError { return error }

        guard let speechError = error as? SFSpeechError else {
            return TranscribeError("Transcription failed: \(error.localizedDescription)", code: .transcriptionFailed)
        }

        switch speechError.code {
        case .noModel:
            return TranscribeError.message(
                "No speech model is available for this locale.",
                hint: "Run transcribe --install-model --locale <locale> first.",
                code: .localeUnavailable
            )
        case .unexpectedAudioFormat, .incompatibleAudioFormats:
            return TranscribeError(
                "The audio could not be supplied in a format the recognizer accepts.",
                code: .transcriptionFailed
            )
        case .audioDisordered:
            return TranscribeError(
                "The file's audio timestamps run backwards, which the recognizer cannot process.",
                code: .unusableInput
            )
        case .insufficientResources:
            return TranscribeError.message(
                "The system ran short of resources for on-device transcription.",
                hint: "Close other applications and try again.",
                code: .transcriptionFailed
            )
        default:
            return TranscribeError(
                "Transcription failed: \(speechError.localizedDescription)",
                code: .transcriptionFailed
            )
        }
    }
}

/// Accumulates finalized results, converting each into a segment with its word timings.
///
/// An actor because the results task and the caller reading them are different tasks.
private actor ResultCollector {

    private var collected: [TranscriptSegment] = []

    func append(_ result: SpeechTranscriber.Result) {
        let attributed = result.text
        let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        var words: [TranscribedWord] = []
        for run in attributed.runs {
            guard let range = run.audioTimeRange,
                  let start = range.start.numericSeconds,
                  let end = range.end.numericSeconds else { continue }
            let wordText = String(attributed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wordText.isEmpty else { continue }
            words.append(TranscribedWord(text: wordText, start: start, end: end))
        }

        // The result's own range is the fallback when word timings were not requested, so a segment
        // always carries a usable position even in plain-text mode.
        let start = words.first?.start ?? result.range.start.numericSeconds ?? 0
        let end = words.last?.end ?? result.range.end.numericSeconds ?? start

        collected.append(TranscriptSegment(text: text, start: start, end: end, words: words))
    }

    func segments() -> [TranscriptSegment] { collected }
}
