import Foundation
import Speech

/// Resolves locales and makes sure the on-device model for one is present.
enum SpeechModelCatalog {

    /// One row of `--list-locales`.
    struct LocaleListing: Sendable {
        let identifier: String
        let isInstalled: Bool
        let displayName: String

        var listingLine: String {
            let marker = isInstalled ? "installed" : "available"
            return "\(identifier.padding(toLength: max(8, identifier.count), withPad: " ", startingAt: 0))  "
                + "\(marker.padding(toLength: 9, withPad: " ", startingAt: 0))  \(displayName)"
        }
    }

    /// Maps a requested locale onto one the transcriber actually supports.
    ///
    /// An unsupported locale is an error rather than a fall back to something nearby: silently
    /// transcribing Portuguese audio with a Spanish model would produce plausible-looking nonsense.
    static func resolveLocale(requested: String?) async throws -> Locale {
        let desired = requested.map(Locale.init(identifier:)) ?? Locale.current

        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: desired) else {
            let available = await SpeechTranscriber.supportedLocales
                .map { $0.identifier(.bcp47) }
                .sorted()
            let requestedDescription = requested ?? "\(desired.identifier(.bcp47)) (your system locale)"
            throw TranscribeError.message(
                "On-device transcription does not support \(requestedDescription).",
                hint: "Supported: \(available.joined(separator: ", ")). Use --locale to choose one.",
                code: .localeUnavailable
            )
        }
        return supported
    }

    /// Every supported locale, marked with whether its model is already on this Mac.
    static func localeListings() async -> [LocaleListing] {
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        return await SpeechTranscriber.supportedLocales
            .map { locale in
                let identifier = locale.identifier(.bcp47)
                return LocaleListing(
                    identifier: identifier,
                    isInstalled: installed.contains(identifier),
                    displayName: Locale.current.localizedString(forIdentifier: locale.identifier) ?? identifier
                )
            }
            .sorted { $0.identifier < $1.identifier }
    }

    /// Ensures the speech assets backing `transcriber` are installed, downloading them if needed.
    ///
    /// - Returns: True if the locale's model had to be downloaded.
    @discardableResult
    static func ensureModelInstalled(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        reporter: StderrReporter
    ) async throws -> Bool {
        guard let request = try await installationRequest(for: transcriber) else { return false }

        // Whether the locale's model is present is read from `installedLocales`. The other two
        // candidates are not usable for this: `assetInstallationRequest` returns a non-nil request
        // even when everything is already installed, and `status(forModules:)` reports `.supported`
        // for locales `installedLocales` lists as installed. The request is therefore always run —
        // it is idempotent and returns in milliseconds when there is nothing to fetch — but only an
        // actually-missing model is announced.
        let modelIsMissing = await !isInstalled(locale)
        if modelIsMissing {
            try await reserveLocale(locale)
            reporter.notice("Downloading the \(locale.identifier(.bcp47)) speech model…")
        }

        // Progress is sampled from Foundation.Progress while the install runs; the request is
        // Sendable, so polling it from a sibling task is safe. The first sample is delayed so that
        // an already-satisfied request does not flash a progress line for a download that is not
        // happening — while a genuinely slow install still reports itself.
        let progressReporting = Task {
            try? await Task.sleep(for: .milliseconds(750))
            while !Task.isCancelled {
                reporter.reportDownloadProgress(
                    fraction: request.progress.fractionCompleted,
                    label: "downloading speech model"
                )
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer {
            progressReporting.cancel()
            reporter.clearProgressLine()
        }

        do {
            try await request.downloadAndInstall()
        } catch {
            throw TranscribeError.message(
                "Could not install the \(locale.identifier(.bcp47)) speech model: \(error.localizedDescription)",
                hint: "Check your network connection and available disk space.",
                code: .localeUnavailable
            )
        }

        if modelIsMissing {
            reporter.notice("Speech model installed.")
        }
        return modelIsMissing
    }

    /// Whether this locale's model is already on this Mac.
    static func isInstalled(_ locale: Locale) async -> Bool {
        let target = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == target }
    }

    // MARK: - Private

    private static func installationRequest(for transcriber: SpeechTranscriber) async throws -> AssetInstallationRequest? {
        do {
            return try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch {
            throw TranscribeError(
                "Could not determine which speech assets are needed: \(error.localizedDescription)",
                code: .localeUnavailable
            )
        }
    }

    /// Claims one of this Mac's limited locale reservations for `locale`.
    private static func reserveLocale(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier == locale.identifier }) else { return }

        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            // Reservations are a fixed-size pool, so this is a real condition a user can hit rather
            // than a bug, and the remedy is specific enough to name.
            let inUse = reserved.map { $0.identifier(.bcp47) }.joined(separator: ", ")
            throw TranscribeError.message(
                "Could not reserve \(locale.identifier(.bcp47)): \(error.localizedDescription)",
                hint: "This Mac allows \(AssetInventory.maximumReservedLocales) reserved locales "
                    + "and currently holds \(reserved.count) (\(inUse)).",
                code: .localeUnavailable
            )
        }
    }
}
