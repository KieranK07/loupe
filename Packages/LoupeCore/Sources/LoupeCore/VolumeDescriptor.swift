import Foundation

/// A mounted local volume Loupe can scan.
///
/// Loupe never crosses a device boundary during a walk, so each volume is a
/// separate scan target the user chooses explicitly.
public struct VolumeDescriptor: Sendable, Identifiable, Hashable {
    public let mountPoint: URL
    public let name: String
    /// e.g. "disk3s5"
    public let bsdName: String
    /// `st_dev`, used to enforce the device boundary during the walk.
    public let deviceID: Int32
    public let isReadOnly: Bool
    public let isInternal: Bool
    /// True for `/System/Volumes/Data` — the writable half of the boot volume,
    /// and Loupe's default scan root. Walking `/` instead would mean traversing
    /// firmlinks back into this same volume and double-counting it.
    public let isRootDataVolume: Bool
    /// The sealed, read-only system volume mounted at `/`. Never walked; shown
    /// as a single fixed entry.
    public let isSealedSystemVolume: Bool

    public let totalCapacity: UInt64
    public let availableCapacity: UInt64
    /// `volumeAvailableCapacityForImportantUsage` — what the system will
    /// actually let you use, after evicting purgeable content.
    public let availableForImportantUsage: UInt64

    public var id: String { bsdName }

    /// The gap between what the volume says is free and what the system will
    /// really free up on demand: local APFS snapshots and purgeable caches.
    /// This is why Finder's "Available" disagrees with everything else, and
    /// Loupe explains it rather than hiding it.
    public var purgeableEstimate: UInt64 {
        availableForImportantUsage > availableCapacity
            ? availableForImportantUsage - availableCapacity
            : 0
    }

    /// An APFS helper volume — Preboot, VM, Update, xART, iSCPreboot, Hardware.
    ///
    /// These are real mounted volumes but they are machinery, not places a user
    /// keeps things. Listing them invites someone to "scan" Preboot, and because
    /// every volume in a container reports the *container's* free space, each one
    /// also claims the whole disk. Both are wrong to show.
    public var isHelperVolume: Bool {
        guard !isRootDataVolume, !isSealedSystemVolume else { return false }
        return mountPoint.path(percentEncoded: false).hasPrefix("/System/Volumes/")
    }

    /// Volumes a user can meaningfully choose to scan: the boot volume (via its
    /// writable Data half) and anything mounted under `/Volumes`.
    public var isUserSelectable: Bool {
        if isRootDataVolume { return true }
        if isSealedSystemVolume || isHelperVolume { return false }
        return mountPoint.path(percentEncoded: false).hasPrefix("/Volumes/")
    }

    public var usedCapacity: UInt64 {
        totalCapacity > availableCapacity ? totalCapacity - availableCapacity : 0
    }

    public init(mountPoint: URL, name: String, bsdName: String, deviceID: Int32,
                isReadOnly: Bool, isInternal: Bool, isRootDataVolume: Bool,
                isSealedSystemVolume: Bool, totalCapacity: UInt64,
                availableCapacity: UInt64, availableForImportantUsage: UInt64) {
        self.mountPoint = mountPoint; self.name = name; self.bsdName = bsdName
        self.deviceID = deviceID; self.isReadOnly = isReadOnly
        self.isInternal = isInternal; self.isRootDataVolume = isRootDataVolume
        self.isSealedSystemVolume = isSealedSystemVolume
        self.totalCapacity = totalCapacity; self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
    }
}

/// A local APFS snapshot. Surfaced because snapshots are the most common reason
/// a Mac reports far less free space than the file tree accounts for.
public struct LocalSnapshot: Sendable, Identifiable, Hashable {
    public let name: String
    public let createdAt: Date?
    public var id: String { name }
    public init(name: String, createdAt: Date?) { self.name = name; self.createdAt = createdAt }
}


/// Where a volume's bytes actually went, reconciled against what the walk saw.
///
/// This exists because Finder's "Available" disagrees with every other number on
/// a modern Mac, and the honest response is to show the pieces rather than to
/// pick one and hope. Every field is something Loupe can point at; whatever is
/// left over goes in `unaccounted` instead of being quietly absorbed.
public struct SpaceBreakdown: Sendable, Hashable {
    public let volume: VolumeDescriptor
    /// What the walk actually measured, in physical bytes.
    public let scannedBytes: UInt64
    /// The sealed, read-only system volume, if it has been measured.
    ///
    /// `nil` means "not measured", which is the default and the honest answer:
    /// every volume in an APFS container reports the *container's* capacity and
    /// free space through statfs, so there is no cheap way to ask how large the
    /// system volume actually is. Loupe would have to walk it. Rather than
    /// invent a number, it says so and folds it into `unaccounted`.
    public let systemVolumeBytes: UInt64?
    /// Local APFS snapshots. The most common reason a Mac reports far less free
    /// space than its file tree accounts for.
    public let snapshots: [LocalSnapshot]
    public let snapshotBytes: UInt64
    /// Content macOS will evict on demand: caches, and snapshots it can roll off.
    /// Derived from the gap between plain availability and important-usage
    /// availability, so it is an estimate and is labelled as one.
    public let purgeableBytes: UInt64
    /// Directories the walk could not open. Named, not hidden.
    public let unreadableCount: UInt64

    public init(volume: VolumeDescriptor, scannedBytes: UInt64, systemVolumeBytes: UInt64? = nil,
                snapshots: [LocalSnapshot], snapshotBytes: UInt64,
                purgeableBytes: UInt64, unreadableCount: UInt64) {
        self.volume = volume; self.scannedBytes = scannedBytes
        self.systemVolumeBytes = systemVolumeBytes; self.snapshots = snapshots
        self.snapshotBytes = snapshotBytes; self.purgeableBytes = purgeableBytes
        self.unreadableCount = unreadableCount
    }

    public var freeBytes: UInt64 { volume.availableCapacity }

    /// The residual. Loupe shows this rather than distributing it into a bucket
    /// called "Other" — an unexplained number the user can see is worth more than
    /// a tidy one they cannot check.
    public var unaccountedBytes: UInt64 {
        let claimed = scannedBytes &+ (systemVolumeBytes ?? 0) &+ freeBytes
        return volume.totalCapacity > claimed ? volume.totalCapacity - claimed : 0
    }

    /// What is actually in the residual, said plainly. The user can check every
    /// clause of this against something they can see.
    public var unaccountedExplanation: String {
        var causes = ["the sealed macOS system volume, which Loupe does not walk"]
        if !snapshots.isEmpty { causes.append("storage held by local snapshots") }
        if purgeableBytes > 0 { causes.append("purgeable caches") }
        if unreadableCount > 0 { causes.append("\(unreadableCount.formatted()) folders Loupe could not read") }
        return "Loupe cannot see " + ByteFormat.string(unaccountedBytes) + ". This is "
             + causes.joined(separator: ", ") + "."
    }

    /// Plain-language explanation of the gap, or nil when there is nothing to explain.
    public var systemDataExplanation: String? {
        guard purgeableBytes > 0 || !snapshots.isEmpty else { return nil }
        var parts: [String] = []
        if !snapshots.isEmpty {
            parts.append("\(snapshots.count) local snapshot\(snapshots.count == 1 ? "" : "s")")
        }
        if purgeableBytes > 0 {
            parts.append("\(ByteFormat.string(purgeableBytes)) of purgeable content")
        }
        return "Finder reports more free space than the file tree accounts for because of "
             + parts.joined(separator: " and ")
             + ". macOS reclaims this automatically when a disk fills up."
    }
}
