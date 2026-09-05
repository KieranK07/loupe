import Darwin
import Foundation
import LoupeCore

/// One item that was moved, and where it landed.
///
/// `resultingURL` is always captured. macOS renames on collision, so the name in
/// the Trash is frequently not the name the user selected, and a report that
/// printed the original name would be telling them to look for something that is
/// not there.
public struct TrashedItem: Sendable, Hashable {
    public let original: URL
    public let resultingURL: URL?
    public let physicalBytes: UInt64
}

/// What happened, in full.
public struct ReclaimReport: Sendable {
    public let moved: [TrashedItem]
    public let failures: [URL: ReclaimFailure]
    /// The precise reason per failed path, for the cases `ReclaimFailure` and
    /// `BlocklistRule` between them round off.
    public let failureDetails: [String: String]
    public let startedAt: Date
    public let finishedAt: Date

    public var outcome: ReclaimOutcome {
        ReclaimOutcome(trashed: moved.map(\.original),
                       bytesMoved: moved.reduce(0) { $0 &+ $1.physicalBytes },
                       failures: failures)
    }

    /// The first line of the post-run report, worded as §14 of the spec requires.
    /// Not "reclaimed": nothing has been reclaimed until the Trash is emptied.
    public var headline: String {
        let count = moved.count
        return "Moved \(count.formatted()) item\(count == 1 ? "" : "s") ("
             + ByteFormat.string(outcome.bytesMoved) + ") to the Trash. "
             + "No disk space has been freed yet."
    }
}

/// The only thing in this package that changes the disk.
///
/// It has exactly one primitive: `FileManager.trashItem(at:resultingItemURL:)`.
/// There is no other call here that removes anything, no shell, no `Process`,
/// and a test asserts that none of the alternatives appear anywhere in this
/// module's sources. That is not stylistic. Trashing is recoverable by dragging
/// the item back, and every guard in this package is ultimately backstopped by
/// that property.
///
/// `trashItem` also happens to be the right primitive on the merits: it uses the
/// item's *own* volume's Trash, so it is an O(1) rename regardless of tree size
/// and never copies across volumes. A 6 GB directory moves instantly, with no
/// window in which half of it is gone.
public struct TrashExecutor: Sendable {

    public let catalog: CleanupCatalog
    public let safety: SafetyEngine
    public let planner: ReclaimPlanner

    public init(catalog: CleanupCatalog, safety: SafetyEngine, planner: ReclaimPlanner) {
        self.catalog = catalog; self.safety = safety; self.planner = planner
    }

    /// Moves the selected candidates to the Trash.
    ///
    /// - Parameter selecting: the subset the user actually ticked. `nil` means
    ///   every candidate in the plan — which is only ever the caller's own
    ///   decision, never a default the UI presents: R6 ships every checkbox
    ///   unchecked at every level.
    public func execute(_ plan: ReclaimPlan,
                        selecting selection: Set<URL>? = nil) async -> ReclaimReport {
        let startedAt = Date()

        // The plan may be minutes old. An app can have launched, a file can have
        // been re-created, a directory can have been moved. The plan is a
        // proposal; this is where it is checked against the machine as it is.
        safety.refreshRunningProcesses()
        let openFiles = OpenFileIndex.snapshot()

        var scopes: [String: SafetyScope] = [:]
        var moved: [TrashedItem] = []
        var failures: [URL: ReclaimFailure] = [:]
        var details: [String: String] = [:]

        for candidate in plan.candidates {
            if let selection, !selection.contains(candidate.url) { continue }

            guard let entry = catalog[candidate.targetID] else {
                failures[candidate.url] = .blocked(.outsideTargetScope)
                details[candidate.url.path] = "No catalog entry named \(candidate.targetID)."
                continue
            }
            guard entry.target.isDeletableByLoupe else {
                failures[candidate.url] = .blocked(.outsideTargetScope)
                details[candidate.url.path] =
                    "\(entry.target.displayName) is not removed by moving files to the Trash."
                continue
            }

            let scope = scopes[entry.id] ?? {
                let fresh = planner.scope(for: entry)
                scopes[entry.id] = fresh
                return fresh
            }()

            switch revalidate(candidate, entry: entry, scope: scope, openFiles: openFiles) {
            case .failure(let failure, let detail):
                failures[candidate.url] = failure
                details[candidate.url.path] = detail
            case .success(let bytes):
                switch moveToTrash(candidate.url) {
                case .success(let resulting):
                    moved.append(TrashedItem(original: candidate.url,
                                             resultingURL: resulting,
                                             physicalBytes: bytes))
                case .failure(let failure, let detail):
                    failures[candidate.url] = failure
                    details[candidate.url.path] = detail
                }
            }
        }

        return ReclaimReport(moved: moved, failures: failures, failureDetails: details,
                             startedAt: startedAt, finishedAt: Date())
    }

    /// The frozen-contract shape, for callers that only need the summary.
    public func run(_ plan: ReclaimPlan,
                    selecting selection: Set<URL>? = nil) async -> ReclaimOutcome {
        await execute(plan, selecting: selection).outcome
    }

    // MARK: - Re-validation

    private enum Check {
        case success(bytes: UInt64)
        case failure(ReclaimFailure, detail: String)
    }

    private func revalidate(_ candidate: ReclaimCandidate, entry: CatalogEntry,
                            scope: SafetyScope, openFiles: OpenFileIndex) -> Check {
        // An item whose parent is gone is an item that has already been dealt
        // with, most often because an ancestor in this same run was trashed
        // first. Trashing it now would resurrect nothing and could act on a path
        // that now means something else.
        let parent = candidate.url.deletingLastPathComponent()
        guard let parentIdentity = FileIdentity.lstat(parent), parentIdentity.isDirectory else {
            return .failure(.vanished(parent), detail: "Its enclosing folder is no longer there.")
        }
        guard let identity = FileIdentity.lstat(candidate.url) else {
            return .failure(.vanished(candidate.url), detail: "Already gone.")
        }

        // Named separately from the blocklist refusal because "quit Mail" is
        // something the user can act on and "this is inside macOS" is not.
        for name in entry.target.refuseWhileRunning {
            if safety.runningProcesses.isRunning(bundleIdentifier: name) {
                return .failure(.appRunning(name), detail: "\(name) is running.")
            }
            if safety.runningProcesses.isRunning(executableNamed: name) {
                return .failure(.appRunning(name), detail: "A \(name) process is running.")
            }
        }
        for rule in entry.perPathQuitRules {
            let components = PathComponents.normalizedComponents(of: candidate.url.path)
            let prefix = PathComponents.normalizedComponents(of: rule.pathPrefix)
            guard PathComponents.matchesSubtree(candidate: components, rule: prefix,
                                                caseInsensitive: true) else { continue }
            for name in rule.refuseWhileRunning
            where safety.runningProcesses.isRunning(bundleIdentifier: name)
                || safety.runningProcesses.isRunning(executableNamed: name) {
                return .failure(.appRunning(rule.displayName),
                                detail: "\(rule.displayName) is running.")
            }
        }

        switch safety.evaluate(candidate.url, scope: scope) {
        case .refused(let blocked, let detail):
            return .failure(.blocked(blocked.rule), detail: detail)
        case .allowed(let canonical):
            if let holder = openFiles.occupant(of: canonical.components,
                                               caseInsensitive: canonical.caseInsensitive) {
                let name = (holder.executable as NSString).lastPathComponent
                return .failure(.appRunning(name), detail: "\(name) has \(holder.path) open.")
            }
            // Last, because it is the check that survives everything else being
            // fine. The plan described a file, not a name; if something else now
            // answers to that name, the item the user was shown and agreed to is
            // not the item at the end of this path, and the agreement does not
            // transfer to whatever took its place.
            //
            // It runs after the guards above so that a path swapped for a
            // *blocked* one reports the rule that blocks it, which is the more
            // useful thing to tell someone than "it changed".
            if candidate.deviceID != 0 || candidate.inode != 0 {
                guard candidate.deviceID == identity.device,
                      candidate.inode == identity.inode else {
                    return .failure(.vanished(candidate.url),
                                    detail: "This is no longer the item Loupe measured.")
                }
            } else {
                // `ReclaimCandidate` defaults both fields to zero, so a plan
                // assembled by hand can arrive without them. Every other guard
                // still runs; only this comparison has nothing to compare to.
                LoupeLogReclaim.security.notice(
                    "candidate \(candidate.url.lastPathComponent, privacy: .public) carries no recorded identity; proceeding on the path guards alone")
            }
            // For anything that is not a directory the current figure is one
            // `lstat` away, so it is taken fresh. A directory's figure is the
            // one the plan measured; the sheet recomputes the plan when it
            // opens, so the window is seconds, and re-walking a 6 GB tree to
            // shave a rounding error off a number the user has already seen is
            // not a trade worth making.
            let bytes = identity.isDirectory ? candidate.physicalBytes : identity.physicalBytes
            return .success(bytes: bytes)
        }
    }

    // MARK: - The one primitive

    private enum MoveResult {
        case success(URL?)
        case failure(ReclaimFailure, detail: String)
    }

    private func moveToTrash(_ url: URL) -> MoveResult {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            LoupeLogReclaim.reclaim.info("moved \(url.lastPathComponent, privacy: .public) to the Trash")
            return .success(resulting as URL?)
        } catch {
            return .failure(Self.classify(error, url: url), detail: error.localizedDescription)
        }
    }

    /// Maps what `trashItem` actually throws onto the contract's failure cases.
    ///
    /// The spec lists the causes as real and the specific `NSCocoaErrorDomain`
    /// codes as unverified on macOS 26, so this matches on the codes it knows
    /// and falls through to the system's own message rather than inventing a
    /// category for an error it has not seen. A generic "couldn't delete some
    /// items" is never produced.
    static func classify(_ error: Error, url: URL) -> ReclaimFailure {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .vanished(url)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .permissionDenied(url)
            case NSFileWriteVolumeReadOnlyError:
                return .trashUnavailable(url, reason: "The volume is mounted read-only.")
            case NSFeatureUnsupportedError:
                return .trashUnavailable(
                    url,
                    reason: "This volume does not have a Trash. Delete it in Finder if you want it gone.")
            case NSFileWriteOutOfSpaceError:
                return .trashUnavailable(url, reason: "The volume is full.")
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case ENOENT: return .vanished(url)
            case EACCES, EPERM: return .permissionDenied(url)
            case EROFS: return .trashUnavailable(url, reason: "The volume is mounted read-only.")
            case ENOTSUP: return .trashUnavailable(
                url,
                reason: "This volume does not have a Trash. Delete it in Finder if you want it gone.")
            default: break
            }
        }
        return .trashUnavailable(url, reason: nsError.localizedDescription)
    }

    /// The owner's name, for a permission failure the user needs to understand.
    /// Loupe never offers to elevate; it says whose file it is and stops.
    public static func ownerName(of url: URL) -> String? {
        guard let identity = FileIdentity.lstat(url) else { return nil }
        guard let record = getpwuid(identity.uid), let name = record.pointee.pw_name else {
            return nil
        }
        return String(cString: name)
    }
}
