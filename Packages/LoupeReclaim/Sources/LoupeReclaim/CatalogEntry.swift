import Foundation
import LoupeCore

/// The words that go with a `DeletionMechanism`.
///
/// The mechanism itself is in the contract, so LoupeUI can gate on it. What the
/// contract deliberately does not carry is the prose, and three of the nineteen
/// entries need it: each is a different reason for Loupe to step aside, and a
/// shared sentence would explain none of them.
public struct MechanismCopy: Sendable, Hashable {
    /// The exact command that removes it, when another tool owns the deletion.
    /// Shown verbatim; never run.
    public let command: String?
    /// Why Loupe is not the one doing this.
    public let explanation: String

    public init(command: String? = nil, explanation: String) {
        self.command = command; self.explanation = explanation
    }
}

/// Looks for a command-line tool without running anything.
///
/// This exists for one sentence in the spec: "uv is installed; its cache
/// directory has not been created yet" is a different fact from "uv is not
/// installed", and both are different from "0 bytes". Existence checks answer it
/// without spawning a process.
public struct ToolProbe: Sendable, Hashable {
    public let name: String
    public let searchPaths: [String]

    public func installedLocation() -> String? {
        searchPaths.first { path in
            var info = stat()
            return lstat(path, &info) == 0
        }
    }
}

/// Which processes must be stopped before a particular path may go.
///
/// `CleanupTarget.refuseWhileRunning` is a list, which is the right shape for
/// eighteen of the nineteen entries. It is still the wrong shape for the
/// Chromium row: that one entry covers eight browsers, and putting all eight
/// identifiers on the target would mean Opera GX being open blocks Chrome's
/// cache. Which app matters depends on which vendor's directory the path is in,
/// so it is attached to the path rather than to the entry.
public struct PathQuitRule: Sendable, Hashable {
    public let pathPrefix: String
    public let refuseWhileRunning: [String]
    public let displayName: String
}

/// A catalog entry: the frozen `CleanupTarget` the rest of the app sees, plus
/// the machinery this module needs to find and guard its contents.
public struct CatalogEntry: Sendable, Identifiable {
    public let target: CleanupTarget
    /// The prose for `target.mechanism`. Present exactly when Loupe is not the
    /// one doing the deleting.
    public let mechanismCopy: MechanismCopy?
    /// Component names that are never part of this target, enforced in the
    /// safety engine rather than merely left out of the include patterns.
    public let excludedComponents: [String]
    public let perPathQuitRules: [PathQuitRule]
    /// How far a `**` pattern may descend. Only entry 19 uses one.
    public let discoveryDepth: Int
    public let toolProbe: ToolProbe?
    /// A file whose absence means the entry does not apply at all, whatever the
    /// pattern roots say. Firefox's `profiles.ini` is the case in point.
    public let requiredMarkerFile: String?
    /// Facts the row must show that do not fit the frozen type. Displayed, not
    /// discarded.
    public let notes: [String]

    public var id: String { target.id }
    public var safety: SafetyLevel { target.safety }
    public var mechanism: DeletionMechanism { target.mechanism }

    public init(target: CleanupTarget, mechanismCopy: MechanismCopy? = nil,
                excludedComponents: [String] = [], perPathQuitRules: [PathQuitRule] = [],
                discoveryDepth: Int = 0, toolProbe: ToolProbe? = nil,
                requiredMarkerFile: String? = nil, notes: [String] = []) {
        self.target = target; self.mechanismCopy = mechanismCopy
        self.excludedComponents = excludedComponents
        self.perPathQuitRules = perPathQuitRules
        self.discoveryDepth = discoveryDepth
        self.toolProbe = toolProbe
        self.requiredMarkerFile = requiredMarkerFile
        self.notes = notes
        // An entry Loupe does not delete has to say why, and an entry it does
        // delete has no business carrying an excuse for not deleting it.
        precondition(target.isDeletableByLoupe == (mechanismCopy == nil),
                     "\(target.id): mechanism and its explanation disagree")
    }
}

/// Whether a target exists on this machine at all.
///
/// R7 of the spec: an entry whose paths are absent renders as "Not present on
/// this Mac", never as 0 B, and contributes to no total. Absent and empty are
/// different facts about the user's machine and the row says which one it is.
public enum TargetPresence: Sendable, Hashable {
    /// None of the entry's roots exist.
    case absent
    /// The tool is installed but has never written its cache directory.
    case configuredButUnused(tool: String, location: String)
    /// A root exists and holds nothing.
    case presentButEmpty
    case present(matches: Int)
    /// The entry is real but Loupe could not find out where it lives — a custom
    /// DerivedData location it cannot read, for instance. Reported rather than
    /// silently replaced with the default location.
    case locationUnknown(reason: String)

    public var contributesToTotals: Bool {
        if case .present = self { true } else { false }
    }

    /// The row's subtitle. Five different facts, five different sentences.
    public func summary(displayName: String) -> String {
        switch self {
        case .absent:
            "Not present on this Mac."
        case .configuredButUnused(let tool, let location):
            "\(tool) is installed at \(location); its cache directory has not been created yet."
        case .presentButEmpty:
            "\(displayName) is present and holds nothing."
        case .present(let matches):
            "\(matches.formatted()) item\(matches == 1 ? "" : "s") found."
        case .locationUnknown(let reason):
            "Location unknown. \(reason)"
        }
    }
}
