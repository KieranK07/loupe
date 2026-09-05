import Foundation
import LoupeCore

// MARK: - Node storage
//
// Two arenas of POD structs, not a graph of class instances. At four million
// nodes, ARC traffic and allocator pressure for reference-counted nodes would
// cost more than the entire filesystem walk. These structs are never allocated
// individually; they live in ContiguousArrays and are addressed by index.
//
// The stride of each is pinned by a test. Changing a field without updating the
// memory budget in docs/ARCHITECTURE.md should fail CI, not surprise someone
// three months later when a 1 TB volume runs the app out of memory.

public struct FileFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// SF_DATALESS — an iCloud placeholder. Logical size is real; almost no
    /// bytes are actually here.
    public static let dataless          = FileFlags(rawValue: 1 << 0)
    /// May share blocks with another file (APFS clone). Deleting it frees less
    /// than its size suggests.
    public static let clone             = FileFlags(rawValue: 1 << 1)
    /// A second or later sighting of an inode we have already counted. Carries
    /// zero bytes so volume totals stay correct.
    public static let hardlinkDuplicate = FileFlags(rawValue: 1 << 2)
    /// SF_RESTRICTED — SIP-protected. Never deletable, whatever the UI says.
    public static let restricted        = FileFlags(rawValue: 1 << 3)
    /// UF_COMPRESSED — logical size exceeds bytes on disk.
    public static let compressed        = FileFlags(rawValue: 1 << 4)
}

public struct DirFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    /// Could not be opened. Its subtree is missing from every total, and the UI
    /// must say so rather than quietly under-reporting.
    public static let denied       = DirFlags(rawValue: 1 << 0)
    /// SF_FIRMLINK — never traversed; following it re-enters the Data volume
    /// and double-counts everything.
    public static let firmlink     = DirFlags(rawValue: 1 << 1)
    /// Sits on a different device than the scan root. Not walked.
    public static let crossedDevice = DirFlags(rawValue: 1 << 2)
    public static let restricted   = DirFlags(rawValue: 1 << 3)
    /// Subtree still being walked; totals will grow.
    public static let incomplete   = DirFlags(rawValue: 1 << 4)
}

/// 32 bytes. Stride pinned by `ArenaLayoutTests`.
public struct FileNode: Sendable {
    public var nameOffset: UInt32
    public var parentDir: Int32
    /// Exact bytes. Deliberately not block-encoded: rounding every small file up
    /// to 4 KiB would overstate a directory of 100k small files by ~400 MB.
    public var logicalBytes: UInt64
    /// Allocated size divided by 4096. Always exact, because allocations are
    /// always block multiples. Ceiling is 16 TiB per file.
    public var physicalBlocks: UInt32
    public var mtime: UInt32
    public var nameLength: UInt8
    public var flagBits: UInt8

    @inlinable public var flags: FileFlags { FileFlags(rawValue: flagBits) }
    @inlinable public var physicalBytes: UInt64 { UInt64(physicalBlocks) &* 4096 }

    public init(nameOffset: UInt32, parentDir: Int32, logicalBytes: UInt64,
                physicalBlocks: UInt32, mtime: UInt32, nameLength: UInt8, flags: FileFlags) {
        self.nameOffset = nameOffset; self.parentDir = parentDir
        self.logicalBytes = logicalBytes; self.physicalBlocks = physicalBlocks
        self.mtime = mtime; self.nameLength = nameLength; self.flagBits = flags.rawValue
    }
}

/// 56 bytes. Stride pinned by `ArenaLayoutTests`.
///
/// Children are stored as two contiguous runs — files, then subdirectories —
/// because `getattrlistbulk` hands back a whole directory at once, so the walker
/// can partition and append each group in one go. That removes the need for
/// sibling pointers entirely and makes iterating a directory a linear scan.
public struct DirNode: Sendable {
    public var nameOffset: UInt32
    public var parentDir: Int32
    public var subtreePhysicalBytes: UInt64
    public var subtreeLogicalBytes: UInt64
    public var fileChildStart: UInt32
    public var fileChildCount: UInt32
    public var dirChildStart: UInt32
    public var dirChildCount: UInt32
    public var subtreeItems: UInt32
    public var mtime: UInt32
    public var nameLength: UInt8
    public var depth: UInt8
    public var flagBits: UInt16

    @inlinable public var flags: DirFlags { DirFlags(rawValue: flagBits) }

    public init(nameOffset: UInt32, parentDir: Int32, mtime: UInt32,
                nameLength: UInt8, depth: UInt8, flags: DirFlags) {
        self.nameOffset = nameOffset; self.parentDir = parentDir
        self.subtreePhysicalBytes = 0; self.subtreeLogicalBytes = 0
        self.fileChildStart = 0; self.fileChildCount = 0
        self.dirChildStart = 0; self.dirChildCount = 0
        self.subtreeItems = 0; self.mtime = mtime
        self.nameLength = nameLength; self.depth = depth; self.flagBits = flags.rawValue
    }
}
