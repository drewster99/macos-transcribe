#!/bin/bash
#
# Runs transcribe against the fixture corpus and checks the exit code of every case.
#
# Exit codes are part of this tool's contract, and most of the failure modes worth catching are
# wrong-exit-code bugs rather than crashes: a truncated file that reports success, a bad locale that
# silently falls back. Those look fine until you check the number.
#
# Usage: scripts/run-integration-sweep.sh [path-to-transcribe] [fixture-directory]
#
# Defaults to the Debug build in DerivedData and build/fixtures. Run scripts/make-fixtures.sh first.

set -Eeuo pipefail

ROOT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BINARY="${1:-}"
FIXTURES="${2:-${ROOT_DIRECTORY}/build/fixtures}"

if [[ -z "$BINARY" ]]; then
    # Newest first. Several DerivedData directories can exist for one project, and silently
    # sweeping a stale build would report on code that is no longer there.
    BINARY="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
        -type f -perm +111 -name transcribe -path '*/Build/Products/Debug/*' 2>/dev/null \
        -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
fi

[[ -x "$BINARY" ]] || { echo "error: no transcribe binary; build it first or pass a path" >&2; exit 1; }
[[ -d "$FIXTURES" ]] || { echo "error: no fixtures at ${FIXTURES}; run scripts/make-fixtures.sh" >&2; exit 1; }

echo "binary:   $BINARY"
echo "fixtures: $FIXTURES"
echo

PASSED=0
FAILED=0
OUTPUT_FILE="$(mktemp)"
ERROR_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE" "$ERROR_FILE"' EXIT

# check <description> <expected-exit-code> <command...>
check() {
    local description="$1" expected="$2"
    shift 2

    local actual=0
    "$@" > "$OUTPUT_FILE" 2> "$ERROR_FILE" || actual=$?

    if [[ "$actual" == "$expected" ]]; then
        PASSED=$((PASSED + 1))
        printf '  \033[32mok\033[0m   %-44s exit=%s\n' "$description" "$actual"
    else
        FAILED=$((FAILED + 1))
        printf '  \033[31mFAIL\033[0m %-44s exit=%s expected=%s\n' "$description" "$actual" "$expected"
        sed 's/^/         /' "$ERROR_FILE" | head -3
    fi
}

# check_output <description> <expected-substring> <command...>
# For cases where exiting zero is not enough — the content has to be right too.
check_output() {
    local description="$1" needle="$2"
    shift 2

    local actual=0
    "$@" > "$OUTPUT_FILE" 2> "$ERROR_FILE" || actual=$?

    if [[ "$actual" -eq 0 ]] && grep -q -- "$needle" "$OUTPUT_FILE"; then
        PASSED=$((PASSED + 1))
        printf '  \033[32mok\033[0m   %-44s\n' "$description"
    else
        FAILED=$((FAILED + 1))
        printf '  \033[31mFAIL\033[0m %-44s exit=%s, expected output containing %q\n' \
            "$description" "$actual" "$needle"
        head -3 "$OUTPUT_FILE" | sed 's/^/         /'
    fi
}

echo "Formats"
for format in txt timed srt vtt json; do
    check "format ${format}" 0 "$BINARY" -q -f "$format" "${FIXTURES}/speech-mono-16k.wav"
done

echo
echo "Decoding"
check "48 kHz stereo AAC"        0 "$BINARY" -q "${FIXTURES}/speech-stereo-48k.m4a"
check "5.1 surround downmix"     0 "$BINARY" -q "${FIXTURES}/surround-51.mp4"
check "leading silence"          0 "$BINARY" -q "${FIXTURES}/leading-silence.m4a"

echo
echo "Track selection"
check "two tracks, implicit"     0 "$BINARY" -q "${FIXTURES}/two-track.mov"
check "two tracks, --track 1"    0 "$BINARY" -q --track 1 "${FIXTURES}/two-track.mov"
check "two tracks, --first-track" 0 "$BINARY" -q --first-track "${FIXTURES}/two-track.mov"
check "--list-tracks"            0 "$BINARY" --list-tracks "${FIXTURES}/two-track.mov"
# The default must warn about what it skipped; silence here would be the bug. 2>&1 >/dev/null in
# that order keeps stderr and discards stdout, so only the warning is examined.
check_output "implicit choice warns" "audio tracks" \
    bash -c "\"$BINARY\" \"${FIXTURES}/two-track.mov\" 2>&1 >/dev/null"

echo
echo "Timeline"
# The audio sits ~3s into the asset via an edit list. Only the FIRST cue's start is examined:
# grepping the whole file for 00:00:03 would also pass if the edit list were ignored, since that
# timestamp appears mid-transcript either way.
check_output "edit list offsets first cue" "^00:00:0[23]" \
    bash -c "\"$BINARY\" -q -f srt \"${FIXTURES}/offset-audio.mp4\" | grep -m1 -- '-->' | cut -d' ' -f1"

echo
echo "Informational modes"
check "--list-locales"           0 "$BINARY" --list-locales
check "--install-model"          0 "$BINARY" --install-model --locale en-US
check "--version"                0 "$BINARY" --version
check "--help"                   0 "$BINARY" --help

echo
echo "Unusable input"
check "no audio tracks"         65 "$BINARY" -q "${FIXTURES}/no-audio.mp4"
check "not a media file"        65 "$BINARY" -q "${FIXTURES}/notmedia.mp4"
# The one that matters most: this file opens cleanly and reports a full duration, so a missing
# clean-EOF check yields a short transcript that exits 0 and looks complete.
check "truncated mid-read"      65 "$BINARY" -q "${FIXTURES}/truncated-midread.m4a"
check "missing file"            66 "$BINARY" -q "${FIXTURES}/definitely-absent.mp4"
check "directory as input"      66 "$BINARY" -q "$FIXTURES"

echo
echo "Locales"
check "unsupported locale"      78 "$BINARY" -q --locale xx-XX "${FIXTURES}/speech-mono-16k.wav"

echo
echo "Argument validation"
check "track out of range"      64 "$BINARY" -q --track 9 "${FIXTURES}/two-track.mov"
check "negative track"          64 "$BINARY" -q --track -1 "${FIXTURES}/two-track.mov"
check "--track with --first-track" 64 "$BINARY" -q --track 0 --first-track "${FIXTURES}/two-track.mov"
check "--output with --list-tracks" 64 "$BINARY" --list-tracks -o /tmp/unused "${FIXTURES}/two-track.mov"
check "no file argument"        64 "$BINARY" -q
check "invalid format value"    64 "$BINARY" -q -f wav "${FIXTURES}/speech-mono-16k.wav"
check "zero max cue seconds"    64 "$BINARY" -q -f srt --max-cue-seconds 0 "${FIXTURES}/speech-mono-16k.wav"

echo
echo "Interruption"
# Ctrl-C must exit 130 and write nothing. Exiting 0 with a partial transcript is the worst failure
# this tool has, because the output looks complete.
INTERRUPT_TARGET="/tmp/transcribe-sweep-interrupt.srt"
rm -f "$INTERRUPT_TARGET"
if [[ -f "${FIXTURES}/long-10min.m4a" ]]; then
    "$BINARY" -f srt -o "$INTERRUPT_TARGET" "${FIXTURES}/long-10min.m4a" >/dev/null 2>&1 &
    INTERRUPT_PID=$!
    sleep 3
    kill -INT "$INTERRUPT_PID" 2>/dev/null || true
    # A watchdog, in case the interrupt path ever deadlocks again rather than exiting. Disowned so
    # the shell does not announce its termination once it is no longer needed.
    ( sleep 30; kill -9 "$INTERRUPT_PID" 2>/dev/null || true ) &
    WATCHDOG_PID=$!
    disown "$WATCHDOG_PID" 2>/dev/null || true
    INTERRUPT_RC=0
    wait "$INTERRUPT_PID" || INTERRUPT_RC=$?
    kill "$WATCHDOG_PID" 2>/dev/null || true

    if [[ "$INTERRUPT_RC" -eq 130 ]]; then
        PASSED=$((PASSED + 1)); printf '  \033[32mok\033[0m   %-44s exit=130\n' "SIGINT exits 130"
    else
        FAILED=$((FAILED + 1))
        printf '  \033[31mFAIL\033[0m %-44s exit=%s expected=130%s\n' "SIGINT exits 130" "$INTERRUPT_RC" \
            "$( [[ "$INTERRUPT_RC" -eq 137 ]] && echo ' (hung)' )"
    fi

    if [[ ! -f "$INTERRUPT_TARGET" ]]; then
        PASSED=$((PASSED + 1)); printf '  \033[32mok\033[0m   %-44s\n' "SIGINT writes no output file"
    else
        FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m %-44s\n' "SIGINT wrote a partial transcript"
        rm -f "$INTERRUPT_TARGET"
    fi
else
    printf '  \033[33mskip\033[0m %-44s (no long-10min.m4a)\n' "interruption"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
    printf '\033[32m%d passed, 0 failed\033[0m\n' "$PASSED"
else
    printf '\033[31m%d passed, %d FAILED\033[0m\n' "$PASSED" "$FAILED"
    exit 1
fi
