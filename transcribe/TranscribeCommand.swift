import ArgumentParser
import Foundation
import Speech

// The domain types stay free of any ArgumentParser dependency so the transcription core can be
// built and exercised without the CLI layer. These are the only two bridges into it.
extension OutputFormat: ExpressibleByArgument {}

extension TranscribeExitCode {
    var asExitCode: ExitCode { ExitCode(rawValue) }
}

@main
struct TranscribeCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio file, or a video file's audio, using on-device speech recognition.",
        discussion: """
            The transcript is written to standard output unless --output is given. Warnings and \
            progress go to standard error, so the output is safe to redirect or pipe.

            Speech models are downloaded per locale on first use and cached by the system.
            """,
        version: ToolVersion.displayString
    )

    // MARK: - Input

    @Argument(
        help: ArgumentHelp("The audio or video file to transcribe.", valueName: "file"),
        completion: .file()
    )
    var inputPath: String?

    // MARK: - Output

    @Option(
        name: [.short, .long],
        help: ArgumentHelp("Write the transcript to this path instead of standard output.", valueName: "path"),
        completion: .file()
    )
    var output: String?

    // The value name carries the choices because ArgumentParser echoes only the value name when a
    // value is missing ("Missing value for '--format <...>'"). Spelling them out here means that
    // error, and the usage line, both say what the options actually are.
    @Option(
        name: [.short, .long],
        help: ArgumentHelp(
            "Transcript format.",
            valueName: OutputFormat.allCases.map(\.rawValue).joined(separator: "|")
        )
    )
    var format: OutputFormat = .txt

    @Option(
        name: [.short, .long],
        help: ArgumentHelp("BCP-47 language tag, e.g. en-US. Defaults to the system locale.", valueName: "locale")
    )
    var locale: String?

    // MARK: - Track selection

    @Option(help: ArgumentHelp("Zero-based index of the audio track to transcribe.", valueName: "n"))
    var track: Int?

    @Flag(help: "Use the first audio track without warning when the file has several.")
    var firstTrack = false

    // MARK: - Informational modes

    @Flag(help: "List the input's audio tracks and exit.")
    var listTracks = false

    @Flag(help: "List locales supported by on-device transcription and exit.")
    var listLocales = false

    @Flag(help: "Download and install the speech model for the selected locale, then exit.")
    var installModel = false

    // MARK: - Subtitle tuning

    @Option(help: ArgumentHelp("Maximum duration of one subtitle cue, in seconds.", valueName: "seconds"))
    var maxCueSeconds: Double = TranscriptSegmenter.Limits.default.maximumCueDuration

    @Option(help: ArgumentHelp("Maximum number of words in one subtitle cue.", valueName: "n"))
    var maxWordsPerCue: Int = TranscriptSegmenter.Limits.default.hardWordCap

    // MARK: - Verbosity

    @Flag(name: [.short, .long], help: "Suppress warnings and progress on standard error.")
    var quiet = false

    // MARK: - Validation

    func validate() throws {
        if track != nil && firstTrack {
            throw ValidationError("--track and --first-track cannot be used together.")
        }
        if let track, track < 0 {
            throw ValidationError("--track must be zero or greater; got \(track).")
        }
        if maxCueSeconds <= 0 {
            throw ValidationError("--max-cue-seconds must be greater than zero.")
        }
        if maxWordsPerCue < 1 {
            throw ValidationError("--max-words-per-cue must be at least 1.")
        }
        if mode.requiresInputFile && inputPath == nil {
            throw ValidationError("Missing expected argument '<file>'.")
        }
        if mode != .transcribe && output != nil {
            throw ValidationError("--output applies only when transcribing.")
        }
    }

    /// What this invocation is actually being asked to do.
    ///
    /// Derived once from the mode flags so the rest of the command branches on a single value
    /// rather than re-reading three independent booleans that can contradict each other.
    private var mode: InvocationMode {
        if listLocales { return .listLocales }
        if listTracks { return .listTracks }
        if installModel { return .installModel }
        return .transcribe
    }

    private enum InvocationMode: Equatable {
        case transcribe
        case listTracks
        case listLocales
        case installModel

        var requiresInputFile: Bool {
            switch self {
            case .transcribe, .listTracks: true
            case .listLocales, .installModel: false
            }
        }
    }

    private var trackSelection: TrackSelection {
        if let track { return .index(track) }
        if firstTrack { return .firstTrackExplicitly }
        return .defaultTrack
    }

    // MARK: - Execution

    func run() async throws {
        let reporter = StderrReporter(quiet: quiet)
        // The progress indicator owns a line of the terminal; every exit path has to give it back.
        defer { reporter.clearProgressLine() }

        // The work runs in a child task so Ctrl-C can cancel it cooperatively, letting the audio
        // reader shut down from the context that owns it. The flag travels with it because the
        // analyzer iterates the audio from a task of its own, where task cancellation is not
        // observable.
        let interrupts = InterruptFlag()
        let work = Task { try await execute(reporter: reporter, interrupts: interrupts) }
        let monitor = InterruptMonitor {
            interrupts.set()
            work.cancel()
        }
        defer { monitor.stop() }

        do {
            try await work.value
        } catch let error as TranscribeError {
            reporter.error(error.description)
            throw error.exitCode.asExitCode
        } catch is CancellationError {
            // Partial output is deliberately not written: a transcript that stops early is
            // indistinguishable from a complete one once it leaves this process.
            reporter.error("Interrupted. No transcript was written.")
            throw TranscribeExitCode.interrupted.asExitCode
        }
    }

    private func execute(reporter: StderrReporter, interrupts: InterruptFlag) async throws {
        switch mode {
        case .listLocales:
            try await listSupportedLocales()
        case .listTracks:
            try await listAudioTracks(reporter: reporter)
        case .installModel:
            try await installSpeechModel(reporter: reporter)
        case .transcribe:
            try await runTranscription(reporter: reporter, interrupts: interrupts)
        }
    }

    private func listAudioTracks(reporter: StderrReporter) async throws {
        guard let inputPath else {
            throw TranscribeError("Missing expected argument '<file>'.", code: .usage)
        }
        let source = try await MediaSource.open(path: inputPath, reporter: reporter)
        for track in source.audioTracks {
            print(track.listingLine)
        }
    }

    private func listSupportedLocales() async throws {
        for listing in await SpeechModelCatalog.localeListings() {
            print(listing.listingLine)
        }
    }

    private func installSpeechModel(reporter: StderrReporter) async throws {
        try await SpeechAuthorization.requireAuthorization()
        let resolved = try await SpeechModelCatalog.resolveLocale(requested: locale)
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let didDownload = try await SpeechModelCatalog.ensureModelInstalled(
            for: transcriber,
            locale: resolved,
            reporter: reporter
        )
        if !didDownload {
            // --install-model is explicitly about the model, so it confirms the outcome even when
            // there was nothing to do. Ordinary transcription stays silent in this case.
            reporter.notice("The \(resolved.identifier(.bcp47)) speech model is already installed.")
        }
    }

    private func runTranscription(reporter: StderrReporter, interrupts: InterruptFlag) async throws {
        guard let inputPath else {
            throw TranscribeError("Missing expected argument '<file>'.", code: .usage)
        }

        try await SpeechAuthorization.requireAuthorization()
        let resolvedLocale = try await SpeechModelCatalog.resolveLocale(requested: locale)
        let source = try await MediaSource.open(path: inputPath, reporter: reporter)
        let selectedTrack = try source.selectTrack(trackSelection, reporter: reporter)

        let engine = TranscriptionEngine(reporter: reporter, interrupts: interrupts)
        let transcript = try await engine.transcribe(
            source: source,
            track: selectedTrack,
            locale: resolvedLocale,
            collectWordTimings: format.needsWordTimings
        )

        if transcript.isEmpty {
            reporter.warn("No speech was recognized in this audio.")
        }

        let rendered = TranscriptRenderer(
            format: format,
            limits: TranscriptSegmenter.Limits.default.overriding(
                maximumCueDuration: maxCueSeconds,
                hardWordCap: maxWordsPerCue
            )
        ).render(transcript)

        try write(rendered, reporter: reporter)
    }

    private func write(_ contents: String, reporter: StderrReporter) throws {
        guard let output else {
            print(contents, terminator: "")
            return
        }
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw TranscribeError(
                "Could not write to '\(output)': \(error.localizedDescription)",
                code: .unreadableInput
            )
        }
    }
}
