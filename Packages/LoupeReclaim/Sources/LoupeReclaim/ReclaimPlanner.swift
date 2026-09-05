import Foundation
import LoupeCore

/// One catalog entry as it stands on this machine right now.
public struct TargetSurvey: Sendable {
    public let entry: CatalogEntry
    public let presence: TargetPresence
    /// Selectable items. Empty for every entry whose `mechanism` is not `.trash`.
    public let candidates: [ReclaimCandidate]
    /// Listed, sized and explained, but never selectable in a bulk flow: the
    /// Trash, Downloads, and the two entries Xcode's own tool has to remove.
    public let reviewItems: [ReclaimCandidate]
    public let blocked: [BlockedPath]
    /// Per-path refusal detail, keyed by path. `BlocklistRule` has eleven cases
    /// and the filesystem has more reasons than that; the precise one is kept
    /// here rather than rounded off.
    public let refusalDetails: [String: String]
    /// Paths a heuristic declined to offer, with the reason. Not refusals — the
    /// safety engine allowed them; the catalog's own rules did not select them.
    public let notOffered: [(path: String, reason: String)]

    public var totalBytes: UInt64 { candidates.reduce(0) { $0 &+ $1.physicalBytes } }
    public var reviewBytes: UInt64 { reviewItems.reduce(0) { $0 &+ $1.physicalBytes } }
}

/// The dry run.
///
/// Reads the filesystem and writes nothing to it. Every path it emits has been
/// through `SafetyEngine`; every path it refused is in `blocked` with the rule
/// that refused it, because a user who asked to look at something deserves to
/// know what was withheld and why.
public struct ReclaimPlanner: Sendable {

    public let catalog: CleanupCatalog
    public let safety: SafetyEngine
    public let dormancy: DormancyHeuristic
    public let environment: [String: String]

    public init(catalog: CleanupCatalog, safety: SafetyEngine,
                dormancy: DormancyHeuristic = DormancyHeuristic(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.catalog = catalog; self.safety = safety
        self.dormancy = dormancy; self.environment = environment
    }

    /// The plan the confirmation sheet is built from.
    public func plan(targetIDs: Set<String>? = nil) async -> ReclaimPlan {
        let surveys = await survey(targetIDs: targetIDs)
        return ReclaimPlan(candidates: surveys.flatMap(\.candidates),
                           blocked: surveys.flatMap(\.blocked))
    }

    public func survey(targetIDs: Set<String>? = nil) async -> [TargetSurvey] {
        safety.refreshRunningProcesses()
        let openFiles = OpenFileIndex.snapshot()
        var surveys: [TargetSurvey] = []
        for entry in catalog.entries where targetIDs?.contains(entry.id) ?? true {
            surveys.append(await survey(entry: entry, openFiles: openFiles))
        }
        return surveys
    }

    // MARK: - One entry

    func survey(entry: CatalogEntry, openFiles: OpenFileIndex) async -> TargetSurvey {
        var blocked: [BlockedPath] = []
        var details: [String: String] = [:]
        var notOffered: [(path: String, reason: String)] = []

        if let marker = entry.requiredMarkerFile, FileIdentity.lstat(marker) == nil {
            return TargetSurvey(entry: entry, presence: .absent, candidates: [],
                                reviewItems: [], blocked: [], refusalDetails: [:],
                                notOffered: [])
        }

        let patterns: [String]
        switch relocation(for: entry) {
        case .default:
            patterns = entry.target.patterns
        case .relocated(let location):
            patterns = entry.target.patterns.map { rewrite($0, to: location) }
        case .unusable(let reason):
            return TargetSurvey(entry: entry, presence: .locationUnknown(reason: reason),
                                candidates: [], reviewItems: [], blocked: [],
                                refusalDetails: [:], notOffered: [])
        }

        var anyRootExists = false
        var matches: [String] = []
        var scopeRoots: [[String]] = []
        for pattern in patterns {
            let expansion = PatternExpander.expand(pattern: pattern,
                                                   maximumDepth: entry.discoveryDepth)
            if expansion.rootExists {
                anyRootExists = true
                if let canonical = try? safety.canonicalizer.canonicalize(path: expansion.root) {
                    scopeRoots.append(canonical.components)
                }
            }
            matches.append(contentsOf: expansion.matches)
        }
        matches = Array(Set(matches)).sorted()

        guard anyRootExists else {
            let presence: TargetPresence
            if let probe = entry.toolProbe, let location = probe.installedLocation() {
                presence = .configuredButUnused(tool: probe.name, location: location)
            } else {
                presence = .absent
            }
            return TargetSurvey(entry: entry, presence: presence, candidates: [],
                                reviewItems: [], blocked: [], refusalDetails: [:],
                                notOffered: [])
        }

        let baseScope = SafetyScope(
            targetID: entry.id,
            roots: scopeRoots,
            excludedComponents: entry.excludedComponents,
            refuseWhileRunning: entry.target.refuseWhileRunning)

        var accepted: [ReclaimCandidate] = []
        for path in matches {
            let url = URL(filePath: path, directoryHint: .inferFromPath)
            let scope = scoped(baseScope, for: path, entry: entry)

            switch safety.evaluate(url, scope: scope) {
            case .refused(let blockedPath, let detail):
                blocked.append(blockedPath)
                details[path] = detail
                continue
            case .allowed(let canonical):
                if let holder = openFiles.occupant(of: canonical.components,
                                                   caseInsensitive: canonical.caseInsensitive) {
                    blocked.append(BlockedPath(url: url, rule: .runningAppBundle))
                    details[path] = "\((holder.executable as NSString).lastPathComponent) has \(holder.path) open."
                    continue
                }
                // `lstat` of the path itself, not of what it resolves to. The
                // guards above judge the resolved location, because that is
                // what a symlink could smuggle; the size and the identity are
                // of the item that would actually be moved, which for a symlink
                // is the link and not its target.
                guard let identity = FileIdentity.lstat(url) else {
                    // Gone between the expansion and now. Nothing to offer and
                    // nothing to warn about.
                    continue
                }
                if entry.id == "dormant-node-modules" {
                    let projectRoot = url.deletingLastPathComponent()
                    let newest = await TreeMeasure.newestSourceModification(under: projectRoot)
                    let verdict = dormancy.evaluate(
                        projectRoot: projectRoot, newestSource: newest,
                        excludedPrefixes: dormancyExclusions(),
                        caseInsensitive: canonical.caseInsensitive)
                    if case .notOffered(let reason) = verdict {
                        notOffered.append((path, reason))
                        continue
                    }
                }
                let measurement = await TreeMeasure.measure(url, identity: identity)
                accepted.append(ReclaimCandidate(
                    url: url, targetID: entry.id,
                    physicalBytes: measurement.physicalBytes,
                    itemCount: measurement.itemCount,
                    lastModified: measurement.lastModified,
                    // Recorded so the executor can prove, at the moment it acts,
                    // that the thing at this path is still the thing that was
                    // measured and shown. A path is a name; this is the file.
                    deviceID: identity.device, inode: identity.inode))
            }
        }

        let presence: TargetPresence = accepted.isEmpty && blocked.isEmpty && notOffered.isEmpty
            ? .presentButEmpty
            : .present(matches: accepted.count + blocked.count + notOffered.count)

        // Everything that is not a `.trash` entry is listed and explained but
        // never handed to the executor. The mechanism, not the caller, decides.
        let selectable = entry.target.isDeletableByLoupe
        return TargetSurvey(entry: entry, presence: presence,
                            candidates: selectable ? accepted : [],
                            reviewItems: selectable ? [] : accepted,
                            blocked: blocked, refusalDetails: details,
                            notOffered: notOffered)
    }

    // MARK: - Scope

    /// The scope for one candidate.
    ///
    /// Almost always the entry's own scope. The Chromium row is the exception:
    /// one entry covers eight browsers, and which application must be quit
    /// depends on which vendor's cache directory the path is in. Putting all
    /// eight on `CleanupTarget.refuseWhileRunning` would block Chrome's cache
    /// because Opera GX happens to be open.
    func scoped(_ base: SafetyScope, for path: String, entry: CatalogEntry) -> SafetyScope {
        guard !entry.perPathQuitRules.isEmpty else { return base }
        let components = PathComponents.normalizedComponents(of: path)
        var names = base.refuseWhileRunning
        for rule in entry.perPathQuitRules {
            let prefix = PathComponents.normalizedComponents(of: rule.pathPrefix)
            if PathComponents.matchesSubtree(candidate: components, rule: prefix,
                                             caseInsensitive: true) {
                names.append(contentsOf: rule.refuseWhileRunning)
            }
        }
        return SafetyScope(targetID: base.targetID, roots: base.roots,
                           excludedComponents: base.excludedComponents,
                           refuseWhileRunning: names)
    }

    public func scope(for entry: CatalogEntry) -> SafetyScope {
        var roots: [[String]] = []
        for pattern in entry.target.patterns {
            let expansion = PatternExpander.expand(pattern: pattern,
                                                   maximumDepth: entry.discoveryDepth)
            guard expansion.rootExists,
                  let canonical = try? safety.canonicalizer.canonicalize(path: expansion.root)
            else { continue }
            roots.append(canonical.components)
        }
        return SafetyScope(targetID: entry.id, roots: roots,
                           excludedComponents: entry.excludedComponents,
                           refuseWhileRunning: entry.target.refuseWhileRunning)
    }

    // MARK: - Relocation

    private func relocation(for entry: CatalogEntry) -> ConfiguredLocations.Resolution {
        switch entry.id {
        case "xcode-derived-data":
            ConfiguredLocations.derivedDataLocation(home: catalog.home)
        case "uv-cache":
            ConfiguredLocations.uvCacheDirectory(home: catalog.home, environment: environment)
        default:
            .default
        }
    }

    /// Replaces a pattern's literal prefix with the relocated directory, keeping
    /// the glob tail. The tail is what says *what* in that directory is a
    /// candidate, and relocating must not widen it.
    private func rewrite(_ pattern: String, to location: String) -> String {
        let components = pattern.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let tail = components.drop { !PatternExpander.isGlob($0) }
        return tail.isEmpty ? location : location + "/" + tail.joined(separator: "/")
    }

    /// Where a `node_modules` may not be counted from: the package-manager
    /// caches that own their own entries.
    private func dormancyExclusions() -> [[String]] {
        let h = catalog.home.path(percentEncoded: false)
        return [h + "/.npm", h + "/.cache", h + "/Library", h + "/.yarn", h + "/.local/share"]
            .map(PathComponents.normalizedComponents(of:))
    }
}
