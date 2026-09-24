import Testing
import Foundation
import LoupeCore
@testable import LoupeTree

// MARK: - Fixtures
//
// Every arena below is built through the public building API in the same order
// the walker uses it — stage a directory's children into one shared name buffer,
// commit them, unwind completions — so a fixture cannot accidentally construct a
// tree the real scan could never produce. The helpers mirror `ProjectionTests`,
// which keeps its own copies file-private.

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

private let layouter = TreemapLayouter(rootPath: "/Volumes/Test")
private let projector = SunburstProjector(rootPath: "/Volumes/Test")

private extension TreemapLayouter {
    /// Every test lays out with the same clock and generation unless it is
    /// specifically about those fields.
    func layout(_ arena: Arena, focus: NodeRef = .directory(0),
                basis: SizeBasis = .physical, generation: UInt64 = 1,
                isComplete: Bool = true) -> TreemapLayout {
        layout(arena: arena, focus: focus, basis: basis, generation: generation,
               scannedAt: Date(timeIntervalSince1970: 1_700_000_000), isComplete: isComplete)
    }
}

private extension SunburstProjector {
    func project(_ arena: Arena, focus: NodeRef = .directory(0),
                 basis: SizeBasis = .physical) -> SunburstLayout {
        project(arena: arena, focus: focus, basis: basis, generation: 1,
                scannedAt: Date(timeIntervalSince1970: 1_700_000_000), isComplete: true)
    }
}

private func parentDirectory(of ref: NodeRef, in arena: Arena) -> UInt32? {
    let parent = ref.isDirectory ? arena.dirs[Int(ref.slot)].parentDir
                                 : arena.files[Int(ref.slot)].parentDir
    return parent >= 0 ? UInt32(parent) : nil
}

private func isAggregate(_ kind: WedgeKind) -> Bool {
    if case .aggregated = kind { return true }
    return false
}

private func aspectRatio(_ rect: TreemapRect) -> Double {
    let low = min(rect.width, rect.height), high = max(rect.width, rect.height)
    return low > 0 ? high / low : .infinity
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

/// The naive treemap this engine exists to beat: one parallel cut per child,
/// every rectangle the full height of its parent.
private func sliceAndDice(areas: [Double], into rect: TreemapRect) -> [TreemapRect] {
    let total = areas.reduce(0, +)
    guard total > 0 else { return [] }
    var out: [TreemapRect] = []
    var cursor = rect.x
    for area in areas {
        let width = rect.width * area / total
        out.append(TreemapRect(x: cursor, y: rect.y, width: width, height: rect.height))
        cursor += width
    }
    return out
}

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

/// A heavy-tailed top level: sizes falling off as 1/n, a handful of large
/// directories and a long tail of small ones. That is the shape a home directory
/// actually has, and the shape slice-and-dice handles worst.
private func realisticArena() -> Arena {
    var arena = Arena(reservingCapacityForEntries: 200)
    let root = arena.createRoot(name: "Test")
    let files = (0..<80).map {
        FileSpec(String(format: "item%03d", $0), blocks: UInt32(2_000_000 / ($0 + 1)))
    }
    commit(&arena, parent: root, files: files)
    unwind(&arena, from: root)
    arena.finishWalk()
    return arena
}

/// One child per level, twelve levels down. The only thing that can stop the
/// descent is the depth cap.
private func deepChainArena() -> Arena {
    var arena = Arena()
    let root = arena.createRoot(name: "Test")
    var parent = root
    for level in 0..<12 {
        parent = commit(&arena, parent: parent, dirs: [DirSpec("level\(level)")]).dirSlots.lowerBound
    }
    commit(&arena, parent: parent, files: [FileSpec("leaf", blocks: 1000)])
    unwind(&arena, from: parent)
    arena.finishWalk()
    return arena
}

/// `children` equal-sized files under the root. At 8000 each is 1/8000 of the
/// container — just above `minimumAreaFraction`, so the area cull keeps every
/// one of them and only the per-parent ceiling can bound the level.
private func wideArena(children: Int) -> Arena {
    var arena = Arena(reservingCapacityForEntries: children + 16)
    let root = arena.createRoot(name: "Test")
    commit(&arena, parent: root,
           files: (0..<children).map { FileSpec(String(format: "f%05d", $0), blocks: 4) })
    unwind(&arena, from: root)
    arena.finishWalk()
    return arena
}

/// 1500 equal top-level directories with three equal children each. Depth 0 fits
/// the tile budget; depth 1 is 4500 tiles and cannot.
private func broadLevelArena() -> Arena {
    var arena = Arena(reservingCapacityForEntries: 20_000)
    let root = arena.createRoot(name: "Test")
    let tops = commit(&arena, parent: root,
                      dirs: (0..<1900).map { DirSpec("top\($0)") }).dirSlots
    for top in tops {
        let subs = commit(&arena, parent: top, dirs: (0..<4).map { DirSpec("s\($0)") }).dirSlots
        for sub in subs {
            commit(&arena, parent: sub, files: [FileSpec("f", blocks: 100)])
            unwind(&arena, from: sub)
        }
    }
    arena.finishWalk()
    return arena
}

/// 200,000 files under 10,201 directories. Four of the fifty subdirectories in
/// each branch are large enough to stay visible; the rest are sub-pixel, which is
/// what a real volume looks like.
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

// MARK: - Geometry

@Suite("Treemap layout — geometry")
struct TreemapGeometryTests {

    @Test("every tile sits inside the unit container with a real, positive area")
    func insideTheContainer() {
        for arena in [flatArena(), nestedArena(), realisticArena(), broadLevelArena()] {
            for tile in layouter.layout(arena).tiles {
                let frame = tile.frame
                #expect(frame.x.isFinite && frame.y.isFinite)
                #expect(frame.width.isFinite && frame.height.isFinite)
                #expect(frame.width > 0 && frame.height > 0)
                #expect(frame.area > 0)
                #expect(frame.x >= -1e-12 && frame.y >= -1e-12)
                #expect(frame.maxX <= 1 + 1e-12 && frame.maxY <= 1 + 1e-12)
            }
        }
    }

    @Test("a child's rectangle lies inside its parent's, one depth further out")
    func childrenNestInsideParents() {
        let arena = nestedArena()
        let layout = layouter.layout(arena)
        #expect(layout.tiles.contains { $0.depth >= 2 })

        var byNode: [NodeRef: TreemapTile] = [:]
        for tile in layout.tiles { byNode[tile.node] = tile }

        for tile in layout.tiles {
            guard let parentSlot = parentDirectory(of: tile.node, in: arena),
                  let parent = byNode[.directory(parentSlot)] else {
                #expect(tile.depth == 0)
                continue
            }
            #expect(tile.depth == parent.depth + 1)
            #expect(tile.frame.x >= parent.frame.x - 1e-12)
            #expect(tile.frame.y >= parent.frame.y - 1e-12)
            #expect(tile.frame.maxX <= parent.frame.maxX + 1e-12)
            #expect(tile.frame.maxY <= parent.frame.maxY + 1e-12)
            // Nesting is only meaningful if the child is genuinely smaller.
            #expect(tile.frame.area <= parent.frame.area + 1e-12)
        }
    }

    @Test("no two tiles at the same depth overlap, and depth 0 tiles the container")
    func siblingsDoNotOverlap() {
        // Containment is not enough on its own: two siblings can both sit inside
        // their parent and still sit on top of each other. Sampling a grid is the
        // only check that actually catches a strip whose thickness was computed
        // against the wrong free rectangle.
        for arena in [nestedArena(), realisticArena(), largeArenaSmallSample()] {
            let layout = layouter.layout(arena)
            let depths = Set(layout.tiles.map(\.depth)).sorted()
            #expect(!depths.isEmpty)
            let n = 160

            for depth in depths {
                var hits = [Int](repeating: 0, count: n * n)
                for tile in layout.tiles where tile.depth == depth {
                    let frame = tile.frame
                    let i0 = max(0, Int((frame.x * Double(n)).rounded(.down)) - 1)
                    let i1 = min(n - 1, Int((frame.maxX * Double(n)).rounded(.up)) + 1)
                    let j0 = max(0, Int((frame.y * Double(n)).rounded(.down)) - 1)
                    let j1 = min(n - 1, Int((frame.maxY * Double(n)).rounded(.up)) + 1)
                    guard i0 <= i1, j0 <= j1 else { continue }
                    for j in j0...j1 {
                        let py = (Double(j) + 0.5) / Double(n)
                        for i in i0...i1 {
                            let px = (Double(i) + 0.5) / Double(n)
                            if frame.contains(x: px, y: py) { hits[j * n + i] += 1 }
                        }
                    }
                }
                #expect(hits.allSatisfy { $0 <= 1 })
                // Depth 0 divides the whole container: kept children plus the one
                // aggregate account for every byte, so they account for every point.
                if depth == 0 { #expect(hits.allSatisfy { $0 == 1 }) }
            }
        }
    }

    @Test("a tile's area is its share of its parent's bytes")
    func areasAreProportional() {
        let flat = layouter.layout(flatArena())
        #expect(flat.tiles.count == 3)
        #expect(abs(flat.tiles[0].frame.area - 0.5) < 1e-12)
        #expect(abs(flat.tiles[1].frame.area - 0.3) < 1e-12)
        #expect(abs(flat.tiles[2].frame.area - 0.2) < 1e-12)
        #expect(abs(flat.tiles.reduce(0.0) { $0 + $1.frame.area } - 1.0) < 1e-12)

        // And with eighty siblings and a heavy tail, where the strips stack up and
        // rounding has somewhere to hide.
        let arena = realisticArena()
        let layout = layouter.layout(arena)
        let total = Double(layout.totalPhysicalBytes)
        for tile in layout.tiles where tile.depth == 0 {
            #expect(abs(tile.frame.area - Double(tile.physicalBytes) / total) < 1e-9)
        }
        #expect(abs(layout.tiles.reduce(0.0) { $0 + $1.frame.area } - 1.0) < 1e-9)
    }

    @Test("squarified aspect ratios beat slice-and-dice on a realistic distribution")
    func beatsSliceAndDice() {
        let layout = layouter.layout(realisticArena())
        let top = layout.tiles.filter { $0.depth == 0 }
        #expect(top.count == 80)

        let squarified = top.map { aspectRatio($0.frame) }
        let naive = sliceAndDice(areas: top.map(\.frame.area), into: TreemapLayouter.container)
            .map(aspectRatio)

        let squarifiedMean = squarified.reduce(0, +) / Double(squarified.count)
        let naiveMean = naive.reduce(0, +) / Double(naive.count)
        let squarifiedWorst = squarified.max() ?? .infinity
        let naiveWorst = naive.max() ?? .infinity

        print("""
        aspect ratio over \(top.count) tiles — \
        squarified mean \(String(format: "%.2f", squarifiedMean)), \
        worst \(String(format: "%.2f", squarifiedWorst)); \
        slice-and-dice mean \(String(format: "%.2f", naiveMean)), \
        worst \(String(format: "%.2f", naiveWorst)) \
        (mean \(String(format: "%.0f", naiveMean / squarifiedMean))x better, \
        worst \(String(format: "%.0f", naiveWorst / squarifiedWorst))x better)
        """)

        // A tile you can read and click is one that is not far off square.
        #expect(squarifiedWorst < 6)
        #expect(squarifiedMean < 3)
        // Slice-and-dice on the same bytes: hundred-to-one slivers.
        #expect(naiveWorst > 100)
        #expect(squarifiedMean * 10 < naiveMean)
        #expect(squarifiedWorst * 10 < naiveWorst)
    }
}

/// A trimmed `largeArena` — same shape, small enough for a grid sweep.
private func largeArenaSmallSample() -> Arena {
    var arena = Arena(reservingCapacityForEntries: 4000)
    let root = arena.createRoot(name: "Test")
    let tops = commit(&arena, parent: root, dirs: (0..<8).map { DirSpec("branch\($0)") }).dirSlots
    for top in tops {
        let mids = commit(&arena, parent: top, dirs: (0..<12).map { DirSpec("sub\($0)") }).dirSlots
        for (index, mid) in mids.enumerated() {
            let blocks: UInt32 = index < 4 ? 1000 : 1
            commit(&arena, parent: mid, files: (0..<6).map { FileSpec("f\($0)", blocks: blocks) })
            unwind(&arena, from: mid)
        }
    }
    arena.finishWalk()
    return arena
}

// MARK: - Depth and ordering

@Suite("Treemap layout — depth and ordering")
struct TreemapDepthTests {

    @Test("depth 0 is the focus's direct children, and the focus is never a tile")
    func depthZeroIsDirectChildren() {
        // The whole point of the constant being called `depth` and not
        // `levelsFromRoot`. An off-by-one here is invisible in isolation — the
        // treemap still draws — and only shows up as the two views disagreeing
        // about what the user selected.
        let arena = nestedArena()
        let layout = layouter.layout(arena)

        #expect(!layout.tiles.contains { $0.node == NodeRef.directory(0) })
        for tile in layout.tiles where tile.depth == 0 {
            #expect(parentDirectory(of: tile.node, in: arena) == 0)
        }
        // alpha, beta and gamma are the root's only children, all big enough to
        // survive the cull, so depth 0 is exactly those three.
        #expect(Set(layout.tiles.filter { $0.depth == 0 }.map(\.name))
                == ["alpha", "beta", "gamma"])

        // A zoomed focus renumbers from its own children, not from the root.
        let gamma = layout.tiles.first { $0.name == "gamma" }!
        let zoomed = layouter.layout(arena, focus: gamma.node)
        #expect(!zoomed.tiles.contains { $0.node == gamma.node })
        for tile in zoomed.tiles where tile.depth == 0 {
            #expect(parentDirectory(of: tile.node, in: arena) == gamma.node.slot)
        }
        #expect(Set(zoomed.tiles.filter { $0.depth == 0 }.map(\.name)) == ["loose", "one", "two"])
    }

    @Test("depth mirrors Wedge.ring node for node")
    func depthMirrorsRing() {
        // Built independently and compared: the treemap and the sunburst must
        // agree about what level a node is on, or navigation, selection and the
        // breadcrumb all quietly desynchronise when the user toggles views.
        for arena in [nestedArena(), largeArenaSmallSample()] {
            for focus in [NodeRef.directory(0), NodeRef.directory(1)] {
                let tiles = layouter.layout(arena, focus: focus).tiles
                let wedges = projector.project(arena, focus: focus).wedges

                var ringForNode: [NodeRef: UInt8] = [:]
                for wedge in wedges where !isAggregate(wedge.kind) {
                    ringForNode[wedge.node] = wedge.ring
                }
                var compared = 0
                for tile in tiles where !isAggregate(tile.kind) {
                    guard let ring = ringForNode[tile.node] else { continue }
                    #expect(tile.depth == ring)
                    compared += 1
                }
                #expect(compared > 3)
            }
        }
    }

    @Test("tiles come out outermost-first, so a renderer paints parents underneath")
    func outermostFirst() {
        for arena in [nestedArena(), realisticArena(), largeArenaSmallSample()] {
            let tiles = layouter.layout(arena).tiles
            for pair in zip(tiles, tiles.dropFirst()) {
                #expect(pair.0.depth <= pair.1.depth)
            }
            // Sliceable into whole levels without sorting, the way `SunburstIndex`
            // slices rings.
            let depths = tiles.map(\.depth)
            #expect(depths == depths.sorted())
        }
    }

    @Test("siblings are laid out largest first, and ties break on name")
    func siblingOrdering() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("zebra", blocks: 10),
                                             FileSpec("apple", blocks: 10),
                                             FileSpec("mango", blocks: 10),
                                             FileSpec("whale", blocks: 40)])
        unwind(&arena, from: root)
        arena.finishWalk()

        // Size first, then the stable secondary key. Without the name tie-break the
        // three equal files come back in whatever order introsort happened to
        // leave, and with them a different set of colours every tick.
        #expect(layouter.layout(arena).tiles.map(\.name) == ["whale", "apple", "mango", "zebra"])

        // Within one parent, at any depth, bytes never increase down the array.
        let nested = layouter.layout(largeArenaSmallSample()).tiles
        var previousForParent: [UInt32: UInt64] = [:]
        let arenaRef = largeArenaSmallSample()
        for tile in nested {
            guard let parent = parentDirectory(of: tile.node, in: arenaRef) else { continue }
            if let previous = previousForParent[parent] { #expect(tile.physicalBytes <= previous) }
            previousForParent[parent] = tile.physicalBytes
        }
    }

    @Test("the descent stops at the depth cap however deep the tree goes")
    func depthCap() {
        // `maximumDepth` is a count of levels, exactly as `maximumRings` is a count
        // of rings: 4 means depths 0...3. Pinned here because the constant's name
        // does not say so and the contract does not either.
        #expect(TreemapLayouter.deepestDepth == TreemapGeometry.maximumDepth - 1)

        let layout = layouter.layout(deepChainArena())
        // One child per level, so every level holds exactly one tile and the only
        // thing that can stop the descent is the cap.
        #expect(layout.tiles.map(\.depth) == Array(0...TreemapLayouter.deepestDepth))
        #expect(layout.tiles.count == Int(TreemapLayouter.deepestDepth) + 1)
        #expect(layout.tiles.allSatisfy { $0.depth < TreemapGeometry.maximumDepth })
    }
}

// MARK: - Culling and bounds

@Suite("Treemap layout — bounding the output")
struct TreemapBoundsTests {

    @Test("sub-threshold siblings collapse into one aggregated tile")
    func aggregation() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        var files = [FileSpec("payload", blocks: 1_000_000)]
        for i in 0..<40 { files.append(FileSpec("crumb\(i)", blocks: 1)) }
        commit(&arena, parent: root, files: files)
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = layouter.layout(arena)
        // Forty invisible rectangles would cost forty draw calls and forty
        // hit-test entries for something a tenth of a point across.
        #expect(layout.tiles.count == 2)
        #expect(layout.tiles[0].kind == .real)
        #expect(layout.tiles[0].name == "payload")
        #expect(layout.tiles[1].kind == .aggregated(count: 40))
        #expect(layout.tiles[1].physicalBytes == 40 * 4096)
        #expect(layout.tiles[1].itemCount == 40)
        #expect(layout.tiles[1].name == "40 smaller items")
        // The aggregate takes the leftover exactly: nothing is dropped on the floor.
        #expect(abs(layout.tiles.reduce(0.0) { $0 + $1.frame.area } - 1.0) < 1e-12)
        // And it borrows a real sibling's ref, so identity stays unique.
        #expect(Set(layout.tiles.map(\.id)).count == layout.tiles.count)
    }

    @Test("no real tile is smaller than the minimum area, aggregates aside")
    func minimumArea() {
        for arena in [flatArena(), nestedArena(), realisticArena(), largeArenaSmallSample()] {
            for tile in layouter.layout(arena).tiles {
                // The aggregate is allowed to be smaller than the threshold: it is
                // the one tile whose job is to stand in for things that are.
                if isAggregate(tile.kind) { continue }
                #expect(tile.frame.area >= TreemapGeometry.minimumAreaFraction * (1 - 1e-9))
            }
        }
    }

    @Test("the tile ceiling drops whole levels rather than truncating one")
    func tileCeilingDropsLevels() {
        let arena = broadLevelArena()
        let layout = layouter.layout(arena)

        #expect(layout.tiles.count <= TreemapGeometry.maximumTiles)
        // Depth 0 is complete: all 1900 top-level directories.
        #expect(layout.tiles.count == 1900)
        #expect(layout.tiles.allSatisfy { $0.depth == 0 })

        // Depth 1 was neither empty nor culled — it was 7600 tiles, and 9500 would
        // have crossed the ceiling, so the whole level went. A partial level would
        // leave bare parent showing through where children should be, with nothing
        // on screen to distinguish it from an empty directory.
        let oneTop = layouter.layout(arena, focus: layout.tiles[0].node)
        #expect(oneTop.tiles.filter { $0.depth == 0 }.count == 4)
        #expect(layout.tiles.count + 1900 * 4 > TreemapGeometry.maximumTiles)
    }

    @Test("the area cull and the tile ceiling cannot disagree")
    func cullAndCeilingAreConsistent() {
        // The invariant that makes the whole-level backstop safe. If the ceiling
        // ever drops below what the area cull will admit in one level, a wide
        // directory builds a depth 0 that the backstop then discards, and the
        // user gets an empty treemap for a full disk. This shipped once.
        #expect(TreemapGeometry.maximumTiles > TreemapGeometry.maximumTilesPerLevel)
    }

    @Test("a directory wide enough to fill the cull still renders every tile")
    func wideDirectoryIsNotThrownAway() {
        // 8000 equal children each take 1/8000 of the container, comfortably
        // above the area threshold, so all of them survive the cull — and the
        // ceiling must be high enough to let the level through intact.
        let arena = wideArena(children: 8000)
        let layout = layouter.layout(arena)

        #expect(layout.tiles.count == 8000)
        #expect(layout.tiles.allSatisfy { $0.depth == 0 })
        #expect(!layout.tiles.contains { isAggregate($0.kind) })
        // Both ends of the order are present: nothing was silently shed.
        #expect(layout.tiles.contains { $0.name == "f00000" })
        #expect(layout.tiles.contains { $0.name == "f07999" })
        // Still tiles the container exactly, with unique identities.
        #expect(abs(layout.tiles.reduce(0.0) { $0 + $1.frame.area } - 1.0) < 1e-9)
        #expect(Set(layout.tiles.map(\.id)).count == layout.tiles.count)
    }

    @Test("tile identity is unique, so an aggregate cannot collide with a sibling")
    func uniqueIdentity() {
        for arena in [nestedArena(), realisticArena(), largeArenaSmallSample()] {
            let tiles = layouter.layout(arena).tiles
            #expect(Set(tiles.map(\.id)).count == tiles.count)
        }
    }
}

// MARK: - Colour, honesty, safety

@Suite("Treemap layout — colour, honesty and safety")
struct TreemapSemanticsTests {

    @Test("colour seeds agree with the sunburst node for node")
    func colorSeedMatchesSunburst() {
        // Toggling between the two views must not recolour the machine. Both are
        // built here and compared rather than asserted against a hard-coded table,
        // because the thing that has to hold is agreement, not any particular
        // numbering.
        for arena in [nestedArena(), realisticArena(), largeArenaSmallSample()] {
            let tiles = layouter.layout(arena).tiles
            let wedges = projector.project(arena).wedges

            var seedForNode: [NodeRef: UInt16] = [:]
            for wedge in wedges where !isAggregate(wedge.kind) { seedForNode[wedge.node] = wedge.colorSeed }

            var compared = 0
            for tile in tiles where !isAggregate(tile.kind) {
                guard let seed = seedForNode[tile.node] else { continue }
                #expect(tile.colorSeed == seed)
                compared += 1
            }
            #expect(compared > 3)
        }

        // Inheritance: everything deeper carries its top-level ancestor's index.
        let arena = nestedArena()
        let layout = layouter.layout(arena)
        var seedForTop: [NodeRef: UInt16] = [:]
        for tile in layout.tiles where tile.depth == 0 { seedForTop[tile.node] = tile.colorSeed }
        #expect(layout.tiles.filter { $0.depth == 0 }.map(\.colorSeed) == [0, 1, 2])

        for tile in layout.tiles {
            var current = tile.node
            while let parent = parentDirectory(of: current, in: arena), parent != 0 {
                current = .directory(parent)
            }
            #expect(tile.colorSeed == seedForTop[current])
        }
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
        // completed: this is exactly the state a progress tick lays out from.
        commit(&arena, parent: running, files: [FileSpec("g", blocks: 400)])

        let layout = layouter.layout(arena, isComplete: false)
        let kinds = Dictionary(uniqueKeysWithValues:
            layout.tiles.filter { $0.depth == 0 }.map { ($0.name, $0.kind) })
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

        // A denied directory carries no bytes and no `.incomplete` flag: it is not
        // in progress, it is unreadable, and `.denied` already says so.
        let layout = layouter.layout(arena)
        #expect(layout.tiles.count == 1)
        #expect(layout.tiles[0].name == "payload")
        #expect(layout.tiles[0].kind == .real)
        #expect(!layout.tiles.contains { $0.kind == .stillScanning })
    }

    @Test("hard-link duplicates claim no area, so a parent cannot over-fill")
    func hardlinkDuplicates() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("original", blocks: 100),
                                             FileSpec("linked", blocks: 100,
                                                      flags: [.hardlinkDuplicate])])
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = layouter.layout(arena)
        #expect(layout.tiles.count == 1)
        #expect(layout.tiles[0].name == "original")
        #expect(abs(layout.tiles[0].frame.area - 1.0) < 1e-12)
        #expect(layout.totalPhysicalBytes == 100 * 4096)
    }

    @Test("a zero-byte subtree yields no tiles rather than NaN")
    func zeroSize() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("empty1", blocks: 0, logical: 0),
                                             FileSpec("empty2", blocks: 0, logical: 0)],
               dirs: [DirSpec("hollow")])
        unwind(&arena, from: root)
        arena.finishWalk()

        for basis in SizeBasis.allCases {
            let layout = layouter.layout(arena, basis: basis)
            #expect(layout.tiles.isEmpty)
            #expect(layout.totalPhysicalBytes == 0)
            #expect(layout.totalLogicalBytes == 0)
        }
    }

    @Test("zero-byte siblings do not create a degenerate tile next to a real one")
    func zeroSizeAlongsideReal() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        var files = [FileSpec("real", blocks: 100)]
        for i in 0..<5 { files.append(FileSpec("empty\(i)", blocks: 0, logical: 0)) }
        commit(&arena, parent: root, files: files)
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = layouter.layout(arena)
        #expect(layout.tiles.count == 1)
        #expect(layout.tiles[0].frame == TreemapRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("an empty focus and a stale focus both degrade instead of trapping")
    func emptyAndInvalidFocus() {
        var arena = Arena()
        _ = arena.createRoot(name: "Test")

        let empty = layouter.layout(arena)
        #expect(empty.tiles.isEmpty)
        #expect(empty.breadcrumb.map(\.name) == ["Test"])
        #expect(empty.focusPath == "/Volumes/Test")

        #expect(layouter.layout(arena, focus: .invalid).tiles.isEmpty)
        #expect(layouter.layout(arena, focus: .directory(999)).tiles.isEmpty)
        #expect(layouter.layout(arena, focus: .file(0)).tiles.isEmpty)
        #expect(layouter.layout(Arena(), focus: .directory(0)).tiles.isEmpty)

        // Focusing a file is legal — the inspector does it — and yields no tiles
        // but still a path and a size.
        let flat = flatArena()
        let file = layouter.layout(flat).tiles[0].node
        let onFile = layouter.layout(flat, focus: file)
        #expect(onFile.tiles.isEmpty)
        #expect(onFile.focusPath == "/Volumes/Test/big")
        #expect(onFile.totalPhysicalBytes == 500 * 4096)
    }

    @Test("the breadcrumb and totals agree with the sunburst for the same focus")
    func agreesWithProjectorOnTheHeader() {
        let arena = nestedArena()
        for focus in [NodeRef.directory(0), .directory(1), .directory(2), .file(0)] {
            let tiles = layouter.layout(arena, focus: focus)
            let wedges = projector.project(arena, focus: focus)
            #expect(tiles.breadcrumb == wedges.breadcrumb)
            #expect(tiles.focusPath == wedges.focusPath)
            #expect(tiles.totalPhysicalBytes == wedges.totalPhysicalBytes)
            #expect(tiles.totalLogicalBytes == wedges.totalLogicalBytes)
        }
    }

    @Test("the size basis chooses which of the two true sizes drives the area")
    func basis() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        // A sparse/compressed file: one block on disk, 100 blocks apparent.
        commit(&arena, parent: root, files: [FileSpec("sparse", blocks: 1, logical: 100 * 4096),
                                             FileSpec("dense", blocks: 50)])
        unwind(&arena, from: root)
        arena.finishWalk()

        #expect(layouter.layout(arena, basis: .physical).tiles.map(\.name) == ["dense", "sparse"])
        #expect(layouter.layout(arena, basis: .logical).tiles.map(\.name) == ["sparse", "dense"])
    }

    @Test("the same arena, focus and basis produce a byte-identical layout")
    func determinism() {
        for arena in [nestedArena(), realisticArena(), largeArenaSmallSample()] {
            for basis in SizeBasis.allCases {
                let a = layouter.layout(arena, basis: basis)
                let b = layouter.layout(arena, basis: basis)
                #expect(a.tiles == b.tiles)
                #expect(a.breadcrumb == b.breadcrumb)
                #expect(a.focusPath == b.focusPath)
                #expect(a.totalPhysicalBytes == b.totalPhysicalBytes)
            }
        }
        // Including the paths where ties are broken and where the cull fires.
        let wide = wideArena(children: 8000)
        #expect(layouter.layout(wide).tiles == layouter.layout(wide).tiles)
    }
}

// MARK: - Performance

@Suite("Treemap layout — cost on a large arena")
struct TreemapPerformanceTests {

    @Test("a 200k-node arena lays out in a fraction of a progress tick")
    func largeArenaLayout() {
        let arena = largeArena()
        #expect(arena.totalEntries >= 200_000)

        let clock = ContinuousClock()
        var tileCount = 0
        _ = layouter.layout(arena)          // warm the caches; we are timing the walk

        var best = Duration.seconds(60)
        for _ in 0..<5 {
            let elapsed = clock.measure { tileCount = layouter.layout(arena).tiles.count }
            best = min(best, elapsed)
        }

        print("""
        treemap: \(arena.totalEntries) nodes -> \(tileCount) tiles \
        in \(String(format: "%.2f", milliseconds(best))) ms
        """)

        // Breadth-first and bounded: everything under a culled tile is never
        // visited, so this touches roughly 26k of the 210k nodes.
        #expect(tileCount > 1000)
        #expect(tileCount <= TreemapGeometry.maximumTiles)
        // The time budget is for optimised code; see BuildConfiguration.swift.
        if isOptimizedBuild {
            #expect(best < .milliseconds(100))
        }
    }
}
