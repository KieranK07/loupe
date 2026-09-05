import Foundation

// The safety boundary for Pillar 2, expressed as types rather than as prose in a
// review comment. Everything here exists to make one class of mistake — deleting
// something the user needed — hard to write and easy to test for.

/// How much it costs to be wrong about a target.
///
/// Ordinal and comparable so the UI can gate behaviour on severity without
/// hard-coding a list of ids. A category's level is the **maximum** over its
/// members: a bundle of caches containing one irreplaceable thing is as
/// dangerous as that thing.
public enum SafetyLevel: Int, Sendable, Comparable, CaseIterable, Codable {
    /// Rebuilt locally the next time the tool runs. Costs CPU time and nothing
    /// else — no network, no manual step. Xcode's DerivedData, module caches.
    case rebuildsLocally = 1
    /// Cannot be rebuilt; must be fetched over the network again. Homebrew, npm,
    /// pip and uv download caches.
    case redownloads = 2
    /// A large or slow re-acquisition — gigabytes, or a manual step in another
    /// app. Simulator runtimes, iOS device support.
    case redownloadsLarge = 3
    /// Destroys local state that exists nowhere else and cannot be downloaded.
    /// Docker volumes, iOS device backups.
    case losesLocalState = 4
    /// Files the user made and may never have copied anywhere. Downloads.
    case userData = 5

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Level 4 and up must never be pre-selected and must require an explicit
    /// typed confirmation rather than a single click.
    public var requiresTypedConfirmation: Bool { self >= .losesLocalState }

    /// Whether a whole category may be selected in one action. Only the two
    /// levels that cost time rather than data.
    public var allowsSelectAll: Bool { self <= .redownloads }

    /// Said from the user's side: what it costs them to be wrong.
    public var label: String {
        switch self {
        case .rebuildsLocally:  "Rebuilds on this Mac"
        case .redownloads:      "Downloads again"
        case .redownloadsLarge: "Large download to restore"
        case .losesLocalState:  "Destroys local state"
        case .userData:         "Your own files"
        }
    }
}

/// How an entry is actually removed — because not everything Loupe *shows* is
/// something Loupe *deletes*.
public enum DeletionMechanism: String, Sendable, Hashable, Codable {
    /// Loupe moves it to the Trash itself. The only value the executor accepts.
    case trash
    /// Another tool owns the deletion; Loupe explains and steps aside.
    case delegatedToTool
    /// Loupe reveals it and lets the user decide in Finder.
    case revealInFinder
    /// Shown for information only. Never selectable.
    case reviewOnly
}

/// One curated place worth looking. Never a rule for "find junk" — always a
/// specific, named thing with a stated consequence.
public struct CleanupTarget: Sendable, Identifiable, Hashable {
    public let id: String
    public let displayName: String
    /// Absolute paths or glob patterns. Resolved and re-checked against the
    /// blocklist at plan time; never trusted as written.
    public let patterns: [String]
    public let safety: SafetyLevel
    /// One plain sentence: exactly what stops working or is lost. Required.
    public let whatBreaks: String
    /// How it comes back, in the user's terms. Required.
    public let regeneration: String
    /// Bundle identifiers *and* bare executable names that must not be running.
    ///
    /// A list, not one identifier: entry 16 covers eight browsers, and the
    /// CoreSimulator helpers that matter have no bundle identifier at all.
    public let refuseWhileRunning: [String]
    /// How this entry is removed. Only `.trash` is ever executed by Loupe.
    public let mechanism: DeletionMechanism
    public let isPerUser: Bool

    public init(id: String, displayName: String, patterns: [String], safety: SafetyLevel,
                whatBreaks: String, regeneration: String,
                refuseWhileRunning: [String] = [],
                mechanism: DeletionMechanism = .trash, isPerUser: Bool = true) {
        self.id = id; self.displayName = displayName; self.patterns = patterns
        self.safety = safety; self.whatBreaks = whatBreaks
        self.regeneration = regeneration; self.refuseWhileRunning = refuseWhileRunning
        self.mechanism = mechanism; self.isPerUser = isPerUser
    }

    /// Only `.trash` entries are ever selectable for deletion.
    public var isDeletableByLoupe: Bool { mechanism == .trash }
}

/// Why a path was refused. Enforced in code, never merely in the UI.
public enum BlocklistRule: String, Sendable, Hashable, CaseIterable, Codable {
    case systemPath          // /System
    case usrOutsideLocal     // /usr, except /usr/local
    case libraryApple        // /Library/Apple
    case keychains           // ~/Library/Keychains
    case groupContainers     // ~/Library/Group Containers
    case icloudPlaceholder   // SF_DATALESS — deleting evicts the only copy
    case runningAppBundle    // inside a bundle with a live process
    case gitDirectory        // .git
    case sipRestricted       // SF_RESTRICTED
    case volumeRoot          // the root of any volume
    case outsideTargetScope  // resolved outside every pattern it claimed to match
    case protectedContainer  // ~/Library, /Applications, /Users — a container, not a cache
    case lockedItem          // UF_IMMUTABLE / SF_IMMUTABLE — the user locked it
    case readOnlyVolume      // the volume refuses writes

    public var explanation: String {
        switch self {
        case .systemPath:        "Part of macOS itself."
        case .usrOutsideLocal:   "A system directory. Only /usr/local is user-managed."
        case .libraryApple:      "Managed by macOS, including XProtect."
        case .keychains:         "Your passwords and certificates live here."
        case .groupContainers:   "Shared app data. Removing it can sign you out of apps."
        case .icloudPlaceholder: "Stored in iCloud and not downloaded — deleting the placeholder removes the file everywhere."
        case .runningAppBundle:  "Belongs to an app that is running right now."
        case .gitDirectory:      "A repository's history. Deleting it destroys uncommitted and unpushed work."
        case .sipRestricted:     "Protected by System Integrity Protection."
        case .volumeRoot:        "The root of a volume."
        case .outsideTargetScope:"Resolved to a location outside what this cleanup covers."
        case .protectedContainer:"A container macOS or your apps rely on, not a cache."
        case .lockedItem:        "Locked. Unlock it in Finder's Get Info if you really want it gone."
        case .readOnlyVolume:    "The volume is read-only."
        }
    }
}

public struct BlockedPath: Sendable, Hashable, Identifiable {
    public let url: URL
    public let rule: BlocklistRule
    public var id: String { url.path + rule.rawValue }
    public init(url: URL, rule: BlocklistRule) { self.url = url; self.rule = rule }
}

/// One concrete thing found on disk for a target.
public struct ReclaimCandidate: Sendable, Hashable, Identifiable {
    public let url: URL
    public let targetID: String
    /// Bytes actually freed if this goes. Always physical — a logical figure
    /// here would overstate the benefit, which is the exact lie this app exists
    /// not to tell.
    public let physicalBytes: UInt64
    public let itemCount: UInt32
    public let lastModified: Date?
    /// Identity at plan time. Re-validation compares these before trashing, so a
    /// same-path-different-inode swap between plan and execute is caught — the
    /// one aliasing window a path-based re-check cannot close.
    public let deviceID: Int32
    public let inode: UInt64
    public var id: String { url.path }

    public init(url: URL, targetID: String, physicalBytes: UInt64,
                itemCount: UInt32, lastModified: Date?,
                deviceID: Int32 = 0, inode: UInt64 = 0) {
        self.url = url; self.targetID = targetID; self.physicalBytes = physicalBytes
        self.itemCount = itemCount; self.lastModified = lastModified
        self.deviceID = deviceID; self.inode = inode
    }
}

/// The result of a dry run. **Nothing is ever deleted without one of these
/// having been shown first.**
public struct ReclaimPlan: Sendable {
    public let candidates: [ReclaimCandidate]
    /// Paths that matched a pattern and were refused anyway. Surfaced, not
    /// silently dropped — a user who asked to clean something deserves to know
    /// what was withheld and why.
    public let blocked: [BlockedPath]
    public let createdAt: Date

    public init(candidates: [ReclaimCandidate], blocked: [BlockedPath], createdAt: Date = .now) {
        self.candidates = candidates; self.blocked = blocked; self.createdAt = createdAt
    }

    public var totalBytes: UInt64 { candidates.reduce(0) { $0 &+ $1.physicalBytes } }
    public var isEmpty: Bool { candidates.isEmpty }

    /// The sentence that must appear on every confirmation sheet.
    ///
    /// Moving something to the Trash does not free space. Saying "reclaim
    /// 40 GB" while the bytes are still on the disk would be exactly the
    /// inflated number this app refuses to print.
    public static let trashCaveat =
        "Moving items to the Trash does not free space until the Trash is emptied."
}

public enum ReclaimFailure: Error, Sendable, Hashable {
    case blocked(BlocklistRule)
    case appRunning(String)
    case trashUnavailable(URL, reason: String)
    case vanished(URL)
    case permissionDenied(URL)
}

public struct ReclaimOutcome: Sendable {
    public let trashed: [URL]
    public let bytesMoved: UInt64
    public let failures: [URL: ReclaimFailure]

    public init(trashed: [URL], bytesMoved: UInt64, failures: [URL: ReclaimFailure]) {
        self.trashed = trashed; self.bytesMoved = bytesMoved; self.failures = failures
    }

    /// Deliberately not called "reclaimed". Nothing has been reclaimed yet.
    public var summary: String {
        "\(trashed.count.formatted()) item\(trashed.count == 1 ? "" : "s") moved to the Trash — "
        + ByteFormat.string(bytesMoved) + ". " + ReclaimPlan.trashCaveat
    }
}
