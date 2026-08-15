import AVFoundation
import CoreMedia
import Foundation

/// Converts decoded sample buffers into the `AVAudioPCMBuffer` values the analyzer consumes, and
/// keeps their timestamps monotonic.
struct PCMBufferFactory {

    let format: AVAudioFormat

    /// Guards against decoder timestamps that step backwards between buffers.
    private var timeline: MonotonicBufferTimeline

    init(format: AVAudioFormat) {
        self.format = format
        self.timeline = MonotonicBufferTimeline(sampleRate: format.sampleRate)
    }

    /// Builds a PCM buffer and its start time from a decoded sample buffer.
    ///
    /// Returns nil for buffers that carry no audio frames. Marker-only sample buffers are a normal
    /// part of the stream and simply have nothing to transcribe.
    mutating func makeInput(from sample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) throws -> PCMInput? {
        guard let audio = CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>(sample) else { return nil }
        let frameCount = audio.sampleCount
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw TranscribeError(
                "Could not allocate an audio buffer for \(frameCount) frames.",
                code: .transcriptionFailed
            )
        }

        // Set before the copy, not after: `mutableAudioBufferList` derives its `mDataByteSize`
        // fields from `frameLength`, so a buffer left at zero length advertises a zero-byte
        // destination and CoreMedia rejects the copy with a missing-parameter error.
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // The data is copied rather than aliased because the analyzer may hold the buffer after
        // this call returns, outliving the sample buffer that backed it. At 16 kHz mono that is
        // 32 KB per second of audio.
        do {
            try audio.copyPCMData(fromRange: 0..<frameCount, into: buffer.mutableAudioBufferList)
        } catch {
            throw TranscribeError(
                "Could not read decoded audio: \(error.localizedDescription)",
                code: .transcriptionFailed
            )
        }

        let startTime = timeline.startTime(for: audio.presentationTimeStamp, frameCount: frameCount)
        return PCMInput(buffer: buffer, startTime: startTime, formatDescription: audio.formatDescription)
    }
}

/// One buffer of audio ready for the analyzer, with the media-timeline position it came from.
struct PCMInput {
    let buffer: AVAudioPCMBuffer
    let startTime: CMTime

    /// The format the decoder actually produced, checked against the negotiated format so a
    /// mid-file format change cannot silently corrupt the transcript.
    let formatDescription: CMFormatDescription
}
