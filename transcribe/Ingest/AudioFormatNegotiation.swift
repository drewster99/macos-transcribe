import AVFoundation
import CoreMedia
import Foundation
import Speech

/// The audio format the analyzer wants, and the reader settings that produce it.
///
/// The settings are derived from `analyzerFormat` on demand rather than stored, so there is exactly
/// one place the reader's configuration comes from and it cannot drift from what the analyzer was
/// promised.
struct NegotiatedAudioFormat: Sendable {

    /// The format `SpeechAnalyzer` selected. In practice this is 16 kHz mono 16-bit interleaved
    /// PCM, but nothing here assumes that — it is read back from the framework on every run.
    let analyzerFormat: AVAudioFormat

    /// Whether the reader needs an explicit destination channel layout.
    ///
    /// Required when the source has more than two channels: `AVAssetReaderTrackOutput` will not
    /// invent a downmix for, say, 5.1 to mono without being told what the destination looks like.
    private let needsExplicitChannelLayout: Bool

    /// `outputSettings` for `AVAssetReaderTrackOutput`, decoding straight into `analyzerFormat`.
    ///
    /// Decoding directly into the target avoids a second `AVAudioConverter` stage. That matters for
    /// more than tidiness: a converter doing sample-rate conversion produces a different frame count
    /// than it consumes, so input timestamps can no longer map to output timestamps directly, and
    /// any residual priming latency accumulates as drift in subtitle timings.
    var readerOutputSettings: [String: Any] {
        var settings = analyzerFormat.settings
        if needsExplicitChannelLayout, settings[AVChannelLayoutKey] == nil,
           let layout = Self.channelLayoutData(forChannelCount: analyzerFormat.channelCount) {
            settings[AVChannelLayoutKey] = layout
        }
        return settings
    }

    /// Negotiates the format for one transcriber and one source track.
    ///
    /// - Parameters:
    ///   - transcriber: The module whose format requirements must be met.
    ///   - sourceFormat: The track's native format, offered as a hint.
    ///   - sourceChannelCount: Channel count of the source track, which decides whether an explicit
    ///     channel layout is needed to describe the downmix.
    static func negotiate(
        for transcriber: SpeechTranscriber,
        sourceFormat: AVAudioFormat?,
        sourceChannelCount: UInt32
    ) async throws -> NegotiatedAudioFormat {
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: sourceFormat
        ) else {
            throw TranscribeError(
                "No audio format is available for on-device transcription in this locale.",
                code: .localeUnavailable
            )
        }

        guard analyzerFormat.settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatLinearPCM else {
            throw TranscribeError(
                "The analyzer requested a non-PCM audio format, which cannot be decoded directly.",
                code: .transcriptionFailed
            )
        }

        let negotiated = NegotiatedAudioFormat(
            analyzerFormat: analyzerFormat,
            needsExplicitChannelLayout: sourceChannelCount > 2
        )
        try negotiated.validateSettingsDescribeAnalyzerFormat()
        return negotiated
    }

    /// Confirms the settings dictionary really describes `analyzerFormat` before it reaches
    /// AVFoundation.
    ///
    /// `AVAssetReaderTrackOutput.init(track:outputSettings:)` raises an Objective-C exception for
    /// settings it dislikes. That exception cannot be caught from Swift, so it would be a process
    /// crash rather than a thrown error — which makes checking beforehand the only option.
    private func validateSettingsDescribeAnalyzerFormat() throws {
        guard let roundTripped = AVAudioFormat(settings: readerOutputSettings) else {
            throw TranscribeError(
                "Could not express the analyzer's audio format as reader settings.",
                code: .transcriptionFailed
            )
        }
        let expected = analyzerFormat.streamDescription.pointee
        let actual = roundTripped.streamDescription.pointee
        guard actual.mSampleRate == expected.mSampleRate,
              actual.mChannelsPerFrame == expected.mChannelsPerFrame,
              actual.mBitsPerChannel == expected.mBitsPerChannel,
              actual.mFormatID == expected.mFormatID,
              actual.mFormatFlags == expected.mFormatFlags else {
            throw TranscribeError(
                "Reader settings do not round-trip to the analyzer's audio format "
                + "(\(Int(expected.mSampleRate)) Hz, \(expected.mChannelsPerFrame)ch, "
                + "\(expected.mBitsPerChannel)-bit).",
                code: .transcriptionFailed
            )
        }
    }

    /// An `AudioChannelLayout` describing a plain N-channel destination, as `Data`.
    private static func channelLayoutData(forChannelCount channels: AVAudioChannelCount) -> Data? {
        let tag: AudioChannelLayoutTag
        switch channels {
        case 1: tag = kAudioChannelLayoutTag_Mono
        case 2: tag = kAudioChannelLayoutTag_Stereo
        default: return nil
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        return withUnsafeBytes(of: &layout) { Data($0) }
    }
}
