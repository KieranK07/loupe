import Foundation
import LoupeCore

/// What one catalog entry is allowed to reach.
///
/// The engine is closed by default: without a scope, nothing is deletable. This
/// is the type that says "yes, this path really is part of that target", and it
/// is built from the target's own patterns rather than trusted from the caller.
public struct SafetyScope: Sendable, Hashable {
    public let targetID: String
    /// Canonical component arrays of each pattern's non-glob prefix. A candidate
    /// must lie at or beneath one of these after canonicalisation — which is how
    /// a symlink or a `..` that leaves the target gets caught.
    public let roots: [[String]]
    /// Names that are never part of this target even when they sit inside its
    /// roots. Chromium's `Extensions`, `Cookies` and `Local Storage` live in the
    /// middle of its cache tree; the spec requires them enforced here rather
    /// than merely omitted from the include globs, so an include-glob bug cannot
    /// reach them.
    public let excludedComponents: [String]
    /// Names that must not be running, each checked as a bundle identifier
    /// *and* as a bare executable name.
    ///
    /// One list rather than two because the distinction is not one the catalog
    /// can always make: `com.apple.mail` is only ever a bundle identifier,
    /// `xcodebuild` is only ever an executable, and
    /// `com.apple.CoreSimulator.CoreSimulatorService` is spelled like the first
    /// and is in fact the second.
    public let refuseWhileRunning: [String]

    public init(targetID: String, roots: [[String]], excludedComponents: [String] = [],
                refuseWhileRunning: [String] = []) {
        self.targetID = targetID; self.roots = roots
        self.excludedComponents = excludedComponents
        self.refuseWhileRunning = refuseWhileRunning
    }

    public func contains(_ components: [String], caseInsensitive: Bool) -> Bool {
        roots.contains { PathComponents.matchesSubtree(candidate: components, rule: $0,
                                                       caseInsensitive: caseInsensitive) }
    }
}

/// The engine's answer about one path.
public enum SafetyVerdict: Sendable, Hashable {
    case allowed(CanonicalPath)
    /// The `BlockedPath` is what goes in the plan; `detail` is the precise
    /// reason, which the eleven-case `BlocklistRule` cannot always express.
    case refused(BlockedPath, detail: String)

    public var isAllowed: Bool { if case .allowed = self { true } else { false } }
    public var rule: BlocklistRule? {
        if case .refused(let blocked, _) = self { blocked.rule } else { nil }
    }
    public var canonical: CanonicalPath? {
        if case .allowed(let path) = self { path } else { nil }
    }
    public var detail: String? {
        if case .refused(_, let detail) = self { detail } else { nil }
    }
}
