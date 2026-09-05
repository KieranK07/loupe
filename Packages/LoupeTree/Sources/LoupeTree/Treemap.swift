import Foundation
import LoupeCore

/// Turns an arena plus a focus node into a bounded `TreemapLayout`.
///
/// The treemap counterpart of `SunburstProjector`, and deliberately its twin.
/// Same reduction, same sibling ordering, same culling story, same colour keys —
/// the two views are allowed to disagree about *shape* and about nothing else,
/// because the user toggles between them expecting to be looking at the same
/// machine.
///
/// A layout is a pure function of (arena, focus, basis). It caches nothing and
/// owns nothing mutable, so it can run on any thread — including concurrently
/// with the walker still appending to the arena, which is safe because arena
/// structure is append-only and subtree totals only ever grow.
public struct TreemapLayouter: Sendable {
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    /// Deepest `depth` emitted. `depth` is a *level* index, mirroring
    /// `Wedge.ring`: depth 0 holds the focus's direct children, the focus itself
    /// is never a tile and so carries no depth. `TreemapGeometry.maximumDepth` is
    /// therefore read as a count of levels exactly as `maximumRings` is a count
    /// of rings — 4 means four levels, 0...3 — and no emitted tile ever has
    /// `depth >= maximumDepth`.
    static let deepestDepth: UInt8 =
        TreemapGeometry.maximumDepth > 0 ? TreemapGeometry.maximumDepth - 1 : 0

    /// The container: the whole treemap, in the normalised coordinates the
    /// contract speaks. Origin top-left, y down.
    static let container = TreemapRect(x: 0, y: 0, width: 1, height: 1)

    /// Most tiles one parent may contribute to a level.
    ///
    /// The area cull alone caps a level at `1 / minimumAreaFraction` ≈ 8333
    /// tiles, which is *above* `maximumTiles`. Without this, a directory with
    /// eight thousand equal children would build a depth 0 that the whole-level
    /// budget then threw away, and the user would get an empty treemap for a
    /// full disk. Depth 0 has exactly one parent, so capping a parent at
    /// `maximumTiles - 1` real tiles plus its aggregate guarantees depth 0
    /// always fits and is always drawn. The overflow is the tail of the
    /// descending order, so it collapses into the same aggregate as everything
    /// else that was too small to draw.
    static let maximumTilesPerParent: Int = max(1, TreemapGeometry.maximumTiles - 1)

    public func layout(arena: Arena, focus: NodeRef, basis: SizeBasis,
                       generation: UInt64, scannedAt: Date,
                       isComplete: Bool) -> TreemapLayout {

        func bare(focusPath: String = "", breadcrumb: [Breadcrumb] = [],
                  physical: UInt64 = 0, logical: UInt64 = 0) -> TreemapLayout {
            TreemapLayout(generation: generation, focus: focus, focusPath: focusPath,
                          breadcrumb: breadcrumb, tiles: [],
                          totalPhysicalBytes: physical, totalLogicalBytes: logical,
                          scannedAt: scannedAt, isComplete: isComplete)
        }

        // A focus can outlive the arena it was taken from — the user zooms, a
        // rescan starts, the old ref arrives late. Refuse rather than trap.
        guard focus.isValid, !arena.dirs.isEmpty else { return bare() }
        let slot = Int(focus.slot)
        if focus.isDirectory {
            guard slot < arena.dirs.count else { return bare() }
        } else {
            guard slot < arena.files.count else { return bare() }
        }

        let crumbs = arenaBreadcrumb(arena: arena, focus: focus)
        let focusPath = arena.path(of: focus, rootPath: rootPath)

        // Focusing a file is legal — the inspector does it — but a file has no
        // children, so there is nothing to tile.
        guard focus.isDirectory else {
            let node = arena.files[slot]
            let bytes = contributedBytes(node)
            return bare(focusPath: focusPath, breadcrumb: crumbs,
                        physical: bytes.physical, logical: bytes.logical)
        }

        var tiles: [TreemapTile] = []
        var totalPhysical = arena.dirs[slot].subtreePhysicalBytes
        var totalLogical = arena.dirs[slot].subtreeLogicalBytes

        arena.files.withUnsafeBufferPointer { files in
            arena.dirs.withUnsafeBufferPointer { dirs in
                arena.names.withUnsafeBufferPointer { names in
                    let view = ArenaView(files: files, dirs: dirs, names: names)

                    // Mid-walk a subdirectory's bytes have not folded into its
                    // parent yet, so the focus's stored roll-up lags what its
                    // children already know. The children are the more current
                    // number and the one the areas are normalised by, so the
                    // header must quote the same figure or the percentages the
                    // user reads off the tiles will not add up.
                    let observed = view.childTotals(of: UInt32(slot))
                    totalPhysical = max(totalPhysical, observed.physical)
                    totalLogical = max(totalLogical, observed.logical)

                    tiles = layOut(focus: UInt32(slot), basis: basis, arena: view)
                }
            }
        }

        return TreemapLayout(generation: generation, focus: focus, focusPath: focusPath,
                             breadcrumb: crumbs, tiles: tiles,
                             totalPhysicalBytes: totalPhysical,
                             totalLogicalBytes: totalLogical,
                             scannedAt: scannedAt, isComplete: isComplete)
    }

    // MARK: - Breadcrumb

    // Character-for-character the projector's walk. It is private over there and
    // `Projection.swift` is not ours to change; a treemap that disagreed with the
    // sunburst about the path to the focus would be a worse bug than the
    // duplication. `TreemapBreadcrumbTests` pins the two against each other.


    // MARK: - Layout

    /// One directory waiting to have its children laid out inside its own rect.
    private struct Frame {
        var dir: UInt32
        var rect: TreemapRect
        var seed: UInt16
    }

    /// A child that has earned a rectangle, carrying the colour key it will be
    /// emitted with.
    ///
    /// The collapsed tail rides in this array alongside real children rather than
    /// being appended after them, because the squarifier has to see its area *in
    /// sorted position*. A parent whose sub-threshold tail adds up to half of it
    /// — thousands of nearly-visible files, which is what a source checkout looks
    /// like — would otherwise be squarified around a hole and then handed the
    /// leftovers.
    private struct Placement {
        var child: SizedChild
        var seed: UInt16
        /// Zero for a real node; otherwise how many siblings this stands in for.
        var aggregating: Int
    }

    /// Per-layout scratch, threaded through `expand` so a tree with ten thousand
    /// directories does not allocate four arrays per directory.
    private struct Scratch {
        var kept: [SizedChild] = []
        var placements: [Placement] = []
        var areas: [Double] = []
        var frames: [TreemapRect] = []
    }

    /// Breadth-first, one level at a time, so the tile budget can be spent on
    /// whole levels — see the backstop below.
    private func layOut(focus: UInt32, basis: SizeBasis, arena: ArenaView) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        var frontier: [Frame] = [Frame(dir: focus, rect: Self.container, seed: 0)]
        var nextFrontier: [Frame] = []
        var levelTiles: [TreemapTile] = []
        var scratch = Scratch()

        var depth: UInt8 = 0
        while depth <= Self.deepestDepth, !frontier.isEmpty {
            levelTiles.removeAll(keepingCapacity: true)
            nextFrontier.removeAll(keepingCapacity: true)
            let canDescend = depth < Self.deepestDepth

            for frame in frontier {
                expand(frame, depth: depth, mintsSeeds: depth == 0, canDescend: canDescend,
                       basis: basis, arena: arena, scratch: &scratch,
                       into: &levelTiles, next: &nextFrontier)
            }

            if levelTiles.isEmpty { break }

            // Whole levels, never part of one. A treemap truncated mid-level
            // leaves a rectangle of bare parent showing through where its
            // children should be, and nothing on screen distinguishes that from
            // a directory that really is empty. Depth 0 cannot trip this — the
            // per-parent cap above sizes it to fit — so there is always a
            // treemap to draw.
            if tiles.count + levelTiles.count > TreemapGeometry.maximumTiles { break }

            tiles.append(contentsOf: levelTiles)
            swap(&frontier, &nextFrontier)
            depth &+= 1
        }
        return tiles
    }

    /// Lays one directory's children out inside `frame`'s rectangle.
    private func expand(_ frame: Frame, depth: UInt8, mintsSeeds: Bool, canDescend: Bool,
                        basis: SizeBasis, arena: ArenaView, scratch: inout Scratch,
                        into tiles: inout [TreemapTile], next: inout [Frame]) {
        let rect = frame.rect
        let area = rect.area
        // A parent with no area has nothing to divide up. Bailing here is half of
        // what keeps every division below finite.
        guard rect.width > 0, rect.height > 0, area > 0 else { return }

        let fileRange = arena.fileChildren(of: frame.dir)
        let dirRange = arena.directoryChildren(of: frame.dir)

        // Pass one: the denominator. Deliberately the children's sum rather than
        // the directory's own rolled-up total, for the same reason as the focus
        // header above — mid-walk the parent's total lags its children, and
        // normalising by it would leave a growing bare patch inside the parent.
        var total: UInt64 = 0
        for slot in fileRange {
            total &+= sizedChild(file: slot, arena.files[Int(slot)], basis: basis).size
        }
        for slot in dirRange {
            total &+= sizedChild(directory: slot, arena.dirs[Int(slot)], basis: basis).size
        }
        // A zero-byte subtree has no proportions to compute. Bailing here is the
        // other half of what keeps the division below from ever producing NaN, and
        // it is also the honest answer: there is nothing to show.
        guard total > 0 else { return }
        let totalBytes = Double(total)

        // Pass two: partition. The threshold is on a child's *absolute* area — its
        // share of the whole container, not of its parent — which is the direct
        // analogue of the sunburst's absolute minimum sweep and the only reading
        // of `minimumAreaFraction` that stays unit-free: at any plausible window
        // size 0.00012 of the container is roughly a 10pt square, and a tile
        // smaller than that cannot be seen or clicked wherever in the tree it
        // happens to sit. A child's area is `area * size / total`, so rearranged
        // into bytes the test is one comparison: a directory with 200k children is
        // partitioned in a single linear pass and only the survivors are ever
        // sorted. Sorting all 200k to then throw away 199k of them is the obvious
        // implementation and the one that misses the frame budget.
        let keepThreshold = totalBytes * TreemapGeometry.minimumAreaFraction / area

        scratch.kept.removeAll(keepingCapacity: true)
        var culled = CulledSiblings()

        for slot in fileRange {
            let child = sizedChild(file: slot, arena.files[Int(slot)], basis: basis)
            if Double(child.size) >= keepThreshold { scratch.kept.append(child) }
            else { culled.absorb(child, arena.names) }
        }
        for slot in dirRange {
            let child = sizedChild(directory: slot, arena.dirs[Int(slot)], basis: basis)
            if Double(child.size) >= keepThreshold { scratch.kept.append(child) }
            else { culled.absorb(child, arena.names) }
        }

        scratch.kept.sort { childSortsBefore($0, $1, arena.names) }

        // The per-parent ceiling, applied after the sort so what it sheds is
        // genuinely the smallest of the survivors and not whatever the partition
        // pass happened to see last.
        if scratch.kept.count > Self.maximumTilesPerParent {
            for index in Self.maximumTilesPerParent..<scratch.kept.count {
                culled.absorb(scratch.kept[index], arena.names)
            }
            scratch.kept.removeLast(scratch.kept.count - Self.maximumTilesPerParent)
        }

        scratch.placements.removeAll(keepingCapacity: true)
        for (index, child) in scratch.kept.enumerated() {
            // A tile's colour key is the index of its top-level ancestor under the
            // current focus; everything deeper inherits it. That is what keeps a
            // subtree one hue as you drill in, keeps the hue the same between two
            // ticks of a running scan, and — because the cull keeps a prefix of the
            // same descending order the sunburst keeps — gives a node the same key
            // in both views.
            scratch.placements.append(
                Placement(child: child,
                          seed: mintsSeeds ? UInt16(clamping: index) : frame.seed,
                          aggregating: 0))
        }

        // Siblings that are culled only because they hold nothing get counted into
        // no aggregate at all: a zero-area tile is a rectangle nobody can see and
        // nothing can land on, and the contract forbids emitting one.
        if culled.size > 0, let representative = culled.representative {
            let standIn = SizedChild(ref: representative.ref,
                                     size: culled.size,
                                     physicalBytes: culled.physicalBytes,
                                     logicalBytes: culled.logicalBytes,
                                     itemCount: UInt32(clamping: culled.itemCount),
                                     nameOffset: representative.nameOffset,
                                     nameLength: representative.nameLength,
                                     isIncomplete: false)
            // Its seed is the one index past the kept children, exactly as the
            // sunburst mints it, so a palette keyed on the seed hands the two
            // views the same colour for the same aggregate.
            let seed = mintsSeeds ? UInt16(clamping: scratch.kept.count) : frame.seed
            let at = insertionIndex(for: standIn, in: scratch.placements, arena.names)
            scratch.placements.insert(Placement(child: standIn, seed: seed,
                                                aggregating: culled.count), at: at)
        }

        scratch.areas.removeAll(keepingCapacity: true)
        for placement in scratch.placements {
            scratch.areas.append(area * Double(placement.child.size) / totalBytes)
        }

        Self.squarify(areas: scratch.areas, into: rect, frames: &scratch.frames)

        for (index, tileRect) in scratch.frames.enumerated() {
            guard index < scratch.placements.count else { break }
            // Rounding can shave a hair-thin placement down to nothing. Dropping it
            // costs the user a tile they could not have hit anyway; emitting it
            // would put a degenerate rectangle into hit testing.
            guard tileRect.width > 0, tileRect.height > 0,
                  tileRect.width.isFinite, tileRect.height.isFinite else { continue }

            let placement = scratch.placements[index]
            let child = placement.child
            let kind: WedgeKind
            let name: String
            if placement.aggregating > 0 {
                kind = .aggregated(count: placement.aggregating)
                name = aggregatedLabel(count: placement.aggregating)
            } else {
                kind = child.isIncomplete ? .stillScanning : .real
                name = arena.name(offset: child.nameOffset, length: child.nameLength)
            }

            tiles.append(TreemapTile(node: child.ref, frame: tileRect, depth: depth,
                                     physicalBytes: child.physicalBytes,
                                     logicalBytes: child.logicalBytes,
                                     itemCount: child.itemCount,
                                     name: name, kind: kind, colorSeed: placement.seed))

            // An aggregate stands for many nodes at once and has no children of its
            // own to descend into; the sunburst does not descend one either.
            if canDescend, placement.aggregating == 0, child.ref.isDirectory {
                next.append(Frame(dir: child.ref.slot, rect: tileRect, seed: placement.seed))
            }
        }
    }

    /// Where `standIn` belongs in an array already in the sibling order.
    private func insertionIndex(for standIn: SizedChild, in placements: [Placement],
                                _ names: UnsafeBufferPointer<UInt8>) -> Int {
        var low = 0, high = placements.count
        while low < high {
            let mid = (low &+ high) / 2
            if childSortsBefore(placements[mid].child, standIn, names) { low = mid &+ 1 }
            else { high = mid }
        }
        return low
    }

    // MARK: - Squarification

    /// Places `areas` — descending, summing to `rect.area` — inside `rect`.
    ///
    /// The squarified treemap of Bruls, Huizing and van Wijk. Repeatedly take the
    /// *shorter* side of whatever rectangle is left and grow a strip along it for
    /// as long as adding one more child improves the worst aspect ratio in that
    /// strip; the moment it gets worse, close the strip, shrink the free
    /// rectangle by its thickness and start the next one. Laying the strip along
    /// the shorter side is the whole trick: it is the choice that bounds how
    /// elongated the strip can get before it is worth closing.
    ///
    /// Slice-and-dice — one cut per child, all parallel — is a dozen lines
    /// shorter and produces rectangles at ratios of hundreds to one. Those are
    /// unreadable, they cannot carry a label, and at four points wide they are
    /// not reliably clickable either, which is the actual reason this algorithm
    /// is worth its length.
    private static func squarify(areas: [Double], into rect: TreemapRect,
                                 frames: inout [TreemapRect]) {
        frames.removeAll(keepingCapacity: true)
        let count = areas.count
        guard count > 0 else { return }

        var free = rect
        var index = 0

        while index < count {
            // `side` is the extent the strip runs along; its thickness grows
            // perpendicular to it as children are added.
            let side = min(free.width, free.height)
            // Rounding has eaten the free rectangle, or the caller handed us areas
            // that do not sum to `rect.area`. Either way there is no geometry left
            // to hand out, and stopping is strictly better than emitting
            // rectangles that escape the parent.
            guard side > 0, free.width > 0, free.height > 0 else { break }

            var runSum = areas[index]
            var worst = worstAspect(largest: areas[index], smallest: areas[index],
                                    sum: runSum, side: side)
            var end = index + 1
            while end < count {
                let sum = runSum + areas[end]
                // The run is in descending order, so its extremes are its first and
                // its newest member and the worst ratio needs no rescan.
                let candidate = worstAspect(largest: areas[index], smallest: areas[end],
                                            sum: sum, side: side)
                // `>` and not `>=`: on a run of equal children the ratio plateaus,
                // and breaking on the plateau would close a strip per child, which
                // is slice-and-dice wearing a disguise.
                if candidate > worst { break }
                worst = candidate
                runSum = sum
                end += 1
            }

            let isFinalRun = end == count
            let column = free.width >= free.height
            var thickness = runSum / side
            if isFinalRun {
                // The areas sum to the parent's area, so the last strip is exactly
                // what is left. Snapping says so exactly rather than to within an
                // ulp, which is what puts the last child's edge *on* its parent's
                // edge instead of a hair inside or outside it.
                thickness = column ? free.width : free.height
            } else {
                thickness = min(thickness, column ? free.width : free.height)
            }
            guard thickness > 0, thickness.isFinite else { break }

            // Boundaries come from a running *fraction* of the strip rather than
            // from accumulating per-child extents, so rounding cannot drift a run
            // of four thousand siblings off the end of the strip.
            let start = column ? free.y : free.x
            var cursor = start
            var running = 0.0
            for member in index..<end {
                running += areas[member]
                var edge = start + side * (running / runSum)
                if member == end - 1 { edge = start + side }
                if edge < cursor { edge = cursor }
                frames.append(column
                    ? TreemapRect(x: free.x, y: cursor, width: thickness, height: edge - cursor)
                    : TreemapRect(x: cursor, y: free.y, width: edge - cursor, height: thickness))
                cursor = edge
            }

            free = column
                ? TreemapRect(x: free.x + thickness, y: free.y,
                              width: max(0, free.width - thickness), height: free.height)
                : TreemapRect(x: free.x, y: free.y + thickness,
                              width: free.width, height: max(0, free.height - thickness))
            index = end
        }
    }

    /// The worst aspect ratio in a strip of thickness `sum / side` holding
    /// children between `smallest` and `largest` in area.
    ///
    /// A child of area `a` in that strip is `a * side / sum` long, so its ratio is
    /// `max(side²a/sum², sum²/(side²a))` — monotonic in `a` on either branch,
    /// which is why the two extremes settle the whole strip.
    @inline(__always)
    private static func worstAspect(largest: Double, smallest: Double,
                                    sum: Double, side: Double) -> Double {
        guard sum > 0, side > 0, smallest > 0, largest > 0 else { return .infinity }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }
}

// MARK: - Borrowed arena

/// Borrowed views of the three arenas, taken once per layout.
///
/// A layout of a broad tree touches tens of thousands of child records, ten times
/// a second, for the length of a scan. `ContiguousArray`'s bounds-checked
/// subscript is not free at that rate, and the arena cannot mutate underneath a
/// single `layout` call, so the pointers are taken once at the top and passed
/// down rather than re-derived per directory.
///
/// A near-copy of `Projection.swift`'s `ArenaView`, which is file-private there
/// and not ours to widen. Worth promoting to one shared internal type the next
/// time that file is open.

