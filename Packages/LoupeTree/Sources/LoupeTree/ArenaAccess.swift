import Foundation
import LoupeCore

// Shared arena access for the two layout engines.
//
// The sunburst projector and the treemap layouter need exactly the same two
// things: a pointer-based view of the arena for the hot loop, and the breadcrumb
// from the root to the focus. These lived twice, once in each file, byte for
// byte identical. Two copies of a path calculation that must agree is a bug
// waiting for someone to fix one of them — so there is now one.

struct ArenaView {
    let files: UnsafeBufferPointer<FileNode>
    let dirs: UnsafeBufferPointer<DirNode>
    let names: UnsafeBufferPointer<UInt8>

    @inline(__always)
    func fileChildren(of dir: UInt32) -> Range<UInt32> {
        let node = dirs[Int(dir)]
        return node.fileChildStart..<(node.fileChildStart &+ node.fileChildCount)
    }

    @inline(__always)
    func directoryChildren(of dir: UInt32) -> Range<UInt32> {
        let node = dirs[Int(dir)]
        return node.dirChildStart..<(node.dirChildStart &+ node.dirChildCount)
    }

    /// What a directory's children currently add up to, in both bases.
    func childTotals(of dir: UInt32) -> (physical: UInt64, logical: UInt64) {
        var physical: UInt64 = 0, logical: UInt64 = 0
        for slot in fileChildren(of: dir) {
            let bytes = contributedBytes(files[Int(slot)])
            physical &+= bytes.physical
            logical &+= bytes.logical
        }
        for slot in directoryChildren(of: dir) {
            let node = dirs[Int(slot)]
            physical &+= node.subtreePhysicalBytes
            logical &+= node.subtreeLogicalBytes
        }
        return (physical, logical)
    }

    func name(offset: UInt32, length: UInt8) -> String {
        let start = Int(offset), count = Int(length)
        guard count > 0, start >= 0, start + count <= names.count else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: names[start..<start + count]),
                      as: UTF8.self)
    }
}

/// The chain from the arena root down to `focus`, inclusive, in order.
///
/// Shared so the sunburst and the treemap can never disagree about the path to
/// the thing the user is looking at.
func arenaBreadcrumb(arena: Arena, focus: NodeRef) -> [Breadcrumb] {
    var crumbs: [Breadcrumb] = []
    var parent: Int32

    if focus.isDirectory {
        crumbs.append(Breadcrumb(node: focus, name: arena.name(ofDirectory: focus.slot)))
        if focus.slot == 0 { return crumbs }
        parent = arena.dirs[Int(focus.slot)].parentDir
    } else {
        crumbs.append(Breadcrumb(node: focus, name: arena.name(ofFile: focus.slot)))
        parent = arena.files[Int(focus.slot)].parentDir
    }

    // `depth` is a `UInt8`, so a well-formed chain is at most 256 long. The cap
    // turns a corrupt parent link into a short breadcrumb instead of a hang on
    // whatever thread the projection happens to be running on.
    var steps = 0
    while parent >= 0, Int(parent) < arena.dirs.count, steps < 256 {
        let dir = UInt32(parent)
        crumbs.append(Breadcrumb(node: .directory(dir), name: arena.name(ofDirectory: dir)))
        if parent == 0 { break }
        parent = arena.dirs[Int(parent)].parentDir
        steps += 1
    }
    return crumbs.reversed()
}
