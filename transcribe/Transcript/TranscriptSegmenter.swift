import Foundation

/// Groups timed words into subtitle cues.
enum TranscriptSegmenter {

    /// The thresholds that decide where one cue ends and the next begins.
    ///
    /// These values were tuned against Apple's speech output in a sibling project; they are not
    /// arbitrary. The word caps in particular exist as a safety net: some recognition runs come back
    /// with no sentence-ending punctuation at all, and without a cap that produces a single cue as
    /// long as the whole recording.
    struct Limits: Equatable {

        /// A silence at least this long ends a cue. Long enough to skip the pauses inside a
        /// sentence, short enough to catch the pause between two.
        var pauseGap: TimeInterval

        /// Once a cue has reached `softWordCap` words, a pause this long is enough to end it.
        var softPause: TimeInterval

        /// The word count past which `softPause` starts applying.
        var softWordCap: Int

        /// A cue never exceeds this many words, whatever the punctuation and pauses say.
        var hardWordCap: Int

        /// A cue never exceeds this duration, in seconds.
        var maximumCueDuration: TimeInterval

        static let `default` = Limits(
            pauseGap: 0.6,
            softPause: 0.2,
            softWordCap: 8,
            hardWordCap: 14,
            maximumCueDuration: 6.0
        )

        /// The default limits with the two user-facing values replaced.
        func overriding(maximumCueDuration: TimeInterval, hardWordCap: Int) -> Limits {
            var limits = self
            limits.maximumCueDuration = maximumCueDuration
            limits.hardWordCap = hardWordCap
            // The soft cap must stay below the hard cap or it can never fire, which would silently
            // disable pause-based splitting for anyone who lowered --max-words-per-cue.
            limits.softWordCap = min(softWordCap, max(1, hardWordCap - 1))
            return limits
        }
    }

    /// The grid Apple's speech recognizer quantizes word timestamps onto.
    ///
    /// A word's reported start can land up to one quantum after its true onset, which matters when
    /// a cue boundary falls on that word: without lead-in, the first syllable gets clipped.
    static let timingGrid: TimeInterval = 0.06

    /// Punctuation that ends a sentence, and therefore a cue.
    private static let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]

    /// Trailing characters that can follow sentence punctuation without changing that it ended a
    /// sentence.
    private static let closingCharacters = CharacterSet(charactersIn: "\"”'’)]»")

    /// Regroups words into cues sized for reading.
    ///
    /// Splits on the first condition that applies: sentence-ending punctuation, a long pause, the
    /// cue duration limit, the hard word cap, or a shorter pause once the cue is already long
    /// enough. Falling back through all five is what keeps a recognition run that returns no
    /// punctuation at all from becoming one cue the length of the recording.
    static func makeCues(from words: [TranscribedWord], limits: Limits) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }

        var cues: [TranscriptSegment] = []
        var current: [TranscribedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(TranscriptSegment(
                text: current.map(\.text).joined(separator: " "),
                start: first.start,
                end: max(last.end, first.start),
                words: current
            ))
            current.removeAll(keepingCapacity: true)
        }

        for (index, word) in words.enumerated() {
            current.append(word)

            let gapAfter: TimeInterval = index + 1 < words.count
                ? max(0, words[index + 1].start - word.end)
                : .infinity
            let cueDuration = word.end - (current.first?.start ?? word.start)

            if endsSentence(word.text) {
                flush()
            } else if gapAfter >= limits.pauseGap {
                flush()
            } else if cueDuration >= limits.maximumCueDuration {
                flush()
            } else if current.count >= limits.hardWordCap {
                flush()
            } else if current.count >= limits.softWordCap, gapAfter >= limits.softPause {
                flush()
            }
        }
        flush()
        return cues
    }

    private static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.unicodeScalars.allSatisfy(closingCharacters.contains) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return sentenceEndings.contains(last)
    }
}
