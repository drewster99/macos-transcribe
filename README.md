# macos-transcribe

`transcribe` turns an audio file — or the audio in a video file — into text, using Apple's
on-device speech recognition. Nothing is uploaded anywhere.

```
$ transcribe meeting.mp4
Thanks everyone for joining.
Let's start with the roadmap review.
...

$ transcribe -f srt lecture.mov -o lecture.srt
```

## What it does

- Reads any container AVFoundation can open: `.mp4`, `.mov`, `.m4a`, `.wav`, `.aiff`, `.mp3`, and
  the rest — audio-only or video with audio.
- Picks an audio track when a file has several, and tells you when it had to choose.
- Writes plain text, SubRip (`.srt`), WebVTT (`.vtt`), or JSON with per-word timings.
- Runs entirely on-device. No network, no API keys, no per-minute billing.
- No external dependencies. It does not shell out to `ffmpeg` or anything else.

## Requirements

macOS 26 or later, on Apple silicon. The speech models are Apple-silicon only, which is why the
binary is `arm64`-only rather than universal — an Intel slice would install and then fail at
runtime.

## Install

```
brew install drewster99/tap/transcribe
```

Or download the `.pkg` from [Releases](https://github.com/drewster99/macos-transcribe/releases),
which installs `transcribe` to `/usr/local/bin`. A `.tar.gz` of the bare binary is published
alongside it, with `SHA256SUMS`.

## Usage

```
transcribe [options] <file>

  -o, --output <path>          Write to path instead of standard output
  -f, --format <fmt>           txt (default), srt, vtt, json
  -l, --locale <bcp47>         Language, e.g. en-US. Defaults to your system locale
      --track <n>              Zero-based audio track index
      --first-track            Use the first audio track without warning
      --list-tracks            List the file's audio tracks and exit
      --list-locales           List supported locales and exit
      --install-model          Download the speech model for the locale and exit
      --max-cue-seconds <n>    Longest subtitle cue, in seconds (default 6)
      --max-words-per-cue <n>  Most words in one cue (default 14)
  -q, --quiet                  Suppress warnings and progress
      --version, --help
```

The transcript goes to standard output; warnings and progress go to standard error. Redirecting or
piping is safe:

```
transcribe interview.m4a | grep -i "budget"
transcribe -f json talk.mp4 | jq '.segments[].words[0]'
```

### Choosing a track

A file with one audio track just works. With several, the first is used and a warning names what was
skipped:

```
$ transcribe --list-tracks film.mov
[0]  eng       aac   48000 Hz  2ch  128 kbps  00:00:00–01:32:11
[1]  fra       aac   48000 Hz  2ch  128 kbps  00:00:00–01:32:11

$ transcribe --track 1 film.mov
```

Use `--first-track` to accept the first one silently. One track is transcribed per invocation.

### Languages

`--list-locales` shows what on-device transcription supports and what is already downloaded. The
model for a locale downloads automatically the first time it is used; `--install-model` fetches it
ahead of time. An unsupported locale is an error rather than a silent fall back to a nearby
language.

## Permissions

The first run asks for Speech Recognition access. Because a command-line tool is not its own
application, macOS attributes the request to whatever launched it — usually Terminal — so the prompt
and the entry in **System Settings → Privacy & Security → Speech Recognition** name your terminal,
not `transcribe`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 64 | Bad arguments |
| 65 | Not a media file, no audio tracks, undecodable, or truncated |
| 66 | File missing or unreadable |
| 69 | DRM-protected |
| 70 | Transcription failed |
| 77 | Speech Recognition not authorized |
| 78 | Locale unsupported, or its model could not be installed |
| 130 | Interrupted with Ctrl-C |

An interrupted run writes nothing at all. A partial transcript is indistinguishable from a complete
one once it leaves the process, so it is never emitted.

## Build

```
git clone https://github.com/drewster99/macos-transcribe.git
cd macos-transcribe
open transcribe.xcodeproj
```

## Project layout

```
transcribe/
  TranscribeCommand.swift    argument parsing and orchestration
  CLI/                       output formats, exit codes, track selection
  Ingest/                    AVAssetReader -> AsyncSequence<AnalyzerInput>   # read this first
  Speech/                    authorization, model installation, SpeechAnalyzer
  Transcript/                transcript model and subtitle cue segmentation
  Output/                    txt, srt, vtt, and json rendering
  Support/                   stderr reporting, interrupts, version
release.sh                   build, sign, notarize, publish
```

`Ingest/` is the interesting part: it decodes one audio track straight into the format the analyzer
asks for and feeds it through a pull-based sequence, so memory stays flat on a file of any length.
See `CLAUDE.md` for why it is built that way.

## License

MIT — see [LICENSE.md](LICENSE.md).
