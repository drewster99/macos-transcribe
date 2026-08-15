import AVFoundation
import CoreMedia
import Foundation

/// An opened media file and its audio tracks.
///
/// Everything that can disqualify a file — missing, unreadable, DRM-protected, no audio — is
/// checked here, before any decoding is set up, so failures surface with an accurate message rather
/// than as an opaque error from deep inside the analyzer.
struct MediaSource: Sendable {

    let url: URL

    /// `AVURLAsset` is Sendable, unlike `AVAsset`, which is what lets this whole struct cross into
    /// the ingest sequence.
    let asset: AVURLAsset

    /// Total asset duration. May be indefinite for malformed or streaming-oriented files.
    let duration: CMTime

    /// The file's audio tracks in container order.
    let audioTracks: [AudioTrackInfo]

    /// Opens a media file and reads enough of it to describe its audio tracks.
    static func open(path: String, reporter: StderrReporter) async throws -> MediaSource {
        let url = try resolveInputURL(path)
        let asset = AVURLAsset(url: url)

        // AVURLAsset construction is lazy and never fails, so the first real parse happens here.
        let isReadable: Bool
        do {
            isReadable = try await asset.load(.isReadable)
        } catch {
            throw TranscribeError.message(
                "Cannot read '\(path)': \(error.localizedDescription)",
                hint: "Is it a media file?",
                code: .unusableInput
            )
        }
        guard isReadable else {
            throw TranscribeError.message(
                "'\(path)' is not a recognized media file.",
                hint: "Supported inputs are audio files and video files containing audio.",
                code: .unusableInput
            )
        }

        // Checked before any decoding is configured — a protected asset can advertise perfectly
        // ordinary tracks and then yield nothing.
        if try await asset.load(.hasProtectedContent) {
            throw TranscribeError(
                "'\(path)' is DRM-protected and cannot be transcribed.",
                code: .protectedContent
            )
        }

        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw TranscribeError.message(
                "'\(path)' contains no audio tracks.",
                hint: "Only files with audio can be transcribed.",
                code: .unusableInput
            )
        }

        var infos: [AudioTrackInfo] = []
        infos.reserveCapacity(tracks.count)
        // Loaded sequentially rather than in a task group: AVAssetTrack is not Sendable, so it
        // cannot be handed to a concurrent child task. Track counts are small and AVFoundation
        // caches each property once loaded.
        for (ordinal, track) in tracks.enumerated() {
            infos.append(try await describe(track, ordinal: ordinal))
        }

        for info in infos where info.hasFormatChanges {
            reporter.warn(
                "Audio track \(info.ordinal) changes format \(info.formatDescriptionCount - 1) time(s) mid-file; "
                + "transcription may be incomplete."
            )
        }

        return MediaSource(url: url, asset: asset, duration: duration, audioTracks: infos)
    }

    /// Chooses the track to transcribe, reporting on any it passes over.
    func selectTrack(_ selection: TrackSelection, reporter: StderrReporter) throws -> AudioTrackInfo {
        guard let index = selection.resolvedIndex(audioTrackCount: audioTracks.count) else {
            throw TranscribeError.message(
                "No audio track at index \(selection.requestedIndexDescription).",
                hint: "This file has \(audioTracks.count) audio track(s), numbered 0 to \(audioTracks.count - 1). "
                    + "Use --list-tracks to see them.",
                code: .usage
            )
        }
        let selected = audioTracks[index]

        if selection.warnsAboutUnselectedTracks && audioTracks.count > 1 {
            let others = audioTracks.filter { $0.ordinal != selected.ordinal }
                .map { "\($0.ordinal) (\($0.languageDescription))" }
                .joined(separator: ", ")
            reporter.warn(
                "This file has \(audioTracks.count) audio tracks; transcribing track "
                + "\(selected.ordinal) (\(selected.languageDescription)). Skipped: \(others). "
                + "Use --track to choose, or --first-track to silence this."
            )
        }

        guard selected.isDecodable else {
            throw TranscribeError(
                "Audio track \(selected.ordinal) (\(selected.codecDescription)) cannot be decoded on this system.",
                code: .unusableInput
            )
        }
        return selected
    }

    // MARK: - Private

    private static func resolveInputURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw TranscribeError("No such file: '\(path)'.", code: .unreadableInput)
        }
        guard !isDirectory.boolValue else {
            throw TranscribeError("'\(path)' is a directory, not a media file.", code: .unreadableInput)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw TranscribeError("Permission denied reading '\(path)'.", code: .unreadableInput)
        }
        return url
    }

    private static func describe(_ track: AVAssetTrack, ordinal: Int) async throws -> AudioTrackInfo {
        let formatDescriptions = try await track.load(.formatDescriptions)
        let primaryFormat = formatDescriptions.first
        let streamDescription = primaryFormat?.audioStreamBasicDescription

        return AudioTrackInfo(
            ordinal: ordinal,
            trackID: track.trackID,
            languageCode: try await track.load(.languageCode),
            extendedLanguageTag: try await track.load(.extendedLanguageTag),
            estimatedDataRate: try await track.load(.estimatedDataRate),
            timeRange: try await track.load(.timeRange),
            isEnabled: try await track.load(.isEnabled),
            isDecodable: try await track.load(.isDecodable),
            codec: primaryFormat?.mediaSubType.rawValue ?? 0,
            sampleRate: streamDescription?.mSampleRate ?? 0,
            channelCount: streamDescription?.mChannelsPerFrame ?? 0,
            formatDescriptionCount: formatDescriptions.count
        )
    }
}

private extension TrackSelection {
    /// How the requested track reads back in an error message.
    var requestedIndexDescription: String {
        switch self {
        case .index(let requested): "\(requested)"
        case .defaultTrack, .firstTrackExplicitly: "0"
        }
    }
}
