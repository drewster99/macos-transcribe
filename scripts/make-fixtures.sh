#!/bin/bash
#
# Generates the media corpus the integration sweep runs against.
#
# ffmpeg and `say` are used here and only here. transcribe itself has no external process
# dependencies; these are test scaffolding, not runtime requirements.
#
# Usage: scripts/make-fixtures.sh [output-directory]
#        (default: build/fixtures)

set -Eeuo pipefail

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-${ROOT_DIRECTORY}/build/fixtures}"

fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }
step() { printf '\033[1m==> %s\033[0m\n' "$1"; }

command -v ffmpeg >/dev/null || fail "ffmpeg is required (brew install ffmpeg)"
command -v say >/dev/null || fail "say is required"
command -v afconvert >/dev/null || fail "afconvert is required"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

SPEECH_TEXT="The quick brown fox jumps over the lazy dog. This is a test of the transcription \
system. Apple's speech framework runs entirely on device. Nothing is uploaded to any server. \
That is the whole point of this tool."

SECOND_TEXT="This is the second audio track, spoken by a different voice, for track selection \
testing."

step "Synthesizing speech"
# Voice names vary between installs, so fall back to the system default rather than failing.
say -v Samantha -o en.aiff "$SPEECH_TEXT" 2>/dev/null || say -o en.aiff "$SPEECH_TEXT"
say -v Daniel -o alt.aiff "$SECOND_TEXT" 2>/dev/null || say -o alt.aiff "$SECOND_TEXT"

step "Audio-only fixtures"
afconvert -f WAVE -d LEI16@16000 -c 1 en.aiff speech-mono-16k.wav
ffmpeg -y -loglevel error -i en.aiff -ar 48000 -ac 2 -c:a aac -b:a 128k speech-stereo-48k.m4a

# More than two channels: exercises the downmix path, which needs an explicit destination
# channel layout or AVAssetReader refuses to produce mono.
ffmpeg -y -loglevel error -i en.aiff -ac 6 -c:a aac -b:a 384k surround-51.mp4

# Silence ahead of speech: the progress indicator must keep advancing through it rather than
# sitting at zero and looking hung.
ffmpeg -y -loglevel error -f lavfi -i "anullsrc=r=44100:cl=mono:d=8" -i en.aiff \
  -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1" -c:a aac leading-silence.m4a

step "Video fixtures"
# Two audio tracks tagged with different languages: track selection and the multi-track warning.
ffmpeg -y -loglevel error -f lavfi -i "color=c=navy:s=320x240:d=12" \
  -i en.aiff -i alt.aiff \
  -map 0:v -map 1:a -map 2:a \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 96k \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa \
  -shortest two-track.mov

ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=320x240:d=3" \
  -c:v libx264 -pix_fmt yuv420p -an no-audio.mp4

# Audio delayed behind the video, which the container records as an edit list. Subtitles must come
# out on the asset timeline, so the first cue starts around three seconds, not zero.
ffmpeg -y -loglevel error -f lavfi -i "color=c=green:s=320x240:d=16" -itsoffset 3 -i en.aiff \
  -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest offset-audio.mp4

step "Damaged and non-media fixtures"
printf 'these are just some notes, not a video at all\n' > notmedia.mp4

# +faststart puts the index at the front, so this opens cleanly and reports a full duration while
# holding only part of its audio. That is what makes it catch a truncated read being mistaken for a
# complete one — a file truncated without faststart simply fails to open, which proves nothing.
ffmpeg -y -loglevel error -i en.aiff -c:a aac -b:a 128k -movflags +faststart faststart.m4a
FASTSTART_SIZE="$(stat -f%z faststart.m4a)"
dd if=faststart.m4a of=truncated-midread.m4a bs=1 count=$((FASTSTART_SIZE * 55 / 100)) 2>/dev/null

step "Long fixture"
# Ten minutes, for memory flatness, progress reporting, and interrupt handling.
: > concat.txt
for _ in $(seq 1 50); do echo "file 'en.aiff'" >> concat.txt; done
ffmpeg -y -loglevel error -f concat -safe 0 -i concat.txt -c:a aac -b:a 96k long-10min.m4a
rm -f concat.txt

step "Done"
ls -la "$OUTPUT_DIR"
