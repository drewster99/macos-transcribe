# CLAUDE.md

## What this project is

`transcribe` is a macOS command-line tool that transcribes an audio file, or the audio track of a
video file, using Apple's on-device `Speech` framework. It writes plain text, SubRip, WebVTT, or
JSON to standard output or a file.

Public repo (`__PUBLIC_REPO` marker at root): no secrets, hostnames, or customer data, ever.

## Repo layout

The repo is at `~/Documents/ncc_source/cursor/macos-transcribe`, also reachable as
`~/cursor/macos-transcribe` — same directory, `~/cursor` is a symlink.

```
transcribe.xcodeproj          single Command Line Tool target, at repo root
transcribe/                   all sources; the target uses a synchronized file group,
                              so new files are picked up without editing the project
release.sh                    build, sign, notarize, publish
```

There is no local Swift package. The one external dependency is `apple/swift-argument-parser`,
added as an Xcode package dependency.

## Building and running

**Build only through the drews-xcode-mcp MCP tools. Never `xcodebuild` directly.**

```
mcp__drews-xcode-mcp__build_project
    project_path: /Users/andrew/Documents/ncc_source/cursor/macos-transcribe/transcribe.xcodeproj
    scheme: transcribe
```

The built binary lands in DerivedData at `Build/Products/Debug/transcribe`.

Note that Xcode 26.6 builds with a Swift 6.4 frontend while the command-line `swiftc` on PATH is
6.3.3. Compiling sources by hand against DerivedData modules fails on that mismatch — build through
the MCP.

## Key build settings

- `MACOSX_DEPLOYMENT_TARGET = 26.0` — `SpeechAnalyzer` and everything around it is macOS 26.0+.
- `ARCHS = arm64` — deliberately not universal. The on-device speech models are Apple silicon only,
  so an x86_64 slice would install on an Intel Mac and then fail at runtime.
- `SWIFT_VERSION = 6.0` with `SWIFT_STRICT_CONCURRENCY = complete`.
- `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` — a bare executable has no bundle directory, so the
  Info.plist is compiled into `__TEXT,__info_plist`. This is **required**, not cosmetic: without
  `NSSpeechRecognitionUsageDescription` the process is terminated when it asks for authorization.
- `MARKETING_VERSION` is the single source of the version. `--version` reads
  `CFBundleShortVersionString` back out of the embedded plist at runtime (verified working), and
  `release.sh` bumps only the project file.

## Architecture: the parts you must understand

### Ingest is pull-based, and that is load-bearing

`Ingest/AssetAudioInputSequence.swift` is an `AsyncSequence` whose `next()` decodes exactly one
buffer. `SpeechAnalyzer` drives the pace, so memory stays flat regardless of file length — measured
at 29.6 MB peak RSS for a ten-minute file.

Do not replace this with an `AsyncStream`. Decoding was measured at roughly 130x realtime: an
unbounded stream buffers hours of PCM into memory, and a bounded policy (`.bufferingNewest`) drops
audio silently and yields a confident, wrong transcript.

### One conversion stage, not two

`AVAssetReaderTrackOutput.outputSettings` decodes directly into the format
`SpeechAnalyzer.bestAvailableAudioFormat` returns (16 kHz mono int16 interleaved, in practice —
read at runtime, never assumed). There is no `AVAudioConverter`.

That is not just tidiness. A converter doing sample-rate conversion produces a different frame count
than it consumes, so input timestamps stop mapping to output timestamps, and any residual priming
latency accumulates as drift in subtitle timings.

`AVAssetReaderTrackOutput.init(track:outputSettings:)` raises an Objective-C exception for settings
it dislikes, which is a process crash rather than a catchable error in Swift. `AudioFormatNegotiation`
round-trips the settings through `AVAudioFormat(settings:)` and compares the resulting ASBD before
handing them over. Keep that check.

### Sendable without unchecked conformances

The ingest sequence stores only `Sendable` values (`AVURLAsset` is Sendable; `AVAsset` and
`AVAssetTrack` are not). The reader is created lazily inside the iterator so it is born in the
consumer's isolation domain and never crosses a boundary. There are no `@unchecked Sendable`
conformances in this project — keep it that way.

### Never emit a partial transcript

This is the invariant that most of the error handling exists to protect. A transcript that stopped
early is indistinguishable from a complete one once it leaves the process, so a short read must fail
loudly instead.

Three separate mechanisms enforce it, all of which were found necessary by testing:

1. **Clean-EOF check.** The reader signals both "end of stream" and "failed" by running out of
   samples, so every `nil` return is gated on `reader.status == .completed`.
2. **Explicit interrupt flag.** `SpeechAnalyzer` iterates the input from a task it owns, not a child
   of the caller's, so `Task.isCancelled` inside the iterator never observes the command's
   cancellation. `InterruptFlag` crosses that boundary.
3. **Interrupt handlers.** `finalizeAndFinishThroughEndOfInput()` waits for an end of input a
   stopped reader never sends, and does not observe cancellation, so `InterruptFlag` carries
   handlers that shut the analyzer down from the signal side.

On any failure the analyzer is **cancelled**, never finalized — finalizing publishes what it heard
so far as though it were the whole thing.

### The result collector is not in a task group

It runs as an independent `Task`. As a sibling under `waitForAll()`, a read failure left it waiting
on a results stream that only the error path could close, and the group cannot return until every
child finishes — so the code that would close it never ran. Deadlock. Keep them separate.

### Timestamps are asset-relative

`AnalyzerInput` is given the real presentation timestamp, not `nil`. `AVAssetReaderTrackOutput`
applies edit lists and reports asset-timeline positions, so a file whose audio starts three seconds
in produces subtitles beginning at `00:00:03,000`. Passing `nil` would yield stream-relative times
and silently offset every subtitle.

## Speech framework behaviors worth knowing

These were measured on macOS 26.6, and two of them contradict what the API names suggest:

- **`AssetInventory.assetInstallationRequest(supporting:)` returns a non-nil request even when
  everything is installed.** "nil means installed" is wrong. `downloadAndInstall()` on a satisfied
  request is a ~2 ms no-op.
- **`AssetInventory.status(forModules:)` reports `.supported` for locales that
  `installedLocales` lists as installed.** Do not use it to decide whether a model is present.
- `SpeechTranscriber.installedLocales` is the accurate signal, and is what the code uses.
- `AssetInventory.maximumReservedLocales` is 5, so reserving can fail for real.
- Word timestamps are quantized to a 60 ms grid.
- `SpeechTranscriber.Result` has no stored `isFinal`; it is an extension on `SpeechModuleResult`.

`AVAssetReader` is worth one warning of its own: **its buffer chunking is not reproducible**. The
same binary reading the same bytes produces 24 or 25 buffers from run to run. Frame totals and
decoded audio are identical every time, so write nothing that depends on where the boundaries fall.

## Conventions specific to this repo

- Domain types (`OutputFormat`, `TranscribeExitCode`, `TranscribeError`) do not import
  `ArgumentParser`. The two bridging conformances live at the top of `TranscribeCommand.swift`, so
  the transcription core can be built and exercised without the CLI layer.
- Everything user-facing goes to stderr through `StderrReporter`. Only the transcript goes to
  stdout.
- Errors carry their exit code (`TranscribeError`), and messages state the remedy where there is
  one. No bare `NSError` descriptions reach the user.
- No fallbacks that mask a problem: an unsupported locale is an error, not a switch to a nearby
  language.
- Test fixtures are generated with `ffmpeg`, which is a **test-only** tool. The shipped binary has no
  external process dependencies — never add one.

## Testing

Two layers, and both matter.

**Unit tests** live in `transcribeTests/`, run with the `transcribe` scheme. Because a command line
tool cannot host a test bundle and cannot be `@testable import`ed, the sources under test are
compiled into the bundle directly via the synchronized group, with a
`PBXFileSystemSynchronizedBuildFileExceptionSet` excluding `TranscribeCommand.swift` — two `@main`
symbols in one bundle will not link. Adding a new non-`@main` source file needs no project edit.

```
mcp__drews-xcode-mcp__run_project_tests
    project_path: .../transcribe.xcodeproj
    scheme: transcribe
```

**Integration** is `scripts/run-integration-sweep.sh`, run against the corpus from
`scripts/make-fixtures.sh` (which needs ffmpeg — test scaffolding only, never a runtime dependency).
It checks the exit code of every documented failure mode, because most of what can go wrong here is
a wrong exit code rather than a crash. The two fixtures that matter most are the ones that catch
silent-wrong-answer bugs:

- a `+faststart` file truncated to 55%, which opens and reports a full duration but runs out of data
  mid-read;
- a file whose audio is offset from the video by an edit list.

`release.sh` runs the unit tests before building, and expands the finished `.pkg` to run the binary
it would install, exit codes included.
