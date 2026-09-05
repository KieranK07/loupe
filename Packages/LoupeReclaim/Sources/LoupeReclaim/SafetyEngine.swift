import Darwin
import Foundation
import LoupeCore
import Synchronization

/// The one place that decides whether a path may be deleted.
///
/// Closed by default. `evaluate` returns `.allowed` only when the path resolves
/// inside a target's declared scope **and** survives every guard below; anything
/// it cannot classify is refused. There is no ordering of the checks that turns
/// a refusal into permission, and no argument a caller can pass that skips one.
///
/// The guards, in the order they run:
///
/// 1. canonicalisation — `realpath` plus APFS firmlink normalisation (§B.3);
/// 2. the lexical deny table, matched by whole path component (§B.2, §B.4);
/// 3. the identity walk — every ancestor by `(dev, ino)` (§B.5);
/// 4. filesystem flags on the candidate and every ancestor (§B.6);
/// 5. running processes and the bundles they occupy (§B.7);
/// 6. the volume: read-only, or the candidate is a mount point;
/// 7. the target's own scope, including its per-entry exclusions.
///
/// Steps 2 and 3 are deliberately redundant. Lexical matching cannot see through
/// a hardlink; the identity walk cannot cover a rule whose root does not exist
/// on this machine. Either one denying is a denial.
///
/// # What the identity walk cannot do
///
/// A hardlink whose inode *is* a blocked root — a second name for
/// `/private/var/db/SystemKey`, say — is caught, because that inode is in the
/// deny set. A hardlink to some file *inside* a blocked directory is not:
/// POSIX offers no way to ask a file for its other names, and finding them would
/// mean walking the whole volume for every candidate.
///
/// The bound on that gap is the deletion primitive. Moving a hardlink to the
/// Trash removes that name and nothing else; the file the link pointed at keeps
/// its own name and its own bytes. So the worst case is a stray extra name in
/// the Trash, not a lost file — which is one of the reasons `trashItem` is the
/// only primitive in this package. `TrashExecutorTests` asserts this directly.
public final class SafetyEngine: Sendable {

    public let home: URL
    public let canonicalizer: PathCanonicalizer
    public let blocklist: Blocklist

    private let subtreeIdentities: [InodeKey: (rule: BlocklistRule, detail: String, components: [String])]
    private let itemIdentities: [InodeKey: (rule: BlocklistRule, detail: String)]
    private let extraDenyRoots: [(components: [String], identity: InodeKey?, detail: String)]

    private let processIndex: Mutex<RunningProcessIndex>

    /// - Parameter extraDenyRoots: additional subtrees to refuse. This seam can
    ///   only ever *add* a denial — there is no corresponding allow parameter —
    ///   which is what makes it safe to expose. The tests use it to prove the
    ///   identity walk catches a hardlink without hardlinking anything real.
    public init(home: URL = UserHome.resolved(),
                canonicalizer: PathCanonicalizer = PathCanonicalizer(),
                extraDenyRoots: [URL] = []) {
        _ = DatalessPolicy.disabled
        self.home = home
        self.canonicalizer = canonicalizer
        self.blocklist = Blocklist(home: home)

        var subtree: [InodeKey: (rule: BlocklistRule, detail: String, components: [String])] = [:]
        var item: [InodeKey: (rule: BlocklistRule, detail: String)] = [:]
        for deny in blocklist.denies {
            // Resolve before stat-ing: `/var` is a symlink, and recording the
            // symlink's inode would leave the directory it points at unguarded
            // in the identity walk.
            let literal = PathComponents.join(deny.components)
            let (resolved, _) = PathCanonicalizer.resolveDeepest(literal)
            guard let identity = FileIdentity.lstat(resolved) else { continue }
            let key = InodeKey(identity)
            switch deny.reach {
            case .subtree: if subtree[key] == nil { subtree[key] = (deny.rule, deny.detail, deny.components) }
            case .item:    if item[key] == nil { item[key] = (deny.rule, deny.detail) }
            }
        }
        self.subtreeIdentities = subtree
        self.itemIdentities = item

        self.extraDenyRoots = extraDenyRoots.map { url in
            let canonical = try? canonicalizer.canonicalize(url)
            let components = canonical?.components
                ?? PathComponents.normalizedComponents(of: url.path(percentEncoded: false))
            let identity = canonical.flatMap { FileIdentity.lstat($0.realPath) }.map(InodeKey.init)
            return (components, identity, "Refused by an additional deny root.")
        }

        self.processIndex = Mutex(RunningProcessIndex.snapshot(canonicalizer: canonicalizer))
    }

    // MARK: - Process snapshot

    public var runningProcesses: RunningProcessIndex { processIndex.withLock { $0 } }

    /// Retakes the process snapshot.
    ///
    /// The executor calls this before every run. A plan is a proposal about a
    /// filesystem that has moved on since — an app may have launched in the
    /// seconds the confirmation sheet was open, and the stale snapshot would
    /// have said it had not.
    @discardableResult
    public func refreshRunningProcesses() -> RunningProcessIndex {
        let fresh = RunningProcessIndex.snapshot(canonicalizer: canonicalizer)
        processIndex.withLock { $0 = fresh }
        return fresh
    }

    // MARK: - The decision

    public func evaluate(_ url: URL, scope: SafetyScope?) -> SafetyVerdict {
        let canonical: CanonicalPath
        do {
            canonical = try canonicalizer.canonicalize(url)
        } catch {
            // A path we cannot even name is not a path we may delete.
            return .refused(BlockedPath(url: url, rule: .outsideTargetScope),
                            detail: Self.describe(error))
        }
        return evaluate(canonical: canonical, original: url, scope: scope)
    }

    public func evaluate(canonical: CanonicalPath, original: URL,
                         scope: SafetyScope?) -> SafetyVerdict {
        let insensitive = canonical.caseInsensitive
        let components = canonical.components

        func refuse(_ rule: BlocklistRule, _ detail: String) -> SafetyVerdict {
            .refused(BlockedPath(url: original, rule: rule), detail: detail)
        }

        // 2 — the lexical deny table.
        if let denial = blocklist.firstDenial(components: components,
                                              caseInsensitive: insensitive) {
            return refuse(denial.rule, denial.detail)
        }
        for extra in extraDenyRoots
        where PathComponents.matchesSubtree(candidate: components, rule: extra.components,
                                            caseInsensitive: insensitive) {
            return refuse(.outsideTargetScope, extra.detail)
        }

        // 3, 4, 5 — one walk from the candidate to the root, `lstat`ing each
        // level. Ancestors are taken from the firmlink-normalised spelling: the
        // literal `/System/Volumes/Data/...` form has `/System` as an ancestor,
        // and treating that as a system-path hit would refuse every ordinary
        // file on the Data volume.
        let processes = processIndex.withLock { $0 }
        var level = components.count
        while level >= 0 {
            let isCandidate = level == components.count
            let path = isCandidate
                ? canonical.realPath
                : PathComponents.join(Array(components[0..<level]))
            level -= 1

            guard let identity = FileIdentity.lstat(path) else { continue }
            let key = InodeKey(identity)

            if let denial = subtreeIdentities[key],
               // An allow that cancels this deny lexically must cancel it here
               // too, or the identity walk quietly overrules the carve-out.
               !blocklist.isCancelled(denyComponents: denial.components,
                                      components: components,
                                      caseInsensitive: canonical.caseInsensitive) {
                return refuse(denial.rule, denial.detail)
            }
            if isCandidate, let denial = itemIdentities[key] {
                return refuse(denial.rule, denial.detail)
            }
            // Extra deny roots reach their whole subtree, so this fires for
            // the candidate and for every ancestor alike. It is what catches a
            // hardlink whose name says nothing about where its inode lives.
            for extra in extraDenyRoots where extra.identity == key {
                return refuse(.outsideTargetScope, extra.detail)
            }

            if let refusal = Self.flagRefusal(identity: identity, isCandidate: isCandidate) {
                return refuse(refusal.rule, refusal.detail)
            }

            if let occupant = processes.occupiedRoots[key] {
                return refuse(.runningAppBundle, "\(occupant) is running.")
            }
        }

        // 5b — the lexical half of the running-bundle check, for ancestors the
        // walk above could not `lstat`.
        for bundle in processes.occupiedComponents
        where PathComponents.matchesSubtree(candidate: components, rule: bundle,
                                            caseInsensitive: insensitive) {
            return refuse(.runningAppBundle,
                          "\(PathComponents.join(bundle)) belongs to a running process.")
        }

        // 6 — the volume.
        if let volume = VolumeFacts.of(canonical.realPath) {
            if volume.isReadOnly {
                return refuse(.readOnlyVolume,
                              "The volume holding this item is mounted read-only.")
            }
            if volume.mountPoint == canonical.realPath {
                return refuse(.volumeRoot, "This is the root of a mounted volume.")
            }
        }

        // 7 — scope. Nothing reaches this line without a target that claims it.
        guard let scope else {
            return refuse(.outsideTargetScope,
                          "This path is not part of any cleanup target Loupe knows about.")
        }
        guard scope.contains(components, caseInsensitive: insensitive) else {
            return refuse(.outsideTargetScope,
                          "Resolves to \(canonical.matchedPath), which is outside \(scope.targetID).")
        }
        for excluded in scope.excludedComponents
        where PathComponents.containsComponent(candidate: components, name: excluded,
                                               caseInsensitive: insensitive) {
            return refuse(.outsideTargetScope,
                          "\(excluded) is not a cache and is excluded from \(scope.targetID).")
        }
        for name in scope.refuseWhileRunning {
            if processes.isRunning(bundleIdentifier: name) {
                return refuse(.runningAppBundle, "\(name) is running.")
            }
            if processes.isRunning(executableNamed: name) {
                return refuse(.runningAppBundle, "A \(name) process is running.")
            }
        }

        return .allowed(canonical)
    }

    // MARK: - Flags

    static func flagRefusal(identity: FileIdentity,
                            isCandidate: Bool) -> (rule: BlocklistRule, detail: String)? {
        let flags = identity.flags
        if flags & ProtectionFlags.sfRestricted != 0 {
            return (.sipRestricted, "Carries SF_RESTRICTED.")
        }
        if flags & ProtectionFlags.ufDataVault != 0 {
            return (.sipRestricted, "Carries UF_DATAVAULT; not even readable without an entitlement.")
        }
        guard isCandidate else { return nil }

        if flags & ProtectionFlags.sfDataless != 0 {
            // The worst single mistake available to this app: the placeholder is
            // the user's only handle on a file that exists nowhere else on this
            // Mac, and trashing it removes the file from iCloud everywhere.
            return (.icloudPlaceholder, "Stored in iCloud and not downloaded to this Mac.")
        }
        if flags & ProtectionFlags.sfFirmlink != 0 {
            return (.volumeRoot, "A firmlink grafting another volume in at this point.")
        }
        if flags & ProtectionFlags.sfNoUnlink != 0 {
            // Measured on `/`, `/Library`, `/Applications`, `/usr/local`,
            // `/private/var` and `/System/Volumes/Data`: every one of them a
            // container the system assembled, none of them a cache.
            return (.protectedContainer, "Carries SF_NOUNLINK; the system forbids removing it.")
        }
        if flags & ProtectionFlags.sfImmutable != 0 {
            return (.lockedItem, "Carries SF_IMMUTABLE; the system has locked it.")
        }
        if flags & ProtectionFlags.ufImmutable != 0 {
            return (.lockedItem, "Locked. Unlock it in Finder's Get Info panel first.")
        }
        return nil
    }

    private static func describe(_ rejection: PathRejection) -> String {
        switch rejection {
        case .notAFileURL: "Not a file URL."
        case .notAbsolute: "Not an absolute path."
        case .empty: "Empty path."
        case .containsNUL: "Path contains a NUL byte."
        }
    }
}

/// The two things `statfs` is asked for here.
struct VolumeFacts: Sendable, Hashable {
    let mountPoint: String
    let isReadOnly: Bool
    let filesystemType: String

    static func of(_ path: String) -> VolumeFacts? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let mount = withUnsafeBytes(of: &info.f_mntonname) { Self.string(from: $0) }
        let type = withUnsafeBytes(of: &info.f_fstypename) { Self.string(from: $0) }
        return VolumeFacts(mountPoint: mount,
                           isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
                           filesystemType: type)
    }

    private static func string(from raw: UnsafeRawBufferPointer) -> String {
        let bytes = raw.bindMemory(to: CChar.self)
        return bytes.baseAddress.map { String(cString: $0) } ?? ""
    }
}
