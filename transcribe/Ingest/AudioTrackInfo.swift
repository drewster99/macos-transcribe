import AVFoundation
import CoreMedia
import Foundation

/// Everything `--list-tracks` shows about one audio track, and everything track selection needs to
/// pick one.
struct AudioTrackInfo: Sendable, Identifiable {

    /// Zero-based position among the file's audio tracks. This is the value `--track` takes, so it
    /// counts audio tracks only — not the video and subtitle tracks interleaved among them.
    let ordinal: Int

    /// The track's persistent identifier, used to re-resolve the track inside the ingest sequence
    /// without carrying a non-Sendable `AVAssetTrack` across an isolation boundary.
    let trackID: CMPersistentTrackID

    /// ISO 639-2 language code declared by the container, e.g. `"eng"`.
    let languageCode: String?

    /// BCP-47 language tag declared by the container, e.g. `"en-US"`. Richer than `languageCode`
    /// when present because it can carry region and script.
    let extendedLanguageTag: String?

    /// Average bitrate in bits per second, as estimated by the container.
    let estimatedDataRate: Float

    /// The track's position on the asset timeline. A non-zero start is normal in muxed video and is
    /// why transcription timestamps must be asset-relative, not stream-relative.
    let timeRange: CMTimeRange

    /// Whether the container marks this track as enabled for playback.
    let isEnabled: Bool

    /// Whether this system can decode the track.
    let isDecodable: Bool

    /// The codec, e.g. `kAudioFormatMPEG4AAC`.
    let codec: FourCharCode

    let sampleRate: Double
    let channelCount: UInt32

    /// How many distinct format descriptions the track carries. More than one means the audio
    /// format changes partway through, which invalidates the assumption that one negotiated output
    /// format covers the whole track.
    let formatDescriptionCount: Int

    var id: Int { ordinal }

    /// True when the track's format changes partway through.
    var hasFormatChanges: Bool { formatDescriptionCount > 1 }

    /// The best available human-readable language label, preferring the more specific tag.
    var languageDescription: String {
        extendedLanguageTag ?? languageCode ?? "und"
    }

    /// The codec as its four-character code, e.g. `"aac "`. Falls back to a hex representation for
    /// codecs whose FourCC is not printable ASCII.
    var codecDescription: String {
        let bytes = [
            UInt8((codec >> 24) & 0xFF),
            UInt8((codec >> 16) & 0xFF),
            UInt8((codec >> 8) & 0xFF),
            UInt8(codec & 0xFF),
        ]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            return String(format: "0x%08x", codec)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A single-line description for `--list-tracks`.
    ///
    /// The leading index is printed bare so that the number the user reads is literally the value
    /// they pass to `--track`.
    var listingLine: String {
        var fields = [
            "[\(ordinal)]",
            languageDescription.padding(toLength: max(8, languageDescription.count), withPad: " ", startingAt: 0),
            codecDescription,
            "\(Int(sampleRate.rounded())) Hz",
            "\(channelCount)ch",
        ]
        if estimatedDataRate > 0 {
            fields.append("\(Int((estimatedDataRate / 1000).rounded())) kbps")
        }
        fields.append(Self.timecodeRange(timeRange))
        if !isEnabled { fields.append("(disabled)") }
        if !isDecodable { fields.append("(not decodable)") }
        if hasFormatChanges { fields.append("(\(formatDescriptionCount) format changes)") }
        return fields.joined(separator: "  ")
    }

    private static func timecodeRange(_ range: CMTimeRange) -> String {
        guard range.start.isNumeric, range.duration.isNumeric else { return "unknown range" }
        return "\(timecode(range.start.seconds))–\(timecode(range.end.seconds))"
    }

    private static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "??:??:??" }
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
