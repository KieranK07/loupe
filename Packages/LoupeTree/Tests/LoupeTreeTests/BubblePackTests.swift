import Testing
import Foundation
import LoupeCore
@testable import LoupeTree

// MARK: - Fixtures
//
// Arenas are built through the public building API in the same order the walker
// uses it — stage a directory's children into one shared name buffer, commit
// them, unwind completions — so a fixture cannot accidentally construct a tree
// the real scan could never produce. The helpers mirror `TreemapTests`, which
// keeps its own file-private copies.

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

private let packer = BubblePacker(rootPath: "/Volumes/Test")

private extension BubblePacker {
    /// Every test packs with the same clock and generation unless it is
    /// specifically about those fields.
    func pack(_ arena: Arena, focus: NodeRef = .directory(0),
              basis: SizeBasis = .physical, generation: UInt64 = 1,
              isComplete: Bool = true) -> BubbleLayout {
        pack(arena: arena, focus: focus, basis: basis, generation: generation,
             scannedAt: Date(timeIntervalSince1970: 1_700_000_000), isComplete: isComplete)
    }
}

private func isAggregate(_ kind: WedgeKind) -> Bool {
    if case .aggregated = kind { return true }
    return false
}

// MARK: - Random trees
//
// A deterministic generator, so a failure names a seed that reproduces it
// exactly. Everything the packer can meet is in reach here: empty directories,
// zero-byte files, one child swallowing the parent, and thousands of children
// under one node.

private struct Random {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Heavy-tailed on purpose: a real directory is one or two large things and
    /// a long tail of small ones, and a uniform generator would never exercise
    /// the cull, the aggregate or the front chain's cut path.
    mutating func blocks() -> UInt32 {
        let roll = unit()
        if roll < 0.06 { return 0 }
        if roll < 0.55 { return UInt32(int(1...40)) }
        if roll < 0.90 { return UInt32(int(40...4_000)) }
        return UInt32(int(4_000...400_000))
    }
}

private struct TreeShape {
    var maximumDepth: Int
    var maximumFiles: Int
    var maximumDirectories: Int
    var nodeBudget: Int
}

private func randomArena(seed: UInt64, shape: TreeShape) -> Arena {
    var random = Random(seed: seed)
    var arena = Arena()
    let root = arena.createRoot(name: "Test")
    var spent = 0

    func build(_ parent: UInt32, depth: Int) {
        let fileCount = spent < shape.nodeBudget ? random.int(0...shape.maximumFiles) : 0
        let dirCount = depth < shape.maximumDepth && spent < shape.nodeBudget
            ? random.int(0...shape.maximumDirectories) : 0
        spent += fileCount + dirCount

        var files: [FileSpec] = []
        files.reserveCapacity(fileCount)
        for i in 0..<fileCount { files.append(FileSpec("f\(depth)_\(i)", blocks: random.blocks())) }
        var dirs: [DirSpec] = []
        dirs.reserveCapacity(dirCount)
        for i in 0..<dirCount { dirs.append(DirSpec("d\(depth)_\(i)")) }

        let result = commit(&arena, parent: parent, files: files, dirs: dirs)
        if result.completed {
            unwind(&arena, from: parent)
            return
        }
        for slot in result.dirSlots { build(slot, depth: depth + 1) }
    }

    build(root, depth: 0)
    arena.finishWalk()
    return arena
}

// MARK: - Invariant checking
//
// Both invariants are checked the way the renderer will actually use them.
// "No sibling overlap" is checked as *no two circles at the same depth overlap
// at all*, which is the stronger statement and is implied by the contract: two
// circles under different parents cannot overlap either, because their parents
// do not and each is strictly inside its own. "Nesting" is checked by finding a
// depth-(d−1) circle that wholly contains the child — the geometric parent
// recovery the hit test and the share-of-parent percentages depend on.

/// A uniform bucket grid over one depth, so the checks below are near linear
/// instead of quadratic. A quadratic check is fine on a fixture and is why a
/// randomised suite of a few hundred trees never gets written.
private struct CircleGrid {
    static let resolution = 48
    let circles: [BubbleCircle]
    private var cells: [[Int]]

    init(_ circles: [BubbleCircle]) {
        self.circles = circles
        cells = Array(repeating: [], count: Self.resolution * Self.resolution)
        for (i, circle) in circles.enumerated() {
            for cell in Self.cells(touching: circle) { cells[cell].append(i) }
        }
    }

    private static func clampCell(_ value: Double) -> Int {
        min(resolution - 1, max(0, Int(value * Double(resolution))))
    }

    private static func cells(touching circle: BubbleCircle) -> [Int] {
        let x0 = clampCell(circle.centerX - circle.radius)
        let x1 = clampCell(circle.centerX + circle.radius)
        let y0 = clampCell(circle.centerY - circle.radius)
        let y1 = clampCell(circle.centerY + circle.radius)
        var out: [Int] = []
        for row in y0...y1 {
            for column in x0...x1 { out.append(row * resolution + column) }
        }
        return out
    }

    /// Indices whose bounding box shares a cell with `circle`.
    func neighbours(of index: Int) -> Set<Int> {
        var out: Set<Int> = []
        for cell in Self.cells(touching: circles[index]) {
            for other in cells[cell] where other != index { out.insert(other) }
        }
        return out
    }

    func indices(containing x: Double, y: Double) -> [Int] {
        cells[Self.clampCell(y) * Self.resolution + Self.clampCell(x)]
    }
}

/// How far two circles are allowed to reach into one another.
///
/// The front chain forgives `CirclePack.tolerance` (1e−6) of overlap when it
/// decides whether a candidate collides, and that tolerance is expressed in
/// packing units where the largest radius is 1. Every pack is then scaled *down*
/// into its parent, by at most 0.5 at depth 0 and less below, so 1e−6 in
/// normalised container units is a strict over-estimate of what can survive. In
/// practice the sibling padding puts the real separation four thousand times
/// further out than this.
private let overlapEpsilon = 1e-6

/// How far a child is allowed to poke out of its parent.
///
/// Zero, in exact arithmetic: the enclosing radius is recomputed as the exact
/// `max(distance + radius)` and every child is then scaled by
/// `innerRadius / enclosingRadius`, so containment is an identity rather than an
/// estimate. What is left is the rounding in three multiplications and a square
/// root on values below 1, which lives well inside 1e−9.
private let nestingEpsilon = 1e-9

private func checkInvariants(_ layout: BubbleLayout, _ label: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
    let circles = layout.circles
    guard !circles.isEmpty else { return }

    var previousDepth: UInt8 = 0
    var byDepth: [[BubbleCircle]] = []
    for circle in circles {
        #expect(circle.depth >= previousDepth,
                "\(label): circles are not ordered shallowest-first",
                sourceLocation: sourceLocation)
        previousDepth = circle.depth
        #expect(circle.depth < BubbleGeometry.maximumDepth,
                "\(label): depth \(circle.depth) is past the level budget",
                sourceLocation: sourceLocation)
        #expect(circle.radius > 0 && circle.radius.isFinite,
                "\(label): degenerate radius \(circle.radius) on \(circle.name)",
                sourceLocation: sourceLocation)
        #expect(circle.centerX.isFinite && circle.centerY.isFinite,
                "\(label): non-finite centre on \(circle.name)",
                sourceLocation: sourceLocation)
        while byDepth.count <= Int(circle.depth) { byDepth.append([]) }
        byDepth[Int(circle.depth)].append(circle)
    }

    var grids: [CircleGrid] = []
    for level in byDepth { grids.append(CircleGrid(level)) }

    // Invariant 2: no two circles on a level intersect.
    for (depth, grid) in grids.enumerated() {
        for i in grid.circles.indices {
            let a = grid.circles[i]
            for j in grid.neighbours(of: i) where j > i {
                let b = grid.circles[j]
                let dx = b.centerX - a.centerX, dy = b.centerY - a.centerY
                let distance = (dx * dx + dy * dy).squareRoot()
                #expect(distance >= a.radius + b.radius - overlapEpsilon,
                        """
                        \(label): depth \(depth) circles overlap — \(a.name) r=\(a.radius) \
                        and \(b.name) r=\(b.radius) are \(distance) apart
                        """,
                        sourceLocation: sourceLocation)
            }
        }
    }

    // Invariant 1: every circle lies wholly inside a circle one level up — the
    // focus's own disc for depth 0, which the contract fixes at (0.5, 0.5) r 0.5
    // and does not emit.
    for circle in byDepth.first ?? [] {
        let dx = circle.centerX - 0.5, dy = circle.centerY - 0.5
        let reach = (dx * dx + dy * dy).squareRoot() + circle.radius
        #expect(reach <= 0.5 + nestingEpsilon,
                "\(label): \(circle.name) escapes the focus disc by \(reach - 0.5)",
                sourceLocation: sourceLocation)
    }

    for depth in 1..<max(1, byDepth.count) {
        let parents = grids[depth - 1]
        for circle in byDepth[depth] {
            var enclosed = false
            var nearestShortfall = Double.greatestFiniteMagnitude
            for index in parents.indices(containing: circle.centerX, y: circle.centerY) {
                let parent = parents.circles[index]
                let dx = circle.centerX - parent.centerX, dy = circle.centerY - parent.centerY
                let reach = (dx * dx + dy * dy).squareRoot() + circle.radius
                nearestShortfall = min(nearestShortfall, reach - parent.radius)
                if reach <= parent.radius + nestingEpsilon { enclosed = true; break }
            }
            #expect(enclosed,
                    """
                    \(label): depth \(depth) circle \(circle.name) r=\(circle.radius) has no \
                    enclosing parent; nearest missed by \(nearestShortfall)
                    """,
                    sourceLocation: sourceLocation)
        }
    }
}

// MARK: - The geometry on its own

@Suite("Circle packing geometry")
struct CirclePackGeometryTests {

    @Test("An empty, single and paired pack are the degenerate cases they look like")
    func degeneratePacks() {
        var packed: [PackedCircle] = []
        #expect(CirclePack.packSiblings(radii: [], into: &packed) == 0)
        #expect(packed.isEmpty)

        #expect(CirclePack.packSiblings(radii: [1], into: &packed) == 1)
        #expect(packed[0].x == 0)
        #expect(packed[0].y == 0)

        #expect(CirclePack.packSiblings(radii: [1, 0.5], into: &packed) == 2)
        let gap = packed[1].x - packed[0].x
        #expect(abs(gap - 1.5) < 1e-12, "two circles should come out exactly tangent")
    }

    @Test("Enclosing an empty set, a single circle and a nested pair")
    func degenerateEnclosures() {
        #expect(CirclePack.enclose([], count: 0).r == 0)

        let one = PackedCircle(x: 3, y: -2, r: 1.5)
        let single = CirclePack.enclose([one], count: 1)
        #expect(single == one)

        // A circle wholly inside another must not grow the answer at all.
        let outer = PackedCircle(x: 0, y: 0, r: 4)
        let inner = PackedCircle(x: 1, y: 1, r: 0.25)
        let both = CirclePack.enclose([outer, inner], count: 2)
        #expect(abs(both.r - 4) < 1e-9)
        #expect(abs(both.x) < 1e-9)
        #expect(abs(both.y) < 1e-9)
    }

    /// The two properties the whole layout rests on, on the geometry alone: a
    /// few hundred random radius sets, including the shapes a real directory
    /// produces and the ones it never does.
    @Test("Random sibling packs never overlap and always fit their enclosure")
    func randomPacksAreSoundAndEnclosed() {
        var random = Random(seed: 0xB0BB1E)
        var packed: [PackedCircle] = []

        for trial in 0..<400 {
            var radii: [Double] = []
            switch trial % 5 {
            case 0:
                // Heavy tail: one giant, a long drizzle.
                let count = random.int(1...200)
                radii = (0..<count).map { $0 == 0 ? 1 : max(0.02, random.unit() * 0.2) }
            case 1:
                // Everything the same size. The plateau case, where a naive
                // front chain closes a run per circle.
                radii = Array(repeating: 1, count: random.int(1...200))
            case 2:
                radii = (0..<random.int(1...200)).map { _ in max(0.05, random.unit()) }
            case 3:
                // Two decades of scale in one level.
                radii = (0..<random.int(1...120)).map { _ in
                    max(0.01, pow(10, -2 * random.unit()))
                }
            default:
                radii = (0..<random.int(1...40)).map { _ in 1 }
            }
            radii.sort(by: >)

            let placed = CirclePack.packSiblings(radii: radii, into: &packed)
            #expect(placed == radii.count, "trial \(trial): the hang guard tripped")

            for i in 0..<placed {
                for j in (i + 1)..<placed {
                    let dx = packed[j].x - packed[i].x, dy = packed[j].y - packed[i].y
                    let distance = (dx * dx + dy * dy).squareRoot()
                    #expect(distance >= packed[i].r + packed[j].r - CirclePack.tolerance,
                            "trial \(trial): circles \(i) and \(j) overlap")
                }
            }

            let enclosure = CirclePack.enclose(packed, count: placed)
            var area = 0.0
            for i in 0..<placed {
                let dx = packed[i].x - enclosure.x, dy = packed[i].y - enclosure.y
                let reach = (dx * dx + dy * dy).squareRoot() + packed[i].r
                #expect(reach <= enclosure.r + 1e-9,
                        "trial \(trial): circle \(i) escapes its own enclosure")
                area += packed[i].r * packed[i].r
            }
            // Density: the sanity check that this is a *pack* and not a
            // scattering, and the thing that stops a regression here from
            // silently shrinking every circle in every level. The floor is set
            // by the equal-circle cases, which are the greedy front chain's
            // worst input — see `equalCirclesPackWell`. On the heavy-tailed
            // distributions that dominate a real filesystem it clears 0.78.
            if placed >= 12 {
                let density = area / (enclosure.r * enclosure.r)
                #expect(density > 0.5, "trial \(trial): packing density fell to \(density)")
                if trial % 5 == 0 || trial % 5 == 3 {
                    // The heavy-tailed cases. A single circle can dominate the
                    // enclosure here — one giant plus drizzle cannot reach the
                    // asymptotic density however well the drizzle is packed —
                    // so this floor is lower than the 0.78 a broad tail hits.
                    #expect(density > 0.6,
                            "trial \(trial): a heavy tail should pack tightly, got \(density)")
                }
            }
        }
    }

    @Test("Equal circles still pack respectably")
    func equalCirclesPackWell() {
        // The greedy front chain is not an optimal packer and does worst on
        // exactly the input a naive test would use: equal circles, where every
        // anchor pair scores the same and the arrangement is decided by tie
        // breaks. Twelve equal circles fit optimally in a disc of radius 4.03
        // (density 0.74); this reaches about 0.59, where scoring from the
        // origin instead of the centroid reaches 0.42. The floor below is what
        // guards that difference — it is not a claim of optimality.
        var packed: [PackedCircle] = []
        for count in [7, 12, 19, 37, 60, 100, 200] {
            let placed = CirclePack.packSiblings(radii: Array(repeating: 1, count: count),
                                                 into: &packed)
            let enclosure = CirclePack.enclose(packed, count: placed)
            let density = Double(count) / (enclosure.r * enclosure.r)
            #expect(density > 0.5, "\(count) equal circles packed at \(density)")
        }
    }
}

// MARK: - The layout

@Suite("Bubble packing")
struct BubblePackTests {

    // MARK: Shape of the answer

    @Test("An invalid focus and an empty arena refuse rather than trap")
    func refusesNonsense() {
        let empty = Arena()
        #expect(packer.pack(empty, focus: .directory(0)).circles.isEmpty)

        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("a", blocks: 10)])
        unwind(&arena, from: root)
        arena.finishWalk()

        #expect(packer.pack(arena, focus: .invalid).circles.isEmpty)
        #expect(packer.pack(arena, focus: .directory(9999)).circles.isEmpty)
        #expect(packer.pack(arena, focus: .file(9999)).circles.isEmpty)
    }

    @Test("Focusing a file gives no circles but still gives its bytes and its path")
    func fileFocus() throws {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("big.dmg", blocks: 1000)])
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena, focus: .file(0))
        #expect(layout.circles.isEmpty)
        #expect(layout.totalPhysicalBytes == 1000 * 4096)
        #expect(layout.focusPath.hasSuffix("big.dmg"))
        #expect(layout.breadcrumb.last?.name == "big.dmg")
    }

    @Test("An empty directory produces no circles")
    func noChildren() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root)
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena)
        #expect(layout.circles.isEmpty)
        checkInvariants(layout, "empty directory")
    }

    @Test("The focus's own circle is never emitted")
    func focusIsNotACircle() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("a", blocks: 100)])
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena)
        #expect(!layout.circles.contains { $0.node == layout.focus })
    }

    @Test("Packing is deterministic: the same arena twice is the same layout")
    func deterministic() {
        let arena = randomArena(seed: 42, shape: TreeShape(maximumDepth: 3, maximumFiles: 30,
                                                           maximumDirectories: 4, nodeBudget: 600))
        #expect(packer.pack(arena) == packer.pack(arena))
    }

    // MARK: The invariants

    @Test("Both invariants hold across three hundred random trees")
    func randomTreesHoldTheInvariants() {
        let shapes = [
            TreeShape(maximumDepth: 1, maximumFiles: 40, maximumDirectories: 0, nodeBudget: 200),
            TreeShape(maximumDepth: 2, maximumFiles: 20, maximumDirectories: 5, nodeBudget: 400),
            TreeShape(maximumDepth: 4, maximumFiles: 12, maximumDirectories: 3, nodeBudget: 500),
            TreeShape(maximumDepth: 6, maximumFiles: 6, maximumDirectories: 2, nodeBudget: 400),
            TreeShape(maximumDepth: 3, maximumFiles: 60, maximumDirectories: 2, nodeBudget: 700),
            TreeShape(maximumDepth: 2, maximumFiles: 0, maximumDirectories: 8, nodeBudget: 300),
        ]

        var packedSomething = 0
        for seed in 0..<300 {
            let shape = shapes[seed % shapes.count]
            let arena = randomArena(seed: UInt64(seed) &+ 1, shape: shape)
            for basis in [SizeBasis.physical, .logical] {
                let layout = packer.pack(arena, basis: basis)
                checkInvariants(layout, "seed \(seed) basis \(basis)")
                if !layout.circles.isEmpty { packedSomething += 1 }
            }
        }
        // A suite that quietly generated three hundred empty trees would pass
        // every assertion above and prove nothing.
        #expect(packedSomething > 400, "only \(packedSomething) of 600 layouts had circles in them")
    }

    @Test("Both invariants hold when zoomed into an interior node")
    func invariantsHoldAtEveryFocus() {
        for seed in 0..<40 {
            let arena = randomArena(seed: UInt64(seed) &+ 5000,
                                    shape: TreeShape(maximumDepth: 5, maximumFiles: 15,
                                                     maximumDirectories: 3, nodeBudget: 500))
            for slot in stride(from: 0, to: arena.dirs.count, by: max(1, arena.dirs.count / 8)) {
                let layout = packer.pack(arena, focus: .directory(UInt32(slot)))
                checkInvariants(layout, "seed \(seed) focus dir#\(slot)")
            }
        }
    }

    // MARK: Adversarial shapes

    @Test("One enormous child and a thousand tiny ones")
    func oneGiantAndAThousandCrumbs() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        var files = [FileSpec("giant", blocks: 4_000_000)]
        for i in 0..<1000 { files.append(FileSpec("crumb\(i)", blocks: 1)) }
        commit(&arena, parent: root, files: files)
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena)
        checkInvariants(layout, "giant plus crumbs")
        let giant = layout.circles.first { $0.name == "giant" }
        #expect(giant != nil)
        // The crumbs are four ten-millionths of the parent each. They cannot be
        // drawn, so they must arrive as one aggregate rather than as a thousand
        // invisible marks or as nothing at all.
        let aggregates = layout.circles.filter { isAggregate($0.kind) }
        #expect(aggregates.count == 1)
        if case .aggregated(let count) = aggregates.first?.kind {
            #expect(count == 1000)
        }
    }

    @Test("All children exactly equal")
    func allEqual() {
        for count in [2, 3, 4, 7, 12, 64, 200] {
            var arena = Arena()
            let root = arena.createRoot(name: "Test")
            commit(&arena, parent: root,
                   files: (0..<count).map { FileSpec("f\($0)", blocks: 1000) })
            unwind(&arena, from: root)
            arena.finishWalk()

            let layout = packer.pack(arena)
            checkInvariants(layout, "\(count) equal children")
            #expect(layout.circles.count == count)
            // Equal bytes have to mean equal radii, or the chart is lying about
            // the one comparison it is definitely being asked to make.
            let radii = layout.circles.map(\.radius)
            let spread = (radii.max() ?? 0) - (radii.min() ?? 0)
            #expect(spread < 1e-12, "\(count) equal children came out at different sizes")
        }
    }

    @Test("A single child")
    func singleChild() throws {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("only", blocks: 500)])
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena)
        checkInvariants(layout, "single child")
        let only = try #require(layout.circles.first)
        #expect(layout.circles.count == 1)
        #expect(abs(only.centerX - 0.5) < 1e-9)
        #expect(abs(only.centerY - 0.5) < 1e-9)
        // It must not fill its parent exactly, or the parent's ring vanishes and
        // there is nothing on screen to click to get back out.
        #expect(only.radius < 0.5 - BubbleGeometry.siblingPadding + 1e-9)
        #expect(only.radius > 0.45, "one child should still be nearly the whole disc")
    }

    @Test("A child of size zero draws nothing and drags nothing down with it")
    func zeroSizedChild() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("real", blocks: 100),
                                             FileSpec("hollow", blocks: 0)])
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena)
        checkInvariants(layout, "zero-sized child")
        #expect(layout.circles.count == 1)
        #expect(layout.circles.first?.name == "real")
        // Nothing at all was culled *for size*, so there is no aggregate to
        // draw: a group standing for one empty file would be a mark about
        // nothing.
        #expect(!layout.circles.contains { isAggregate($0.kind) })
    }

    @Test("A directory of nothing but zero-sized children produces no circles")
    func allZeroSized() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: (0..<20).map { FileSpec("z\($0)", blocks: 0) })
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena)
        #expect(layout.circles.isEmpty)
    }

    // MARK: Area encodes size

    @Test("Radius goes as the square root of size, so area is the encoding")
    func areaEncodesSize() throws {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root, files: [FileSpec("a", blocks: 4000),
                                             FileSpec("b", blocks: 1000),
                                             FileSpec("c", blocks: 250)])
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena)
        let byName = Dictionary(uniqueKeysWithValues: layout.circles.map { ($0.name, $0) })
        let a = try #require(byName["a"]), b = try #require(byName["b"]), c = try #require(byName["c"])
        // Four times the bytes is twice the radius, not four times.
        #expect(abs(a.radius / b.radius - 2) < 1e-9)
        #expect(abs(b.radius / c.radius - 2) < 1e-9)
        #expect(abs(a.area / b.area - 4) < 1e-9)
    }

    @Test("Sibling order is descending by size, matching the other two engines")
    func siblingOrder() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root,
               files: (0..<12).map { FileSpec("f\($0)", blocks: UInt32(120 - $0 * 8)) })
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena)
        let depthZero = layout.circles.filter { $0.depth == 0 }
        for (a, b) in zip(depthZero, depthZero.dropFirst()) {
            #expect(a.physicalBytes >= b.physicalBytes)
        }
        // The colour key is the sibling index at depth 0, exactly as the
        // treemap mints it, so the two views cannot recolour the machine.
        for (index, circle) in depthZero.enumerated() {
            #expect(circle.colorSeed == UInt16(index))
        }
    }

    @Test("hasChildren says what is actually in the layout, not what is in the tree")
    func hasChildrenReflectsTheLayout() throws {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        let level0 = commit(&arena, parent: root,
                            files: [FileSpec("loose", blocks: 500)],
                            dirs: [DirSpec("full"), DirSpec("hollow")])
        let full = level0.dirSlots.lowerBound
        let hollow = full + 1
        commit(&arena, parent: full, files: [FileSpec("inner", blocks: 400)])
        unwind(&arena, from: full)
        commit(&arena, parent: hollow, files: [FileSpec("dust", blocks: 0)])
        unwind(&arena, from: hollow)
        arena.finishWalk()

        let layout = packer.pack(arena)
        let byName = Dictionary(uniqueKeysWithValues: layout.circles.map { ($0.name, $0) })
        #expect(try #require(byName["full"]).hasChildren)
        // A directory whose only child has no bytes contributes no circle, so
        // styling it as a container would promise a zoom that shows nothing.
        #expect(byName["hollow"] == nil || !(byName["hollow"]!.hasChildren))
        #expect(!(try #require(byName["loose"]).hasChildren))
    }

    // MARK: Budgets

    @Test("The level budget can never throw away depth zero")
    func depthZeroAlwaysSurvives() {
        // Ten thousand equal children: far more than the whole-level budget, and
        // exactly the shape that once shipped an empty treemap for a full disk.
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        commit(&arena, parent: root,
               files: (0..<10_000).map { FileSpec("f\($0)", blocks: 1000) })
        unwind(&arena, from: root)
        arena.finishWalk()

        let layout = packer.pack(arena)
        #expect(!layout.circles.isEmpty, "a full disk rendered as an empty chart")
        #expect(layout.circles.count <= BubbleGeometry.maximumCircles)
        #expect(layout.circles.allSatisfy { $0.depth == 0 })
        // The tail that did not fit is accounted for rather than dropped.
        #expect(layout.circles.contains { isAggregate($0.kind) })
        checkInvariants(layout, "ten thousand equal children")
    }

    @Test("Nothing deeper than the level budget is ever emitted")
    func depthBudget() {
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        var parent = root
        for level in 0..<10 {
            let result = commit(&arena, parent: parent,
                                files: [FileSpec("f\(level)", blocks: 100)],
                                dirs: [DirSpec("d\(level)")])
            parent = result.dirSlots.lowerBound
        }
        commit(&arena, parent: parent, files: [FileSpec("leaf", blocks: 100)])
        unwind(&arena, from: parent)
        arena.finishWalk()

        let layout = packer.pack(arena)
        #expect(layout.circles.allSatisfy { $0.depth < BubbleGeometry.maximumDepth })
        #expect(layout.circles.contains { $0.depth == BubbleGeometry.maximumDepth - 1 })
        checkInvariants(layout, "deep chain")
    }

    /// The arithmetic `BubbleGeometry.maximumCircles`'s own doc comment demands,
    /// stated as a test so nobody has to take the comment's word for it.
    ///
    /// This test was written while the constants were **inconsistent**: the
    /// radius cull could admit 6833 circles in one level against a cross-level
    /// backstop of 3000, so a wide enough directory would build a level the
    /// backstop then discarded — an empty chart for a full disk, which is the
    /// exact bug that shipped once in `TreemapGeometry`. It was written to fail
    /// the day the constants were put right, and it did.
    ///
    /// `minimumRadiusFraction` has since been raised to 0.0092, so it now
    /// asserts the property in the positive direction: the cull can no longer
    /// reach the backstop, and `maximumCircles` is a cap nothing hits rather
    /// than a trap. The per-parent guard is kept as belt-and-braces and because
    /// `depthZeroAlwaysSurvives` proves the end-to-end consequence.
    @Test("The circle budget and the radius floor are consistent")
    func budgetArithmetic() {
        #expect(BubblePacker.maximumCirclesPerParent + 1 <= BubbleGeometry.maximumCircles,
                "a single parent can build a level the whole-level budget then throws away")

        #expect(BubblePacker.maximumCirclesPerLevel < BubbleGeometry.maximumCircles,
                """
                The radius cull can admit more circles in one level \
                (\(BubblePacker.maximumCirclesPerLevel)) than the backstop allows \
                (\(BubbleGeometry.maximumCircles)). A wide directory will build a level that is \
                then thrown away and the user gets an empty chart. Raise maximumCircles, or \
                raise minimumRadiusFraction to at least 0.496 / sqrt(maximumCircles).
                """)
    }

    @Test("A wide, deep tree packs inside the frame budget")
    func performance() {
        // 200 directories of 200 files: 40,000 entries, which is a large but
        // ordinary Library folder, and the layout runs on every scan tick.
        var arena = Arena()
        let root = arena.createRoot(name: "Test")
        let level0 = commit(&arena, parent: root, dirs: (0..<200).map { DirSpec("d\($0)") })
        for slot in level0.dirSlots {
            commit(&arena, parent: slot,
                   files: (0..<200).map { FileSpec("f\($0)", blocks: UInt32(1 + ($0 * 37) % 5000)) })
            unwind(&arena, from: slot)
        }
        arena.finishWalk()

        let clock = ContinuousClock()
        _ = packer.pack(arena)
        let elapsed = clock.measure { _ = packer.pack(arena) }
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        // Generous, because this runs in a debug build on shared CI hardware.
        // It is here to catch an accidental quadratic, not to police tenths.
        #expect(milliseconds < 2500, "packing 40k entries took \(milliseconds) ms")

        checkInvariants(packer.pack(arena), "wide and deep")
    }
}
