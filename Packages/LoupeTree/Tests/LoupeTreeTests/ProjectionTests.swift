import Testing
import Foundation
import LoupeCore
@testable import LoupeTree

// MARK: - Fixtures
//
// Every arena below is built through the public building API in the same order
// the walker uses it — stage a directory's children into one shared name buffer,
// commit them, unwind completions — so a fixture cannot accidentally construct a
// tree the real scan could never produce.

private struct FileSpec {
    var name: String
    var blocks: UInt32
    var logical: UInt64
    var flags: FileFlags
    init(_ name: String, blocks: UInt32, logical: UInt64? = nil, flags: FileFlags = []) {
        self.name = name
        self.blocks = blocks
        self.logical = logical ?? UInt64(blocks) * 4096
        self.flags = flags
    }
}

private struct DirSpec {
    var name: String
    var flags: DirFlags
    init(_ name: String, flags: DirFlags = []) { self.name = name; self.flags = flags }
}

@discardableResult
private func commit(_ arena: inout Arena, parent: UInt32,
                    files: [FileSpec] = [], dirs: [DirSpec] = []
) -> (dirSlots: Range<UInt32>, completed: Bool) {
    var buffer: [UInt8] = []
    var stagedFiles: [StagedFile] = []
    for spec in files {
        let bytes = Array(spec.name.utf8)
        stagedFiles.append(StagedFile(nameStart: UInt32(buffer.count),
                                      nameLength: UInt8(bytes.count),
                                      logicalBytes: spec.logical,
                                      physicalBlocks: spec.blocks,
                                      mtime: 0, flags: spec.flags))
        buffer.append(contentsOf: bytes)
    }
    var stagedDirs: [StagedDir] = []
    for spec in dirs {
        let bytes = Array(spec.name.utf8)
        stagedDirs.append(StagedDir(nameStart: UInt32(buffer.count),
                                    nameLength: UInt8(bytes.count),
                                    mtime: 0, flags: spec.flags))
        buffer.append(contentsOf: bytes)
    }
    let result = arena.commitChildren(parent: parent, nameBuffer: buffer,
                                      files: stagedFiles, dirs: stagedDirs)
    return (result.newDirectorySlots, result.parentCompleted)
}

private func unwind(_ arena: inout Arena, from slot: UInt32) {
    var next: UInt32? = slot
    while let s = next { next = arena.completeDirectory(s) }
}

private let projector = SunburstProjector(rootPath: "/Volumes/Test")

private extension SunburstProjector {
    /// Every test projects with the same clock and generation unless it is
    /// specifically about those fields.
    func project(_ arena: Arena, focus: NodeRef = .directory(0),
                 basis: SizeBasis = .physical, generation: UInt64 = 1,
                 isComplete: Bool = true) -> SunburstLayout {
        project(arena: arena, focus: focus, basis: basis, generation: generation,
                scannedAt: Date(timeIntervalSince1970: 1_700_000_000), isComplete: isComplete)
    }
}

private func parentDirectory(of ref: NodeRef, in arena: Arena) -> UInt32? {
    let parent = ref.isDirectory ? arena.dirs[Int(ref.slot)].parentDir
                                 : arena.files[Int(ref.slot)].parentDir
    return parent >= 0 ? UInt32(parent) : nil
}

/// The ancestor of `ref` that sits directly under `focus` — the node whose index
/// the colour seed is supposed to be.
private func topLevelAncestor(of ref: NodeRef, in arena: Arena, focus: UInt32) -> NodeRef {
    var current = ref
    while let parent = parentDirectory(of: current, in: arena), parent != focus {
        current = .directory(parent)
    }
    return current
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

private let fullCircle = 2 * Double.pi

// MARK: - Trees

/// root ── big(500 blk) mid(300 blk) small(200 blk)
private func flatArena() -> Arena {
    var arena = Arena()
    let root = arena.createRoot(name: "Test")
    commit(&arena, parent: root, files: [FileSpec("big", blocks: 500),
                                         FileSpec("mid", blocks: 300),
                                         FileSpec("small", blocks: 200)])
    unwind(&arena, from: root)
    arena.finishWalk()
    return arena
}

/// Three top-level directories, each with two subdirectories, each with files.
/// Deep enough to test nesting and colour inheritance, small enough to read.
private func nestedArena() -> Arena {
    var arena = Arena()
    let root = arena.createRoot(name: "Test")
    let tops = commit(&arena, parent: root,
                      dirs: [DirSpec("alpha"), DirSpec("beta"), DirSpec("gamma")]).dirSlots
    for (index, top) in tops.enumerated() {
        let scale = UInt32(index + 1) * 100
        let subs = commit(&arena, parent: top,
                          files: [FileSpec("loose", blocks: scale)],
                          dirs: [DirSpec("one"), DirSpec("two")]).dirSlots
        for (subIndex, sub) in subs.enumerated() {
            commit(&arena, parent: sub,
                   files: [FileSpec("a", blocks: scale * UInt32(subIndex + 2)),
                           FileSpec("b", blocks: scale)])
            unwind(&arena, from: sub)
        }
    }
    arena.finishWalk()
    return arena
}

// MARK: - Angular allocation

@Suite("Sunburst projection — angular allocation")
struct ProjectionAngleTests {

    @Test("children divide the full circle in proportion to their size")
    func proportional() {
        let layout = projector.project(flatArena())
        #expect(layout.wedges.count == 3)

        let total = layout.wedges.reduce(0.0) { $0 + $1.sweep }
        #expect(abs(total - fullCircle) < 1e-12)
        #expect(layout.wedges[0].startAngle == 0)
        #expect(abs(layout.wedges[2].endAngle - fullCircle) < 1e-12)

        #expect(abs(layout.wedges[0].sweep - fullCircle * 0.5) < 1e-12)
        #expect(abs(layout.wedges[1].sweep - fullCircle * 0.3) < 1e-12)
        #expect(abs(layout.wedges[2].sweep - fullCircle * 0.2) < 1e-12)
    }

    @Test("siblings are laid out largest first, and ties break on name")
    func descendingOrder() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("zebra", blocks: 10),
                                             FileSpec("apple", blocks: 10),
                                             FileSpec("mango", blocks: 10),
                                             FileSpec("whale", blocks: 40)])
        unwind(&arena, from: root)
        arena.finishWalk()

        let names = projector.project(arena).wedges.map(\.name)
        // Size first, then the stable secondary key. Without the name tie-break the
        // three equal files come back in whatever order introsort happened to leave.
        #expect(names == ["whale", "apple", "mango", "zebra"])

        let wedges = projector.project(arena).wedges
        for pair in zip(wedges, wedges.dropFirst()) {
            #expect(pair.0.endAngle == pair.1.startAngle)
        }
    }

    @Test("every descendant's arc lies strictly inside its parent's")
    func nesting() {
        let arena = nestedArena()
        let layout = projector.project(arena)
        #expect(layout.wedges.contains { $0.ring >= 2 })

        var byNode: [NodeRef: Wedge] = [:]
        for wedge in layout.wedges { byNode[wedge.node] = wedge }

        for wedge in layout.wedges {
            #expect(wedge.endAngle > wedge.startAngle)
            guard let parentSlot = parentDirectory(of: wedge.node, in: arena) else { continue }
            let parent = byNode[.directory(parentSlot)]
            let start = parent?.startAngle ?? 0
            let end = parent?.endAngle ?? fullCircle
            #expect(wedge.startAngle >= start - 1e-12)
            #expect(wedge.endAngle <= end + 1e-12)
            if let parent {
                #expect(wedge.ring == parent.ring + 1)
            } else {
                #expect(wedge.ring == 0)
            }
        }
    }

    @Test("each ring fills its parent's arc exactly, with no gaps between siblings")
    func ringsFillTheirParent() {
        let arena = nestedArena()
        let layout = projector.project(arena)

        var spans: [NodeRef: [Wedge]] = [:]
        for wedge in layout.wedges {
            let parent = parentDirectory(of: wedge.node, in: arena).map(NodeRef.directory)
            spans[parent ?? .directory(0), default: []].append(wedge)
        }
        for (_, group) in spans {
            let sorted = group.sorted { $0.startAngle < $1.startAngle }
            for pair in zip(sorted, sorted.dropFirst()) {
                #expect(abs(pair.0.endAngle - pair.1.startAngle) < 1e-12)
            }
        }
    }

    @Test("the size basis chooses which of the two true sizes drives the arc")
    func basis() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        // A sparse/compressed file: one block on disk, 100 blocks apparent.
        commit(&arena, parent: root, files: [FileSpec("sparse", blocks: 1, logical: 100 * 4096),
                                             FileSpec("dense", blocks: 50)])
        unwind(&arena, from: root)
        arena.finishWalk()

        #expect(projector.project(arena, basis: .physical).wedges.map(\.name) == ["dense", "sparse"])
        #expect(projector.project(arena, basis: .logical).wedges.map(\.name) == ["sparse", "dense"])
    }
}

// MARK: - Culling and bounds

@Suite("Sunburst projection — bounding the output")
struct ProjectionBoundsTests {

    @Test("sub-pixel siblings collapse into one trailing aggregated wedge")
    func aggregation() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        var files = [FileSpec("payload", blocks: 1_000_000)]
        for i in 0..<40 { files.append(FileSpec("crumb\(i)", blocks: 1)) }
        commit(&arena, parent: root, files: files)
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = projector.project(arena)
        // Forty invisible arcs would cost forty draw calls and hit-test entries for
        // something a third of a pixel wide.
        #expect(layout.wedges.count == 2)
        #expect(layout.wedges[0].kind == .real)
        #expect(layout.wedges[1].kind == .aggregated(count: 40))
        #expect(layout.wedges[1].startAngle == layout.wedges[0].endAngle)
        #expect(abs(layout.wedges[1].endAngle - fullCircle) < 1e-12)
        #expect(layout.wedges[1].physicalBytes == 40 * 4096)
        #expect(layout.wedges[1].itemCount == 40)
        #expect(layout.wedges[1].name == "40 smaller items")
    }

    @Test("no emitted wedge is narrower than the minimum sweep, aggregates aside")
    func minimumSweep() {
        for arena in [flatArena(), nestedArena(), broadAndDeepArena()] {
            for wedge in projector.project(arena).wedges {
                if case .aggregated = wedge.kind { continue }
                // The aggregate is allowed to be thinner than a pixel: it is the one
                // wedge whose job is to stand in for things that are.
                #expect(wedge.sweep >= SunburstGeometry.minimumSweepRadians * (1 - 1e-9))
            }
        }
    }

    @Test("wedge identity is unique, so the aggregate cannot collide with a sibling")
    func uniqueIdentity() {
        let layout = projector.project(broadAndDeepArena())
        #expect(Set(layout.wedges.map(\.id)).count == layout.wedges.count)
    }

    @Test("wedges come out ring-major and angle-ascending")
    func emissionOrder() {
        // `SunburstIndex` slices this array into rings without sorting when it is
        // already in order, ten times a second during a scan. The breadth-first
        // descent gives that ordering for free; this pins it so it stays free.
        for arena in [nestedArena(), broadAndDeepArena()] {
            let wedges = projector.project(arena).wedges
            for pair in zip(wedges, wedges.dropFirst()) {
                #expect(pair.0.ring < pair.1.ring
                        || (pair.0.ring == pair.1.ring && pair.0.startAngle <= pair.1.startAngle))
                #expect(pair.1.startAngle >= 0 && pair.1.endAngle <= fullCircle + 1e-12)
            }
        }
    }

    @Test("layout stops at the ring cap however deep the tree goes")
    func ringDepth() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        var parent = root
        for level in 0..<12 {
            parent = commit(&arena, parent: parent, dirs: [DirSpec("level\(level)")]).dirSlots.lowerBound
        }
        commit(&arena, parent: parent, files: [FileSpec("leaf", blocks: 1000)])
        unwind(&arena, from: parent)
        arena.finishWalk()

        let layout = projector.project(arena)
        // A single child per level, so every ring holds exactly one wedge and the
        // only thing that can stop the descent is the cap.
        #expect(layout.wedges.map(\.ring) == Array(0...SunburstProjector.deepestRing))
        #expect(layout.wedges.count == Int(SunburstProjector.deepestRing) + 1)
        #expect(layout.wedges.allSatisfy { $0.ring < SunburstGeometry.maximumRings })
    }

    @Test("the wedge ceiling drops whole outer rings rather than truncating one")
    func wedgeCeiling() {
        let arena = broadAndDeepArena()
        let layout = projector.project(arena)

        #expect(layout.wedges.count <= SunburstGeometry.maximumWedges)

        var perRing: [UInt8: Int] = [:]
        for wedge in layout.wedges { perRing[wedge.ring, default: 0] += 1 }
        let deepest = perRing.keys.max() ?? 0

        // Depth was not the limit — the tree has more rings inside `maximumRings`
        // and the projector still had budget-free rings available.
        #expect(deepest < SunburstProjector.deepestRing)
        // Every ring that survived is complete: 500 top-level directories, then a
        // kept child plus one aggregate under each of them.
        #expect(perRing[0] == 500)
        for ring in 1...deepest { #expect(perRing[ring] == 1000) }
        // One more whole ring would have crossed the ceiling.
        #expect(layout.wedges.count + 1000 > SunburstGeometry.maximumWedges)
    }
}

/// 500 top-level directories, each the head of a six-deep chain carrying three
/// sub-pixel files per level. Broad enough that every ring is near-full and deep
/// enough that the ring budget, not the depth cap, is what stops the layout.
private func broadAndDeepArena() -> Arena {
    var arena = Arena(reservingCapacityForEntries: 20_000)
    let root = arena.createRoot(name: "Test")
    let tops = commit(&arena, parent: root, dirs: (0..<500).map { DirSpec("top\($0)") }).dirSlots
    for top in tops {
        var parent = top
        for level in 0..<6 {
            parent = commit(&arena, parent: parent,
                            files: (0..<3).map { FileSpec("t\(level)_\($0)", blocks: 1) },
                            dirs: [DirSpec("chain\(level)")]).dirSlots.lowerBound
        }
        // The payload at the bottom is what keeps each chain link holding nearly all
        // of its parent's arc, so the chain stays visible ring after ring.
        commit(&arena, parent: parent, files: [FileSpec("payload", blocks: 1_000_000),
                                               FileSpec("t6_0", blocks: 1),
                                               FileSpec("t6_1", blocks: 1),
                                               FileSpec("t6_2", blocks: 1)])
        unwind(&arena, from: parent)
    }
    arena.finishWalk()
    return arena
}

// MARK: - Colour, honesty, safety

@Suite("Sunburst projection — colour, honesty and safety")
struct ProjectionSemanticsTests {

    @Test("every wedge carries its top-level ancestor's index as its colour seed")
    func colorSeedInheritance() {
        let arena = nestedArena()
        let layout = projector.project(arena)

        let ringOne = layout.wedges.filter { $0.ring == 0 }
        #expect(ringOne.map(\.colorSeed) == [0, 1, 2])

        var seedForTop: [NodeRef: UInt16] = [:]
        for wedge in ringOne { seedForTop[wedge.node] = wedge.colorSeed }

        for wedge in layout.wedges {
            let top = topLevelAncestor(of: wedge.node, in: arena, focus: 0)
            #expect(wedge.colorSeed == seedForTop[top])
        }
    }

    @Test("colour seeds survive re-projection, so the chart does not reshuffle")
    func colorSeedStability() {
        let arena = nestedArena()
        let first = projector.project(arena, generation: 1)
        let second = projector.project(arena, generation: 99)
        #expect(first.wedges.map { [$0.node.rawValue: $0.colorSeed] }
                == second.wedges.map { [$0.node.rawValue: $0.colorSeed] })
    }

    @Test("a directory still being walked is marked, not quietly drawn as finished")
    func stillScanning() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        let kids = commit(&arena, parent: root, dirs: [DirSpec("done"), DirSpec("running")]).dirSlots
        let done = kids.lowerBound, running = kids.lowerBound + 1

        commit(&arena, parent: done, files: [FileSpec("f", blocks: 600)])
        unwind(&arena, from: done)
        // `running` has reported the children it has read so far but has not
        // completed: this is exactly the state a progress tick projects from.
        commit(&arena, parent: running, files: [FileSpec("g", blocks: 400)])

        let layout = projector.project(arena, isComplete: false)
        let kinds = Dictionary(uniqueKeysWithValues: layout.wedges.map { ($0.name, $0.kind) })
        #expect(kinds["done"] == .real)
        #expect(kinds["running"] == .stillScanning)
        #expect(layout.isComplete == false)
    }

    @Test("an unreadable directory is never drawn as still-scanning")
    func deniedDirectory() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("payload", blocks: 100)],
               dirs: [DirSpec("locked", flags: [.denied])])
        unwind(&arena, from: root)
        arena.finishWalk()

        // A denied directory must NOT carry `.incomplete`. Nothing ever reports
        // back for it, so the flag would stick for the life of the arena and any
        // consumer reading it — inspector, treemap, a future reclaim pass — would
        // be told an unreadable folder is still being scanned. `.denied` already
        // carries the real meaning.
        #expect(arena.dirs[1].flags.contains(.denied))
        #expect(!arena.dirs[1].flags.contains(.incomplete))
        let layout = projector.project(arena)
        #expect(layout.wedges.count == 1)
        #expect(layout.wedges[0].name == "payload")
    }

    @Test("hard-link duplicates claim no arc, so a ring cannot over-fill")
    func hardlinkDuplicates() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("original", blocks: 100),
                                             FileSpec("linked", blocks: 100,
                                                      flags: [.hardlinkDuplicate])])
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = projector.project(arena)
        #expect(layout.wedges.count == 1)
        #expect(layout.wedges[0].name == "original")
        #expect(abs(layout.wedges[0].sweep - fullCircle) < 1e-12)
        #expect(layout.totalPhysicalBytes == 100 * 4096)
    }

    @Test("a zero-byte subtree yields no wedges rather than NaN")
    func zeroSize() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("empty1", blocks: 0, logical: 0),
                                             FileSpec("empty2", blocks: 0, logical: 0)],
               dirs: [DirSpec("hollow")])
        unwind(&arena, from: root)
        arena.finishWalk()

        for basis in SizeBasis.allCases {
            let layout = projector.project(arena, basis: basis)
            #expect(layout.wedges.isEmpty)
            #expect(layout.totalPhysicalBytes == 0)
            #expect(layout.totalLogicalBytes == 0)
        }
    }

    @Test("zero-byte siblings do not create a degenerate wedge next to a real one")
    func zeroSizeAlongsideReal() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        var files = [FileSpec("real", blocks: 100)]
        for i in 0..<5 { files.append(FileSpec("empty\(i)", blocks: 0, logical: 0)) }
        commit(&arena, parent: root, files: files)
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = projector.project(arena)
        #expect(layout.wedges.count == 1)
        #expect(layout.wedges[0].startAngle == 0)
        #expect(layout.wedges[0].endAngle == fullCircle)
        #expect(layout.wedges.allSatisfy { $0.startAngle.isFinite && $0.endAngle.isFinite })
    }

    @Test("an empty focus and a stale focus both degrade instead of trapping")
    func emptyAndInvalidFocus() {
        var arena = Arena()
        _ = arena.createRoot(name: "Test")

        let empty = projector.project(arena)
        #expect(empty.wedges.isEmpty)
        #expect(empty.breadcrumb.map(\.name) == ["Test"])
        #expect(empty.focusPath == "/Volumes/Test")

        #expect(projector.project(arena, focus: .invalid).wedges.isEmpty)
        #expect(projector.project(arena, focus: .directory(999)).wedges.isEmpty)
        #expect(projector.project(arena, focus: .file(0)).wedges.isEmpty)
        #expect(projector.project(Arena(), focus: .directory(0)).wedges.isEmpty)
    }

    @Test("breadcrumb runs root to focus, and a zoomed focus fills the circle")
    func breadcrumbAndZoom() throws {
        let arena = nestedArena()
        // gamma is the largest top-level directory, so it is wedge zero.
        let top = projector.project(arena).wedges[0]
        #expect(top.name == "gamma")

        let zoomed = projector.project(arena, focus: top.node)
        #expect(zoomed.focus == top.node)
        #expect(zoomed.breadcrumb.map(\.name) == ["Test", "gamma"])
        #expect(zoomed.focusPath == "/Volumes/Test/gamma")
        #expect(zoomed.totalPhysicalBytes == top.physicalBytes)

        let total = zoomed.wedges.filter { $0.ring == 0 }.reduce(0.0) { $0 + $1.sweep }
        #expect(abs(total - fullCircle) < 1e-12)

        // Ring 1 is gamma's grandchildren: Test / gamma / child / grandchild.
        let deep = try #require(zoomed.wedges.first { $0.ring == 1 })
        let leaf = projector.project(arena, focus: deep.node)
        #expect(leaf.breadcrumb.count == 4)
        #expect(leaf.breadcrumb.first?.name == "Test")
        #expect(leaf.breadcrumb.last?.node == deep.node)
    }

    @Test("the same arena, focus and basis produce a byte-identical layout")
    func determinism() {
        let arena = nestedArena()
        for basis in SizeBasis.allCases {
            let a = projector.project(arena, basis: basis)
            let b = projector.project(arena, basis: basis)
            #expect(a.wedges == b.wedges)
            #expect(a.breadcrumb == b.breadcrumb)
            #expect(a.focusPath == b.focusPath)
            #expect(a.totalPhysicalBytes == b.totalPhysicalBytes)
        }
        let wide = broadAndDeepArena()
        #expect(projector.project(wide).wedges == projector.project(wide).wedges)
    }
}

// MARK: - Performance

@Suite("Sunburst projection — cost on a large arena")
struct ProjectionPerformanceTests {

    /// 200,000 files under 10,200 directories. Four of the fifty subdirectories in
    /// each branch are large enough to stay visible; the rest are sub-pixel, which
    /// is what a real volume looks like.
    private func largeArena() -> Arena {
        var arena = Arena(reservingCapacityForEntries: 220_000)
        let root = arena.createRoot(name: "Test")
        let tops = commit(&arena, parent: root,
                          dirs: (0..<200).map { DirSpec("branch\($0)") }).dirSlots
        for top in tops {
            let mids = commit(&arena, parent: top,
                              dirs: (0..<50).map { DirSpec("sub\($0)") }).dirSlots
            for (index, mid) in mids.enumerated() {
                let blocks: UInt32 = index < 4 ? 1000 : 1
                commit(&arena, parent: mid,
                       files: (0..<20).map { FileSpec("f\($0)", blocks: blocks) })
                unwind(&arena, from: mid)
            }
        }
        arena.finishWalk()
        return arena
    }

    @Test("a 200k-node arena projects in a fraction of a progress tick")
    func largeArenaProjection() {
        let arena = largeArena()
        #expect(arena.totalEntries >= 200_000)

        let clock = ContinuousClock()
        var wedgeCount = 0
        _ = projector.project(arena)          // warm the caches; we are timing the walk

        var best = Duration.seconds(60)
        for _ in 0..<5 {
            let elapsed = clock.measure { wedgeCount = projector.project(arena).wedges.count }
            best = min(best, elapsed)
        }

        print("""
        projection: \(arena.totalEntries) nodes -> \(wedgeCount) wedges \
        in \(String(format: "%.2f", milliseconds(best))) ms
        """)

        // The projection descends breadth-first and stops: it touches roughly 26k of
        // the 210k nodes, because everything under a culled wedge is never visited.
        #expect(wedgeCount > 1000)
        #expect(best < .milliseconds(100))
    }
}

