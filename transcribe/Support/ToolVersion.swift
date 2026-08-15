import Foundation

/// The tool's version, sourced from the Info.plist embedded in the binary's `__TEXT,__info_plist`
/// section.
///
/// A command-line tool has no bundle directory, so the plist is compiled into the executable itself
/// via `CREATE_INFOPLIST_SECTION_IN_BINARY`. That plist is generated from `MARKETING_VERSION` in the
/// Xcode project, which keeps the release script and `--version` reading from one place rather than
/// two that can drift.
enum ToolVersion {

    /// The marketing version string, e.g. `"1.0.2"`.
    static let current: String = {
        guard let version = embeddedInfoDictionary()?["CFBundleShortVersionString"] as? String else {
            // The plist is embedded at build time, so its absence is a build-configuration bug, not
            // a runtime condition a user can cause or recover from.
            fatalError("Missing CFBundleShortVersionString: CREATE_INFOPLIST_SECTION_IN_BINARY is not set")
        }
        return version
    }()

    /// The build number, e.g. `"14"`.
    static let build: String = {
        guard let build = embeddedInfoDictionary()?["CFBundleVersion"] as? String else {
            fatalError("Missing CFBundleVersion: CREATE_INFOPLIST_SECTION_IN_BINARY is not set")
        }
        return build
    }()

    /// The string shown by `--version`.
    static var displayString: String { "transcribe \(current) (build \(build))" }

    /// Reads the embedded plist.
    ///
    /// `Bundle.main.infoDictionary` is tried first because it is the documented API; for a bare
    /// executable it reads the embedded section rather than a bundle. `CFBundleGetInfoDictionary`
    /// is the direct Core Foundation route, kept as a second attempt so a `Bundle` that resolves to
    /// the enclosing directory instead of the binary cannot silently produce a nil version.
    private static func embeddedInfoDictionary() -> [String: Any]? {
        if let info = Bundle.main.infoDictionary, info["CFBundleShortVersionString"] != nil {
            return info
        }
        guard let mainBundle = CFBundleGetMainBundle(),
              let info = CFBundleGetInfoDictionary(mainBundle) as? [String: Any] else {
            return nil
        }
        return info
    }
}
