import Testing
import Foundation
import LoupeCore
@testable import LoupeTree

@Suite("Arena memory layout — pins the budget in docs/ARCHITECTURE.md")
struct ArenaLayoutTests {
    /// If either of these changes, the projected memory figure for a 1 TB
    /// volume changes with it. Update the architecture doc in the same commit.
    @Test("node strides are exactly as budgeted")
    func strides() {
        #expect(MemoryLayout<FileNode>.stride == 32)
        #expect(MemoryLayout<DirNode>.stride == 56)
    }

    @Test("projected 4M-entry volume stays inside the 300MB target")
    func budget() {
        // Ratio and name length both measured on a real 1.97M-entry home dir.
        let entries = 4_000_000
        let fileCount = entries * 7 / 8, dirCount = entries / 8
        let bytes = fileCount * MemoryLayout<FileNode>.stride
                  + dirCount * MemoryLayout<DirNode>.stride
                  + entries * 23                       // 22.8 B/name measured
                  + dirCount * MemoryLayout<UInt32>.stride
        #expect(bytes < 300 * 1_000_000)
    }
}

@Suite("Arena roll-up arithmetic")
struct ArenaRollupTests {

    /// root ├── a ├── f1(100 blk) f2(200 blk)  └── b ── f3(300 blk)
    ///      └── c ── f4(400 blk)
    private func buildTree() -> Arena {
        var arena = Arena()
        let root = arena.createRoot(name: "root")

        func names(_ list: [String]) -> ([UInt8], [(UInt32, UInt8)]) {
            var buf: [UInt8] = []; var spans: [(UInt32, UInt8)] = []
            for n in list {
                let b = Array(n.utf8)
                spans.append((UInt32(buf.count), UInt8(b.count)))
                buf.append(contentsOf: b)
            }
            return (buf, spans)
        }

        // root's children: two directories, no files
        var (buf, spans) = names(["a", "c"])
        let rootCommit = arena.commitChildren(
            parent: root, nameBuffer: buf, files: [],
            dirs: [StagedDir(nameStart: spans[0].0, nameLength: spans[0].1, mtime: 0, flags: []),
                   StagedDir(nameStart: spans[1].0, nameLength: spans[1].1, mtime: 0, flags: [])])
        #expect(!rootCommit.parentCompleted)
        let a = rootCommit.newDirectorySlots.lowerBound
        let c = a + 1

        // a's children: f1, f2 and directory b
        (buf, spans) = names(["f1", "f2", "b"])
        let aCommit = arena.commitChildren(
            parent: a, nameBuffer: buf,
            files: [StagedFile(nameStart: spans[0].0, nameLength: spans[0].1,
                               logicalBytes: 100 * 4096, physicalBlocks: 100, mtime: 0, flags: []),
                    StagedFile(nameStart: spans[1].0, nameLength: spans[1].1,
                               logicalBytes: 200 * 4096, physicalBlocks: 200, mtime: 0, flags: [])],
            dirs: [StagedDir(nameStart: spans[2].0, nameLength: spans[2].1, mtime: 0, flags: [])])
        #expect(!aCommit.parentCompleted)
        let b = aCommit.newDirectorySlots.lowerBound

        // b's children: f3 only -> b finishes on commit
        (buf, spans) = names(["f3"])
        let bCommit = arena.commitChildren(
            parent: b, nameBuffer: buf,
            files: [StagedFile(nameStart: spans[0].0, nameLength: spans[0].1,
                               logicalBytes: 300 * 4096, physicalBlocks: 300, mtime: 0, flags: [])],
            dirs: [])
        #expect(bCommit.parentCompleted)

        // unwind b -> a -> root
        var next: UInt32? = b
        while let slot = next { next = arena.completeDirectory(slot) }

        // c's children: f4 only
        (buf, spans) = names(["f4"])
        let cCommit = arena.commitChildren(
            parent: c, nameBuffer: buf,
            files: [StagedFile(nameStart: spans[0].0, nameLength: spans[0].1,
                               logicalBytes: 400 * 4096, physicalBlocks: 400, mtime: 0, flags: [])],
            dirs: [])
        #expect(cCommit.parentCompleted)
        next = c
        while let slot = next { next = arena.completeDirectory(slot) }

        arena.finishWalk()
        return arena
    }

    @Test("totals roll all the way to the root")
    func totals() {
        let arena = buildTree()
        #expect(arena.rootTotalPhysicalBytes == 1000 * 4096)
        #expect(arena.rootTotalLogicalBytes == 1000 * 4096)
        // 4 files + 3 directories beneath the root
        #expect(arena.dirs[0].subtreeItems == 7)
        #expect(arena.totalEntries == 8)   // + the root itself
    }

    @Test("every directory is marked complete when the walk ends")
    func completion() {
        let arena = buildTree()
        for d in arena.dirs { #expect(!d.flags.contains(.incomplete)) }
    }

    @Test("hard-link duplicates are stored but contribute no bytes")
    func hardlinks() {
        var arena = Arena()
        let root = arena.createRoot(name: "root")
        let buf = Array("origdup".utf8)
        arena.commitChildren(
            parent: root, nameBuffer: buf,
            files: [StagedFile(nameStart: 0, nameLength: 4, logicalBytes: 4096,
                               physicalBlocks: 1, mtime: 0, flags: []),
                    StagedFile(nameStart: 4, nameLength: 3, logicalBytes: 4096,
                               physicalBlocks: 1, mtime: 0, flags: [.hardlinkDuplicate])],
            dirs: [])
        // Both nodes exist so the inspector can show the link, but only one pays.
        #expect(arena.files.count == 2)
        #expect(arena.rootTotalPhysicalBytes == 4096)
        #expect(arena.hardlinkDuplicates == 1)
    }

    @Test("a denied directory never blocks its parent from completing")
    func deniedDoesNotStall() {
        var arena = Arena()
        let root = arena.createRoot(name: "root")
        let result = arena.commitChildren(
            parent: root, nameBuffer: Array("locked".utf8), files: [],
            dirs: [StagedDir(nameStart: 0, nameLength: 6, mtime: 0, flags: [.denied])])
        // The subtree is unreadable, so nothing will ever report back for it.
        #expect(result.parentCompleted)
        #expect(arena.deniedCount == 1)
    }

    @Test("paths reconstruct by walking parents")
    func paths() {
        let arena = buildTree()
        // f3 lives at root/a/b/f3
        let f3 = arena.files.indices.first { arena.name(ofFile: UInt32($0)) == "f3" }!
        #expect(arena.path(of: .file(UInt32(f3)), rootPath: "/Volumes/X") == "/Volumes/X/a/b/f3")
        #expect(arena.path(of: .directory(0), rootPath: "/Volumes/X") == "/Volumes/X")
    }
}
