import Foundation

/// Whether a project looks abandoned, and if not, why not.
///
/// Every gate here exists because the obvious signal is wrong. `node_modules`'
/// own modification time reflects the last `npm install`, which on the
/// development machine made a project with 28-day-old sources look 76 days
/// stale. The gates are all conjunctive and all failable, and failing one means
/// the project is simply not offered — never that it is offered with a warning.
public struct DormancyHeuristic: Sendable {

    /// The default. Asserted rather than derived, and on the development machine
    /// it yields zero candidates — which is the correct outcome for a
    /// conservative rule, not a broken feature.
    public static let defaultThresholdDays = 180.0
    /// The UI will not accept a smaller value.
    public static let floorThresholdDays = 90.0

    public let thresholdDays: Double
    public let now: Date

    public init(thresholdDays: Double = DormancyHeuristic.defaultThresholdDays, now: Date = .now) {
        self.thresholdDays = max(DormancyHeuristic.floorThresholdDays, thresholdDays)
        self.now = now
    }

    public enum Verdict: Sendable, Hashable {
        case dormant(sourceAgeDays: Double)
        case notOffered(reason: String)
    }

    public static let lockfiles = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock",
                                  "bun.lockb", "npm-shrinkwrap.json"]
    public static let manifests = ["package.json"]

    /// - Parameters:
    ///   - projectRoot: the directory containing `node_modules`.
    ///   - newestSource: the newest modification time among files a person edits,
    ///     with generated directories excluded. See `TreeMeasure`.
    public func evaluate(projectRoot: URL, newestSource: Date?,
                         excludedPrefixes: [[String]],
                         caseInsensitive: Bool) -> Verdict {
        let components = PathComponents.normalizedComponents(
            of: projectRoot.path(percentEncoded: false))

        // G4 — a dependency tree inside a package manager's own cache belongs to
        // that cache's entry, not to this one. The measured case is a 540 MB
        // node_modules left inside npm's `_cacache/tmp` by an interrupted install.
        for prefix in excludedPrefixes
        where PathComponents.matchesSubtree(candidate: components, rule: prefix,
                                            caseInsensitive: caseInsensitive) {
            return .notOffered(reason: "Inside \(PathComponents.join(prefix)), which belongs to another entry.")
        }

        // G2 — without a lockfile the reinstall is not reproducible, so the tree
        // cannot be put back the way it was.
        guard Self.lockfiles.contains(where: { exists(projectRoot, $0) }) else {
            return .notOffered(reason: "No lockfile, so reinstalling would not reproduce this exact dependency tree.")
        }
        guard Self.manifests.contains(where: { exists(projectRoot, $0) }) else {
            return .notOffered(reason: "No package.json, so this is not a project root.")
        }

        // G1 — measured from what the human edits.
        guard let newestSource else {
            return .notOffered(reason: "No source files found to judge this project by.")
        }
        let ageDays = now.timeIntervalSince(newestSource) / 86_400
        guard ageDays > thresholdDays else {
            return .notOffered(reason: "Edited \(Int(ageDays.rounded())) days ago.")
        }

        // G5 — uncommitted work means the project is mid-flight whatever the
        // dates say.
        if let gitReason = uncommittedWorkReason(projectRoot: projectRoot,
                                                 newestSource: newestSource) {
            return .notOffered(reason: gitReason)
        }

        return .dormant(sourceAgeDays: ageDays)
    }

    /// A proxy for `git status --porcelain`, without running `git`.
    ///
    /// Loupe does not spawn processes to decide what to delete, so the check is
    /// made from file metadata: `.git/index` is rewritten by `git add` and
    /// `git commit`, so a source file newer than the index is work that has not
    /// been staged. It over-refuses — a file merely touched since the last commit
    /// blocks the project — and that is the direction to be wrong in. If the
    /// index cannot be read at all, the project is not offered.
    private func uncommittedWorkReason(projectRoot: URL, newestSource: Date) -> String? {
        let gitDirectory = projectRoot.appending(component: ".git", directoryHint: .isDirectory)
        guard FileIdentity.lstat(gitDirectory) != nil else { return nil }
        let index = gitDirectory.appending(component: "index", directoryHint: .notDirectory)
        guard let indexIdentity = FileIdentity.lstat(index) else {
            return "This is a Git repository whose index Loupe cannot read, so it cannot tell whether there is uncommitted work."
        }
        guard newestSource <= indexIdentity.modified else {
            return "A file here has changed since the last time anything was staged or committed."
        }
        return nil
    }

    private func exists(_ directory: URL, _ name: String) -> Bool {
        FileIdentity.lstat(directory.appending(component: name, directoryHint: .notDirectory)) != nil
    }
}
