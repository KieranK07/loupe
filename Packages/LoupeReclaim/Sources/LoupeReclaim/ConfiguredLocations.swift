import Foundation

/// The two catalog entries whose location a user can move, resolved without
/// running anything.
///
/// The general rule here is the same one §B.2 applies to `$HOME`: a value that a
/// parent process or a preference file can set is a value an attacker can set,
/// so it is validated before it is allowed to redirect a deletion. A relocated
/// cache must still land somewhere a cache plausibly lives.
enum ConfiguredLocations {

    enum Resolution: Sendable, Hashable {
        /// No override; use the catalog's default patterns.
        case `default`
        case relocated(String)
        /// An override exists but Loupe will not act on it. The entry reports
        /// its location as unknown rather than scanning the default, which would
        /// be scanning somewhere the user is not using.
        case unusable(reason: String)
    }

    /// Directories a relocated cache is allowed to be in.
    ///
    /// Deliberately narrow. Honouring an arbitrary `UV_CACHE_DIR` would let
    /// anything that can set an environment variable nominate a folder for
    /// deletion, and "the user's own Documents folder" is a perfectly valid
    /// value for it to nominate.
    static func plausibleCacheParents(home: URL) -> [[String]] {
        let h = home.path(percentEncoded: false)
        return [h + "/.cache", h + "/Library/Caches", h + "/.local/share",
                h + "/Library/Application Support"]
            .map(PathComponents.normalizedComponents(of:))
    }

    static func uvCacheDirectory(home: URL, environment: [String: String]) -> Resolution {
        guard let raw = environment["UV_CACHE_DIR"], !raw.isEmpty else { return .default }
        guard raw.hasPrefix("/") else {
            return .unusable(reason: "UV_CACHE_DIR is set to a relative path.")
        }
        let components = PathComponents.normalizedComponents(of: raw)
        let allowed = plausibleCacheParents(home: home).contains {
            PathComponents.matchesSubtree(candidate: components, rule: $0, caseInsensitive: true)
        }
        guard allowed else {
            return .unusable(reason: "UV_CACHE_DIR points outside the usual cache locations, so Loupe leaves it alone.")
        }
        return .relocated(PathComponents.join(components))
    }

    /// Xcode's `IDECustomDerivedDataLocation`.
    ///
    /// Read straight from the preferences file rather than through
    /// `UserDefaults`, so that a machine where reading it is refused reports
    /// "location unknown" instead of triggering a permissions dialog in the
    /// middle of a scan.
    static func derivedDataLocation(home: URL) -> Resolution {
        let preferences = home.appending(path: "Library/Preferences/com.apple.dt.Xcode.plist",
                                         directoryHint: .notDirectory)
        guard FileIdentity.lstat(preferences) != nil else { return .default }
        guard let data = try? Data(contentsOf: preferences, options: [.mappedIfSafe]) else {
            return .unusable(reason: "Loupe could not read Xcode's preferences, so it will not assume the default location is in use.")
        }
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            return .default
        }
        guard let raw = plist["IDECustomDerivedDataLocation"] as? String, !raw.isEmpty else {
            return .default
        }
        guard raw.hasPrefix("/") else {
            return .unusable(reason: "Xcode's DerivedData location is set relative to each workspace, so there is no single folder to show.")
        }
        let components = PathComponents.normalizedComponents(of: raw)
        let homeComponents = PathComponents.normalizedComponents(
            of: home.path(percentEncoded: false))
        guard PathComponents.matchesSubtree(candidate: components, rule: homeComponents,
                                            caseInsensitive: true) else {
            return .unusable(reason: "Xcode's DerivedData location is outside your home folder, so Loupe does not touch it.")
        }
        return .relocated(PathComponents.join(components))
    }
}
