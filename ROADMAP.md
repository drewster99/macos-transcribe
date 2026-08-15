# ROADMAP

Design log. Completed items stay, marked ✅ — the reasoning is the point, not the checkbox.

## v0.1 — working tool

- ✅ Xcode Command Line Tool target, arm64, macOS 26.0, Swift 6 with complete concurrency checking.
- ✅ Info.plist embedded in `__TEXT,__info_plist`; `--version` reads it back at runtime.
- ✅ Audio track enumeration, `--list-tracks`, and selection via `--track` / `--first-track`.
- ✅ Single-stage decode straight into the analyzer's format, no `AVAudioConverter`.
- ✅ Pull-based ingest sequence with back-pressure.
- ✅ Authorization, locale resolution, model installation with progress.
- ✅ Transcription with word timings; `txt`, `timed`, `srt`, `vtt`, `json` output.
- ✅ Ctrl-C exits 130 and writes nothing.
- ✅ Progress on stderr, gated on stderr being a terminal.

## Decisions and why

**(DESIGN) No `ffmpeg`, no subprocesses.** The prior art in `drews-video-social-scheduler` shells out
to `ffmpeg` to make a 16 kHz mono WAV, then reads it with `AVAudioFile`. That cannot address
individual tracks and cannot open `.mp4` at all through `AVAudioFile`. `AVAssetReader` handles audio
files and video uniformly and needs nothing installed.

**(DESIGN) Pull, not push.** See CLAUDE.md. Decode runs ~130x realtime; anything push-based either
exhausts memory or drops audio.

**(DESIGN) arm64 only.** The speech models are Apple silicon only. A universal binary would install
on an Intel Mac and fail at runtime, which is worse than not installing.

**(DESIGN) One audio track per invocation.** Mixing tracks would destroy the ability to attribute
speech, and transcribing all of them multiplies runtime for a case most files do not have. Shell
loops cover the batch case.

**(DESIGN) Plain text is one line per finalized result.** Result boundaries are roughly
utterance-sized and newline-delimited output is what the rest of the toolchain expects. No
re-segmentation heuristic sits between the model and plain-text output.

**(DESIGN) `timed` is a format, not a `--timestamps` flag.** A flag would be meaningless alongside
`-f srt`, `-f vtt`, and `-f json`, so it would need validation rejecting those combinations. The
format enum already decides everything about output shape; keeping it the only such dimension means
no two options can contradict each other.

**(DESIGN) An unsupported locale is an error.** Falling back to a nearby language would transcribe
Portuguese with a Spanish model and produce fluent nonsense.

**(FINDING) `assetInstallationRequest(supporting:)` is always non-nil.** Measured. The plan assumed
nil meant "already installed" and that was wrong. `installedLocales` is the accurate signal;
`status(forModules:)` disagrees with it and is not usable either.

**(FINDING) `AVAudioPCMBuffer.mutableAudioBufferList` sizes from `frameLength`, not
`frameCapacity`.** Setting `frameLength` after the copy left a zero-byte destination and CoreMedia
rejected it with `-12731`. It must be set first.

**(FINDING) `copyNextSampleBuffer()` is deprecated in Swift on macOS 26**, replaced by
`AVAssetReader.outputProvider(for:)` returning an async `Provider`. Measured at 1 ms of jitter
against a 10 ms tick, so it does not block the cooperative pool and no dedicated reader thread is
needed. It also throws on mid-read failure rather than returning nil.

**(FINDING) `AVAssetReaderTrackOutput` applies edit lists** and reports asset-timeline timestamps, so
real PTS are passed to `AnalyzerInput` rather than nil.

**(FINDING) Task cancellation does not reach the ingest iterator**, because `SpeechAnalyzer` iterates
it from a task it owns. And `finalizeAndFinishThroughEndOfInput()` neither observes cancellation nor
returns once the reader has stopped. Both required explicit mechanisms — see CLAUDE.md.

## Verification corpus

Generated with `ffmpeg` (test-only dependency):

| Fixture | Catches |
| --- | --- |
| mono 16 kHz WAV | baseline |
| 48 kHz stereo AAC | resampling and downmix |
| 5.1 AAC | multi-channel downmix needing an explicit channel layout |
| `.mov`, two audio tracks tagged eng/spa | track selection and the multi-track warning |
| video with no audio | exit 65 |
| text file named `.mp4` | exit 65 |
| **`+faststart` truncated to 55%** | **opens and reports full duration, then fails mid-read** |
| **audio offset from video by an edit list** | **subtitle alignment** |
| 8 s leading silence | progress not appearing hung; recognition after silence |
| 10 minute file | memory flatness, progress, interrupt |

Current state: 25/25 exit-code sweep passing.

## Next

1. XCTest target. The segmenter, timecode formatting, `TrackSelection.resolvedIndex`, and
   `PCMBufferFactory` timestamp monotonicity are all pure functions and should be unit tested.
2. A committed fixture-generation script so the corpus is reproducible rather than living in a
   scratch directory.
3. Decide whether `--format json` should offer `SpeechTranscriber.Result.alternatives`. The data is
   free; it was left out to keep the default output small.
4. Consider `--verbose` to report the negotiated audio format and selected track, for diagnosing a
   file that transcribes poorly.
5. Revisit whether a `.pkg` is still worth shipping once Homebrew is the common install path.
