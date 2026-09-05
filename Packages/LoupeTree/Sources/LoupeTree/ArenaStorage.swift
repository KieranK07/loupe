import Foundation
import LoupeCore

/// One directory's worth of decoded entries, staged by a walker thread before
/// being committed to the arena.
///
/// Staging exists so the arena lock is taken once per *directory* rather than
/// once per entry — roughly 520k acquisitions for a 4M-entry volume instead of
/// four million. Names are held as ranges into a shared byte buffer so staging
/// a directory costs no per-entry String allocation.
public struct StagedFile: Sendable {
    public var nameStart: UInt32
    public var nameLength: UInt8
    public var logicalBytes: UInt64
    public var physicalBlocks: UInt32
    public var mtime: UInt32
    public var flags: FileFlags
    public init(nameStart: UInt32, nameLength: UInt8, logicalBytes: UInt64,
                physicalBlocks: UInt32, mtime: UInt32, flags: FileFlags) {
        self.nameStart = nameStart; self.nameLength = nameLength
        self.logicalBytes = logicalBytes; self.physicalBlocks = physicalBlocks
        self.mtime = mtime; self.flags = flags
    }
}

public struct StagedDir: Sendable {
    public var nameStart: UInt32
    public var nameLength: UInt8
    public var mtime: UInt32
    public var flags: DirFlags
    public init(nameStart: UInt32, nameLength: UInt8, mtime: UInt32, flags: DirFlags) {
        self.nameStart = nameStart; self.nameLength = nameLength
        self.mtime = mtime; self.flags = flags
    }
}

/// Append-only storage for a scanned tree.
///
/// Structure is immutable once written: a node's name, parent and own size never
/// change after its slot is filled. Only subtree totals mutate, and only ever
/// upward. That invariant is what lets a reader project a consistent-if-partial
/// tree while a walk is still running, without copying or locking the whole
/// structure.
public struct Arena: Sendable {
    public private(set) var files: ContiguousArray<FileNode> = []
    public private(set) var dirs: ContiguousArray<DirNode> = []
    public private(set) var names: ContiguousArray<UInt8> = []

    /// Outstanding unfinished subdirectories per directory. Transient: sized to
    /// the directory count (~2 MB for a 4M-entry volume) and dropped when the
    /// walk ends via `finishWalk()`.
    private var pendingChildren: ContiguousArray<UInt32> = []

    public private(set) var hardlinkDuplicates: UInt64 = 0
    public private(set) var datalessCount: UInt64 = 0
    public private(set) var deniedCount: UInt64 = 0

    public init() {}

    public init(reservingCapacityForEntries entries: Int) {
        files.reserveCapacity(entries * 7 / 8)
        dirs.reserveCapacity(entries / 8)
        names.reserveCapacity(entries * 24)
        pendingChildren.reserveCapacity(entries / 8)
    }

    // MARK: Names

    @inlinable public func name(ofFile slot: UInt32) -> String {
        let n = files[Int(slot)]
        return decodeName(offset: n.nameOffset, length: n.nameLength)
    }

    @inlinable public func name(ofDirectory slot: UInt32) -> String {
        let n = dirs[Int(slot)]
        return decodeName(offset: n.nameOffset, length: n.nameLength)
    }

    @usableFromInline func decodeName(offset: UInt32, length: UInt8) -> String {
        let start = Int(offset), count = Int(length)
        guard start + count <= names.count else { return "" }
        return names.withUnsafeBufferPointer { buf in
            String(decoding: UnsafeBufferPointer(rebasing: buf[start..<start + count]), as: UTF8.self)
        }
    }

    public func name(of ref: NodeRef) -> String {
        guard ref.isValid else { return "" }
        return ref.isDirectory ? name(ofDirectory: ref.slot) : name(ofFile: ref.slot)
    }

    // MARK: Building

    /// Creates the scan root. Must be called exactly once, before any commit.
    public mutating func createRoot(name rootName: String, mtime: UInt32 = 0) -> UInt32 {
        precondition(dirs.isEmpty, "root already exists")
        let off = appendNameBytes(Array(rootName.utf8))
        dirs.append(DirNode(nameOffset: off.0, parentDir: -1, mtime: mtime,
                            nameLength: off.1, depth: 0, flags: [.incomplete]))
        pendingChildren.append(0)
        return 0
    }

    private mutating func appendNameBytes(_ bytes: [UInt8]) -> (UInt32, UInt8) {
        // Measured: zero names above 255 bytes across ~2M real entries. Longer
        // names are truncated for display only; the walk still descends by fd.
        let clipped = bytes.count > 255 ? Array(bytes.prefix(255)) : bytes
        let offset = UInt32(names.count)
        names.append(contentsOf: clipped)
        return (offset, UInt8(clipped.count))
    }

    /// Commits one directory's children in a single critical section.
    ///
    /// File sizes are folded into the parent's totals immediately, because files
    /// are leaves and their contribution is already final. Subdirectories are
    /// counted as outstanding until each reports back via `completeDirectory`.
    ///
    /// - Returns: the slot range of newly created subdirectories, for the walker
    ///   to push as work items, and whether the parent completed immediately
    ///   (a directory containing no subdirectories is finished the moment it is
    ///   committed).
    @discardableResult
    public mutating func commitChildren(
        parent: UInt32, nameBuffer stagingNames: [UInt8],
        files staged: [StagedFile], dirs stagedDirs: [StagedDir]
    ) -> (newDirectorySlots: Range<UInt32>, parentCompleted: Bool) {
        let parentIndex = Int(parent)
        let parentDepth = dirs[parentIndex].depth

        let fileStart = UInt32(files.count)
        var physSum: UInt64 = 0, logSum: UInt64 = 0

        for s in staged {
            let bytes = Array(stagingNames[Int(s.nameStart)..<Int(s.nameStart) + Int(s.nameLength)])
            let (off, len) = appendNameBytes(bytes)
            files.append(FileNode(nameOffset: off, parentDir: Int32(parent),
                                  logicalBytes: s.logicalBytes,
                                  physicalBlocks: s.physicalBlocks,
                                  mtime: s.mtime, nameLength: len, flags: s.flags))
            if s.flags.contains(.hardlinkDuplicate) {
                hardlinkDuplicates &+= 1        // counted once already, contributes nothing
            } else {
                physSum &+= UInt64(s.physicalBlocks) &* 4096
                logSum &+= s.logicalBytes
            }
            if s.flags.contains(.dataless) { datalessCount &+= 1 }
        }

        let dirStart = UInt32(dirs.count)
        for s in stagedDirs {
            let bytes = Array(stagingNames[Int(s.nameStart)..<Int(s.nameStart) + Int(s.nameLength)])
            let (off, len) = appendNameBytes(bytes)
            // A denied directory is never walked, so nothing will ever call
            // completeDirectory on it. Marking it `.incomplete` would leave it
            // reading as "still scanning" for the life of the arena, long after
            // the walk ended. It is not in progress; it is unreadable, which
            // `.denied` already says.
            let dirFlags = s.flags.contains(.denied) ? s.flags : s.flags.union(.incomplete)
            dirs.append(DirNode(nameOffset: off, parentDir: Int32(parent),
                                mtime: s.mtime, nameLength: len,
                                depth: parentDepth &+ 1, flags: dirFlags))
            pendingChildren.append(0)
            if s.flags.contains(.denied) { deniedCount &+= 1 }
        }
        let dirEnd = UInt32(dirs.count)

        dirs[parentIndex].fileChildStart = fileStart
        dirs[parentIndex].fileChildCount = UInt32(staged.count)
        dirs[parentIndex].dirChildStart = dirStart
        dirs[parentIndex].dirChildCount = UInt32(stagedDirs.count)
        dirs[parentIndex].subtreePhysicalBytes &+= physSum
        dirs[parentIndex].subtreeLogicalBytes &+= logSum
        dirs[parentIndex].subtreeItems &+= UInt32(staged.count)

        // A denied subdirectory never reports back, so it must not be counted
        // as outstanding or its parent would never complete.
        let liveChildren = stagedDirs.filter { !$0.flags.contains(.denied) }.count
        pendingChildren[parentIndex] = UInt32(liveChildren)
        return (dirStart..<dirEnd, liveChildren == 0)
    }

    /// Folds a finished directory's totals into its parent.
    /// - Returns: the parent's slot if the parent is now finished too, so the
    ///   caller can walk the chain iteratively rather than recursing.
    public mutating func completeDirectory(_ slot: UInt32) -> UInt32? {
        let i = Int(slot)
        dirs[i].flagBits &= ~DirFlags.incomplete.rawValue
        let parent = dirs[i].parentDir
        guard parent >= 0 else { return nil }
        let p = Int(parent)
        dirs[p].subtreePhysicalBytes &+= dirs[i].subtreePhysicalBytes
        dirs[p].subtreeLogicalBytes &+= dirs[i].subtreeLogicalBytes
        dirs[p].subtreeItems &+= dirs[i].subtreeItems &+ 1
        if pendingChildren[p] > 0 { pendingChildren[p] &-= 1 }
        return pendingChildren[p] == 0 ? UInt32(parent) : nil
    }

    /// Drops transient walk bookkeeping once no further mutation will occur.
    public mutating func finishWalk() {
        pendingChildren = []
        if !dirs.isEmpty { dirs[0].flagBits &= ~DirFlags.incomplete.rawValue }
    }

    public mutating func noteDenied() { deniedCount &+= 1 }

    // MARK: Reading

    public var totalEntries: Int { files.count + dirs.count }
    public var rootTotalPhysicalBytes: UInt64 { dirs.first?.subtreePhysicalBytes ?? 0 }
    public var rootTotalLogicalBytes: UInt64 { dirs.first?.subtreeLogicalBytes ?? 0 }

    /// Approximate resident cost, for the budget assertion in the scan summary.
    public var approximateBytesResident: Int {
        files.count * MemoryLayout<FileNode>.stride
        + dirs.count * MemoryLayout<DirNode>.stride
        + names.count
        + pendingChildren.count * MemoryLayout<UInt32>.stride
    }

    public func fileChildren(of dir: UInt32) -> Range<UInt32> {
        let n = dirs[Int(dir)]
        return n.fileChildStart..<(n.fileChildStart &+ n.fileChildCount)
    }

    public func directoryChildren(of dir: UInt32) -> Range<UInt32> {
        let n = dirs[Int(dir)]
        return n.dirChildStart..<(n.dirChildStart &+ n.dirChildCount)
    }

    /// Absolute path of a node, rebuilt by walking parents. O(depth); measured
    /// max depth on a real machine is 25, so this is cheap enough to call for
    /// the inspector but not in a render loop.
    public func path(of ref: NodeRef, rootPath: String) -> String {
        var components: [String] = []
        var currentDir: Int32
        if ref.isDirectory {
            if ref.slot == 0 { return rootPath }
            components.append(name(ofDirectory: ref.slot))
            currentDir = dirs[Int(ref.slot)].parentDir
        } else {
            components.append(name(ofFile: ref.slot))
            currentDir = files[Int(ref.slot)].parentDir
        }
        while currentDir > 0 {
            components.append(name(ofDirectory: UInt32(currentDir)))
            currentDir = dirs[Int(currentDir)].parentDir
        }
        return rootPath + "/" + components.reversed().joined(separator: "/")
    }
}
