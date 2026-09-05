import Foundation
import LoupeCore

/// Turns an arena plus a focus node into a bounded `BubbleLayout`.
///
/// The third of the three layout engines, and deliberately the sibling of
/// `TreemapLayouter`: same reduction to `SizedChild`, same sibling ordering,
/// same culling story, same colour keys, same breadth-first level budget. The
/// three views are allowed to disagree about *shape* and about nothing else,
/// because the user toggles between them expecting to be looking at the same
/// machine.
///
/// What is genuinely different is the geometry. A treemap tiles its container
/// exactly; a circle pack does not tile at all, so a level's children have to be
/// packed, enclosed, and then scaled to fit the parent. That costs density and
/// buys nesting you can see at a glance — which is the trade `BubbleLayout`'s
/// own doc comment states, and which the UI is required to repeat out loud so a
/// pretty chart does not imply a precision it does not have.
///
/// A layout is a pure function of (arena, focus, basis). It caches nothing and
/// owns nothing mutable, so it can run on any thread — including concurrently
/// with the walker still appending to the arena, which is safe because arena
/// structure is append-only and subtree totals only ever grow.
public struct BubblePacker: Sendable {
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    /// Deepest `depth` emitted. `depth` is a *level* index, mirroring
    /// `Wedge.ring` and `TreemapTile.depth`: depth 0 holds the focus's direct
    /// children, and the focus itself is never a circle. `maximumDepth` is a
    /// count of levels, so 4 means 0...3 and no emitted circle ever has
    /// `depth >= maximumDepth`.
    static let deepestDepth: UInt8 =
        BubbleGeometry.maximumDepth > 0 ? BubbleGeometry.maximumDepth - 1 : 0

    /// The container: the focus's own circle, inscribed in the normalised unit
    /// square. It is never emitted — the contract says so, and a disc under the
    /// whole chart would swallow every click that missed a child.
    static let containerCenter: Double = 0.5
    static let containerRadius: Double = 0.5

    /// The radius a child is packed into, inside a parent of radius `r`.
    ///
    /// One padding's worth of the parent is kept clear all the way round. That
    /// ring of parent colour showing past its children is the only thing that
    /// makes nesting visible here, exactly as the treemap's gutter is.
    @inline(__always)
    static func innerRadius(of radius: Double) -> Double {
        radius - BubbleGeometry.siblingPadding
    }

    /// Most circles the radius cull can admit in **one level**, at any depth.
    ///
    /// A kept child's final radius is at most `rInner * sqrt(bytes / total)` —
    /// see `keepThreshold` below for why — so `radius >= minimumRadiusFraction`
    /// forces `bytes/total >= (minimumRadiusFraction / rInner)^2`. Shares sum to
    /// one, so one parent can keep at most `(rInner / minimumRadiusFraction)^2`
    /// children: `(0.496 / 0.006)^2 = 6833` at depth 0, which has exactly one
    /// parent. A whole *level* is bounded by the same area argument one step
    /// out — parents at a level are disjoint discs inside the focus, so their
    /// radii square-sum to at most `0.5^2` — giving `(0.5 / 0.006)^2 = 6944`.
    ///
    /// Either way it is **more than `BubbleGeometry.maximumCircles` (3000)**,
    /// which is the exact
    /// inconsistency `BubbleGeometry.maximumCircles`'s own doc comment warns
    /// about and that shipped once in `TreemapGeometry`: a wide directory builds
    /// a level the cross-level backstop then throws away, and the user gets an
    /// empty chart for a full disk. `maximumCirclesPerParent` below is the
    /// guard that keeps depth 0 drawable regardless; the constants themselves
    /// still want fixing, and `BubblePackTests` pins the arithmetic so the day
    /// they are fixed this comment stops being a lie.
    static let maximumCirclesPerLevel: Int = {
        let ratio = innerRadius(of: containerRadius) / BubbleGeometry.minimumRadiusFraction
        return Int(ratio * ratio)
    }()

    /// Most circles one parent may contribute to a level.
    ///
    /// Depth 0 has exactly one parent, so capping a parent at
    /// `maximumCircles - 1` real circles plus its aggregate guarantees depth 0
    /// always fits inside the whole-level budget and is always drawn. The
    /// overflow is the tail of the descending order, so it collapses into the
    /// same aggregate as everything else too small to draw. Identical reasoning
    /// to `TreemapLayouter.maximumTilesPerParent`, and needed here for the same
    /// reason: `maximumCircles` is below `maximumCirclesPerLevel`.
    static let maximumCirclesPerParent: Int = max(1, BubbleGeometry.maximumCircles - 1)

    public func pack(arena: Arena, focus: NodeRef, basis: SizeBasis,
                     generation: UInt64, scannedAt: Date,
                     isComplete: Bool) -> BubbleLayout {

        func bare(focusPath: String = "", breadcrumb: [Breadcrumb] = [],
                  physical: UInt64 = 0, logical: UInt64 = 0) -> BubbleLayout {
            BubbleLayout(generation: generation, focus: focus, focusPath: focusPath,
                         breadcrumb: breadcrumb, circles: [],
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
        // children, so there is nothing to pack.
        guard focus.isDirectory else {
            let node = arena.files[slot]
            let bytes = contributedBytes(node)
            return bare(focusPath: focusPath, breadcrumb: crumbs,
                        physical: bytes.physical, logical: bytes.logical)
        }

        var circles: [BubbleCircle] = []
        var totalPhysical = arena.dirs[slot].subtreePhysicalBytes
        var totalLogical = arena.dirs[slot].subtreeLogicalBytes

        arena.files.withUnsafeBufferPointer { files in
            arena.dirs.withUnsafeBufferPointer { dirs in
                arena.names.withUnsafeBufferPointer { names in
                    let view = ArenaView(files: files, dirs: dirs, names: names)

                    // Mid-walk a subdirectory's bytes have not folded into its
                    // parent yet, so the focus's stored roll-up lags what its
                    // children already know. The children are the more current
                    // number and the one the radii are normalised by, so the
                    // header must quote the same figure or the percentages the
                    // user reads off the circles will not add up.
                    let observed = view.childTotals(of: UInt32(slot))
                    totalPhysical = max(totalPhysical, observed.physical)
                    totalLogical = max(totalLogical, observed.logical)

                    circles = layOut(focus: UInt32(slot), basis: basis, arena: view)
                }
            }
        }

        return BubbleLayout(generation: generation, focus: focus, focusPath: focusPath,
                            breadcrumb: crumbs, circles: circles,
                            totalPhysicalBytes: totalPhysical,
                            totalLogicalBytes: totalLogical,
                            scannedAt: scannedAt, isComplete: isComplete)
    }

    // MARK: - Layout

    /// One directory waiting to have its children packed inside its own circle.
    private struct Frame {
        var dir: UInt32
        var centerX: Double
        var centerY: Double
        var radius: Double
        var seed: UInt16
        /// Index in the working array of the circle this frame came from, or −1
        /// for the focus, which is not a circle.
        var owner: Int
    }

    /// A child that has earned a circle, carrying the colour key it will be
    /// emitted with.
    ///
    /// The collapsed tail rides in this array alongside real children rather
    /// than being appended after them, because the packer has to see its radius
    /// *in sorted position*: the front chain places circles largest-first, and a
    /// sub-threshold tail that adds up to half the parent — thousands of nearly
    /// visible files, which is what a source checkout looks like — would
    /// otherwise be packed last into whatever crevices were left.
    private struct Placement {
        var child: SizedChild
        var seed: UInt16
        /// Zero for a real node; otherwise how many siblings this stands in for.
        var aggregating: Int
    }

    /// An emitted circle before `hasChildren` is known.
    ///
    /// Whether a circle has children in the *layout* cannot be answered until
    /// the next level has been built and survived the budget, so the flag is
    /// filled in by a second pass rather than guessed from `NodeRef.isDirectory`
    /// — a directory whose children were all culled has none here, and styling
    /// it as though it did would promise a zoom that shows nothing.
    private struct Working {
        var node: NodeRef
        var centerX: Double
        var centerY: Double
        var radius: Double
        var depth: UInt8
        var physicalBytes: UInt64
        var logicalBytes: UInt64
        var itemCount: UInt32
        var name: String
        var kind: WedgeKind
        var colorSeed: UInt16
        var parent: Int
        var hasChildren: Bool
    }

    /// Per-layout scratch, threaded through `expand` so a tree with ten thousand
    /// directories does not allocate four arrays per directory.
    private struct Scratch {
        var kept: [SizedChild] = []
        var placements: [Placement] = []
        var radii: [Double] = []
        var packed: [PackedCircle] = []
    }

    /// Breadth-first, one level at a time, so the circle budget can be spent on
    /// whole levels — see the backstop below.
    private func layOut(focus: UInt32, basis: SizeBasis, arena: ArenaView) -> [BubbleCircle] {
        var working: [Working] = []
        var levelCircles: [Working] = []
        var frontier: [Frame] = [Frame(dir: focus, centerX: Self.containerCenter,
                                       centerY: Self.containerCenter,
                                       radius: Self.containerRadius, seed: 0, owner: -1)]
        var nextFrontier: [Frame] = []
        var scratch = Scratch()

        var depth: UInt8 = 0
        while depth <= Self.deepestDepth, !frontier.isEmpty {
            levelCircles.removeAll(keepingCapacity: true)
            nextFrontier.removeAll(keepingCapacity: true)
            let canDescend = depth < Self.deepestDepth

            for frame in frontier {
                expand(frame, depth: depth, mintsSeeds: depth == 0, canDescend: canDescend,
                       basis: basis, arena: arena, scratch: &scratch,
                       committed: working.count, into: &levelCircles, next: &nextFrontier)
            }

            if levelCircles.isEmpty { break }

            // Whole levels, never part of one. A pack truncated mid-level leaves
            // a disc of bare parent where its children should be, and nothing on
            // screen distinguishes that from a directory that really is empty.
            // Depth 0 cannot trip this — `maximumCirclesPerParent` sizes it to
            // fit — so there is always a chart to draw.
            if working.count + levelCircles.count > BubbleGeometry.maximumCircles { break }

            working.append(contentsOf: levelCircles)
            swap(&frontier, &nextFrontier)
            depth &+= 1
        }

        // Second pass for `hasChildren`. Done after the level budget has had its
        // say, so a parent whose children were dropped with their whole level is
        // correctly reported as childless.
        for i in working.indices where working[i].parent >= 0 {
            working[working[i].parent].hasChildren = true
        }

        var circles: [BubbleCircle] = []
        circles.reserveCapacity(working.count)
        for item in working {
            circles.append(BubbleCircle(node: item.node, centerX: item.centerX,
                                        centerY: item.centerY, radius: item.radius,
                                        depth: item.depth,
                                        physicalBytes: item.physicalBytes,
                                        logicalBytes: item.logicalBytes,
                                        itemCount: item.itemCount, name: item.name,
                                        kind: item.kind, colorSeed: item.colorSeed,
                                        hasChildren: item.hasChildren))
        }
        return circles
    }

    /// Packs one directory's children inside `frame`'s circle.
    private func expand(_ frame: Frame, depth: UInt8, mintsSeeds: Bool, canDescend: Bool,
                        basis: SizeBasis, arena: ArenaView, scratch: inout Scratch,
                        committed: Int, into circles: inout [Working], next: inout [Frame]) {
        let inner = Self.innerRadius(of: frame.radius)
        // A parent with no room inside it has nothing to divide up, and nothing
        // it could hold would clear the radius floor anyway. Bailing here is
        // half of what keeps every division below finite.
        guard inner >= BubbleGeometry.minimumRadiusFraction, inner.isFinite else { return }

        let fileRange = arena.fileChildren(of: frame.dir)
        let dirRange = arena.directoryChildren(of: frame.dir)

        // Pass one: the denominator. Deliberately the children's sum rather than
        // the directory's own rolled-up total, for the same reason as the focus
        // header above — mid-walk the parent's total lags its children, and
        // normalising by it would leave a growing bare ring inside the parent.
        var total: UInt64 = 0
        for slot in fileRange {
            total &+= sizedChild(file: slot, arena.files[Int(slot)], basis: basis).size
        }
        for slot in dirRange {
            total &+= sizedChild(directory: slot, arena.dirs[Int(slot)], basis: basis).size
        }
        // A zero-byte subtree has no proportions to compute. Bailing here is the
        // other half of what keeps the division below from ever producing NaN,
        // and it is also the honest answer: there is nothing to show.
        guard total > 0 else { return }
        let totalBytes = Double(total)

        // Pass two: partition, on a bound rather than on the answer.
        //
        // Radius is proportional to the square root of size, because AREA
        // encodes size — a radius proportional to size would exaggerate a big
        // folder by its own factor again. After packing, the whole arrangement
        // is scaled by `inner / enclosingRadius`, and the enclosing circle can
        // never be smaller than one whose area equals the children's combined
        // area, so `enclosingRadius >= sqrt(sum of r^2)`. That gives a hard
        // upper bound on a child's final radius, `inner * sqrt(size / total)`,
        // and the cull tests that bound: rearranged into bytes it is one
        // comparison, so a directory with 200k children is partitioned in a
        // single linear pass and only the survivors are ever sorted. Sorting all
        // 200k to then throw away 199k of them is the obvious implementation and
        // the one that misses the frame budget.
        //
        // Culling on the bound rather than on the packed radius is deliberate:
        // the packed radius is not known until the pack has happened, and
        // dropping circles afterwards would leave holes the aggregate does not
        // account for. The cost is that a mark near the threshold can land a
        // little under the nominal floor once real packing waste is priced in.
        let shareFloor = BubbleGeometry.minimumRadiusFraction / inner
        let keepThreshold = totalBytes * shareFloor * shareFloor

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
        if scratch.kept.count > Self.maximumCirclesPerParent {
            for index in Self.maximumCirclesPerParent..<scratch.kept.count {
                culled.absorb(scratch.kept[index], arena.names)
            }
            scratch.kept.removeLast(scratch.kept.count - Self.maximumCirclesPerParent)
        }

        scratch.placements.removeAll(keepingCapacity: true)
        for (index, child) in scratch.kept.enumerated() {
            // A circle's colour key is the index of its top-level ancestor under
            // the current focus; everything deeper inherits it. That is what
            // keeps a subtree one hue as you fall into it, keeps the hue the
            // same between two ticks of a running scan, and — because the cull
            // keeps a prefix of the same descending order the other two engines
            // keep — gives a node the same key in all three views.
            scratch.placements.append(
                Placement(child: child,
                          seed: mintsSeeds ? UInt16(clamping: index) : frame.seed,
                          aggregating: 0))
        }

        // Siblings culled only because they hold nothing get counted into no
        // aggregate at all: a zero-radius circle is a mark nobody can see and
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
            // sunburst and the treemap mint it, so a palette keyed on the seed
            // hands all three views the same colour for the same aggregate.
            let seed = mintsSeeds ? UInt16(clamping: scratch.kept.count) : frame.seed
            let at = insertionIndex(for: standIn, in: scratch.placements, arena.names)
            scratch.placements.insert(Placement(child: standIn, seed: seed,
                                                aggregating: culled.count), at: at)
        }
        guard !scratch.placements.isEmpty else { return }

        // Pass three: pack, enclose, scale.
        //
        // Radii are normalised so the largest is exactly 1. The front chain and
        // the enclosing pass both carry a fixed absolute tolerance, and a
        // directory holding a terabyte would otherwise be packed in units where
        // sqrt(bytes) is a million and that tolerance means nothing.
        let largest = Double(scratch.placements[0].child.size)
        guard largest > 0 else { return }
        scratch.radii.removeAll(keepingCapacity: true)
        var sumSquares = 0.0
        for placement in scratch.placements {
            let radius = (Double(placement.child.size) / largest).squareRoot()
            sumSquares += radius * radius
            scratch.radii.append(radius)
        }

        applyPadding(to: &scratch.radii, inner: inner, sumSquares: sumSquares)

        let placed = CirclePack.packSiblings(radii: scratch.radii, into: &scratch.packed)
        guard placed > 0 else { return }
        let enclosing = CirclePack.enclose(scratch.packed, count: placed)
        guard enclosing.r > 0, enclosing.r.isFinite else { return }
        let scale = inner / enclosing.r
        guard scale > 0, scale.isFinite else { return }

        for index in 0..<placed {
            let placement = scratch.placements[index]
            // The emitted radius is the *unpadded* radius scaled, so area stays
            // exactly proportional to size. Only the packing saw the padding.
            let radius = scale * (Double(placement.child.size) / largest).squareRoot()
            let centerX = frame.centerX + (scratch.packed[index].x - enclosing.x) * scale
            let centerY = frame.centerY + (scratch.packed[index].y - enclosing.y) * scale
            // Rounding can shave a hair-thin placement down to nothing. Dropping
            // it costs the user a circle they could not have hit anyway;
            // emitting it would put a degenerate mark into hit testing.
            guard radius > 0, radius.isFinite, centerX.isFinite, centerY.isFinite else { continue }

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

            let at = committed + circles.count
            circles.append(Working(node: child.ref, centerX: centerX, centerY: centerY,
                                   radius: radius, depth: depth,
                                   physicalBytes: child.physicalBytes,
                                   logicalBytes: child.logicalBytes,
                                   itemCount: child.itemCount, name: name, kind: kind,
                                   colorSeed: placement.seed, parent: frame.owner,
                                   hasChildren: false))

            // An aggregate stands for many nodes at once and has no children of
            // its own to fall into; neither of the other two engines descends
            // one either. And a circle with no room inside it for even the
            // smallest admissible child is not worth queueing.
            guard canDescend, placement.aggregating == 0, child.ref.isDirectory else { continue }
            guard Self.innerRadius(of: radius) >= BubbleGeometry.minimumRadiusFraction else { continue }
            next.append(Frame(dir: child.ref.slot, centerX: centerX, centerY: centerY,
                              radius: radius, seed: placement.seed, owner: at))
        }
    }

    /// Grows every radius so that, once the pack is scaled down into its parent,
    /// tangent siblings end up about `siblingPadding` apart.
    ///
    /// The scale is not known until the pack has been enclosed, and the padding
    /// has to be applied *before* the pack — so the scale is estimated from the
    /// two bounds that always hold: the enclosing circle is at least as big as
    /// the largest child, and at least as big as a disc of the children's
    /// combined area. Real packings of a heavy-tailed distribution land near
    /// three-quarters density, so that is the divisor. A packing pass purely to
    /// learn the scale, then a second to use it, is the exact alternative — and
    /// it doubles the cost of the most expensive thing this file does in order
    /// to size a cosmetic gap to within a few percent instead of a few tens.
    ///
    /// The cap is the part that matters. A flat absolute gap around a circle
    /// only a few times wider than the gap itself is not a separator, it is the
    /// mark: at the radius floor, `siblingPadding` is two thirds of a diameter,
    /// and inflating by it would balloon the enclosing circle and shrink the
    /// whole level. Above a quarter of its own radius, a circle's padding stops
    /// growing and the gap becomes proportional instead.
    ///
    /// Deflating afterwards — pack tangent, scale, then shave each final radius
    /// — is the obvious one-pass alternative and it is wrong: an absolute shave
    /// takes a third of the radius off the smallest marks and none off the
    /// largest, so area stops encoding size on exactly the marks that are
    /// already hardest to judge.
    private func applyPadding(to radii: inout [Double], inner: Double, sumSquares: Double) {
        let padding = BubbleGeometry.siblingPadding
        guard padding > 0, radii.count > 1, inner > 0 else { return }
        let estimatedEnclosing = max(1, (sumSquares / 0.75).squareRoot())
        let estimatedScale = inner / estimatedEnclosing
        guard estimatedScale > 0, estimatedScale.isFinite else { return }
        let nominal = padding / (2 * estimatedScale)
        guard nominal > 0, nominal.isFinite else { return }
        for i in radii.indices {
            radii[i] += min(nominal, radii[i] * 0.25)
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
}

// MARK: - Circle packing

/// A circle in the packer's own working units, before it is scaled into a
/// parent. Units are arbitrary — only ratios survive the scaling — and the
/// caller normalises so the largest radius is exactly 1.
struct PackedCircle: Sendable, Hashable {
    var x: Double
    var y: Double
    var r: Double
}

/// The geometry, separated from the tree walk so it can be tested on radii
/// alone: the two invariants `BubbleLayout` promises are properties of these two
/// functions, and nothing about an arena is needed to check them.
enum CirclePack {
    /// How much overlap the front chain will forgive when deciding whether a
    /// candidate collides with a chain member.
    ///
    /// Absolute, and that is safe only because the caller normalises the largest
    /// radius to 1 — so this is a relative tolerance in disguise. Zero is not
    /// usable: the placement below makes a circle *exactly* tangent to two
    /// neighbours, and exact tangency read back through a square root is as
    /// likely to test as a hair of overlap as a hair of clearance, which would
    /// send the chain-cutting loop round for no reason.
    static let tolerance: Double = 1e-6

    // MARK: Front chain

    /// Packs `radii` — descending — as mutually non-overlapping tangent circles
    /// around the origin, writing them into `circles` in the same order.
    /// Returns how many were placed.
    ///
    /// The front-chain algorithm of Wang et al., the one D3 uses. Place the
    /// first three mutually tangent, then keep a doubly linked *front* — the
    /// circles currently on the boundary of what has been packed — and put each
    /// next circle tangent to the two front members `a` and `b`. If it collides
    /// with some other front member, cut the front back to that member and try
    /// again; after each success, restart from the pair whose weighted midpoint
    /// is nearest the origin, which is what keeps the whole thing growing
    /// roughly circularly instead of spiralling off in one direction.
    ///
    /// The obvious alternative — place each circle at the first free angle on a
    /// spiral — is a dozen lines shorter and packs at roughly half the density,
    /// which here does not merely look loose: every level is scaled to fit its
    /// parent, so a level that packs half as tightly makes every circle in it
    /// smaller by a factor of √2, and the effect compounds with depth until the
    /// third level is invisible.
    @discardableResult
    static func packSiblings(radii: [Double], into circles: inout [PackedCircle]) -> Int {
        circles.removeAll(keepingCapacity: true)
        let n = radii.count
        guard n > 0 else { return 0 }
        circles.reserveCapacity(n)
        for r in radii { circles.append(PackedCircle(x: 0, y: 0, r: max(0, r))) }

        if n == 1 { return 1 }
        // Two circles sit on the x axis, tangent, straddling the origin.
        circles[0].x = -circles[1].r
        circles[1].x = circles[0].r
        circles[1].y = 0
        if n == 2 { return 2 }
        place(&circles, b: 1, a: 0, c: 2)

        var next = [Int](repeating: 0, count: n)
        var previous = [Int](repeating: 0, count: n)
        next[0] = 1; next[1] = 2; next[2] = 0
        previous[0] = 2; previous[1] = 0; previous[2] = 1

        var a = 0, b = 1
        var i = 3

        // The pack's area-weighted centre of mass, maintained as circles are
        // added so `score` can measure from it.
        var momentX = 0.0, momentY = 0.0, mass = 0.0
        for seed in 0...2 {
            let area = circles[seed].r * circles[seed].r
            momentX += circles[seed].x * area
            momentY += circles[seed].y * area
            mass += area
        }
        // A cut retries the same circle against a shorter front. Each cut
        // strictly shortens the front, so the retries terminate — but the front
        // grows again on every success, so "strictly shortens" is not by itself
        // a bound on the total. This is that bound: a hang guard, not a step of
        // the algorithm, and tripping it means a bug rather than a wide
        // directory. What it costs when it trips is the tail of the level, which
        // is the smallest circles.
        var attempts = 0
        let attemptLimit = 64 * n + 64

        while i < n {
            attempts += 1
            if attempts > attemptLimit { return i }

            place(&circles, b: a, a: b, c: i)

            // Walk out along the front in both directions at once, always
            // extending the side that has covered less arc, so the *nearest*
            // collision along the front is the one found — cutting back to a
            // farther one would throw away circles that are still on the
            // boundary.
            var j = next[b], k = previous[a]
            var sj = circles[b].r, sk = circles[a].r
            var cut = false
            repeat {
                if sj <= sk {
                    if intersects(circles[j], circles[i]) {
                        b = j; next[a] = b; previous[b] = a
                        cut = true
                        break
                    }
                    sj += circles[j].r
                    j = next[j]
                } else {
                    if intersects(circles[k], circles[i]) {
                        a = k; next[a] = b; previous[b] = a
                        cut = true
                        break
                    }
                    sk += circles[k].r
                    k = previous[k]
                }
            } while j != next[k]
            if cut { continue }

            previous[i] = a
            next[i] = b
            next[a] = i
            previous[b] = i

            let area = circles[i].r * circles[i].r
            momentX += circles[i].x * area
            momentY += circles[i].y * area
            mass += area
            let centreX = mass > 0 ? momentX / mass : 0
            let centreY = mass > 0 ? momentY / mass : 0

            // Restart from the front pair whose weighted midpoint is closest to
            // the middle of what has been packed. Without this the front is
            // walked in insertion order and the pack drifts into a comma shape.
            b = i
            var bestScore = score(circles, a, next, centreX: centreX, centreY: centreY)
            var node = next[i]
            while node != b {
                let candidate = score(circles, node, next, centreX: centreX, centreY: centreY)
                if candidate < bestScore {
                    a = node
                    bestScore = candidate
                }
                node = next[node]
            }
            b = next[a]
            i += 1
        }
        return n
    }

    /// Places `c` tangent to both `a` and `b`, on the far side of the line
    /// through their centres.
    private static func place(_ circles: inout [PackedCircle], b: Int, a: Int, c: Int) {
        let ax = circles[a].x, ay = circles[a].y, ar = circles[a].r
        let bx = circles[b].x, by = circles[b].y, br = circles[b].r
        let cr = circles[c].r
        let dx = bx - ax, dy = by - ay
        let d2 = dx * dx + dy * dy
        guard d2 > 0 else {
            // Two coincident anchors, which can only happen if both are
            // degenerate. Tangent to `a` along the x axis is the answer that
            // keeps the non-overlap invariant true; sitting on top of `a`, which
            // is what the reference implementation does here, does not.
            circles[c].x = ax + ar + cr
            circles[c].y = ay
            return
        }
        var a2 = ar + cr; a2 *= a2
        var b2 = br + cr; b2 *= b2
        // Anchor the construction on whichever tangency is the longer lever, so
        // the square root below is taken of the better-conditioned quantity.
        if a2 > b2 {
            let x = (d2 + b2 - a2) / (2 * d2)
            let y = max(0, b2 / d2 - x * x).squareRoot()
            circles[c].x = bx - x * dx - y * dy
            circles[c].y = by - x * dy + y * dx
        } else {
            let x = (d2 + a2 - b2) / (2 * d2)
            let y = max(0, a2 / d2 - x * x).squareRoot()
            circles[c].x = ax + x * dx - y * dy
            circles[c].y = ay + x * dy + y * dx
        }
    }

    @inline(__always)
    private static func intersects(_ a: PackedCircle, _ b: PackedCircle) -> Bool {
        let reach = a.r + b.r - tolerance
        guard reach > 0 else { return false }
        let dx = b.x - a.x, dy = b.y - a.y
        return reach * reach > dx * dx + dy * dy
    }

    /// How far the front edge between `node` and its successor is from the
    /// pack's centre of mass, weighted towards the smaller of the two circles.
    ///
    /// Measuring from the *centroid* rather than from the origin is a
    /// deliberate departure from the reference implementation, and it is worth
    /// the two running sums it costs. The first two circles straddle the origin
    /// and nothing afterwards holds the pack there, so once a level is a few
    /// dozen circles the origin is no longer its middle and "grow from the edge
    /// nearest the origin" stops meaning "stay round". Measured on equal-sized
    /// siblings — a directory of a dozen photos, which is not a rare shape —
    /// the origin version packs at 0.42 of the enclosing disc against 0.59
    /// here, and every circle in a level that packs loosely is scaled down by
    /// the shortfall. On the heavy-tailed distributions a real filesystem
    /// produces the two are within a fifth of a percent, so nothing is traded
    /// away for it.
    @inline(__always)
    private static func score(_ circles: [PackedCircle], _ node: Int, _ next: [Int],
                              centreX: Double, centreY: Double) -> Double {
        let a = circles[node], b = circles[next[node]]
        let ab = a.r + b.r
        guard ab > 0 else {
            let dx = a.x - centreX, dy = a.y - centreY
            return dx * dx + dy * dy
        }
        let x = (a.x * b.r + b.x * a.r) / ab - centreX
        let y = (a.y * b.r + b.y * a.r) / ab - centreY
        return x * x + y * y
    }

    // MARK: Minimum enclosing circle

    /// The smallest circle containing all of `circles[0..<count]`.
    ///
    /// Welzl's randomised incremental algorithm, in its balls-not-points form:
    /// carry a basis of at most three circles that determines the current
    /// answer, and whenever a circle falls outside, rebuild the basis around it
    /// and start again. Expected linear because of the shuffle, which is seeded
    /// identically every call — a layout is recomputed ten times a second during
    /// a scan, and an enclosing circle that depended on a random draw would make
    /// the whole chart shiver.
    ///
    /// The radius returned is not Welzl's. It is recomputed exactly, as the
    /// largest `distance-to-centre plus radius` over the input, which is the
    /// same number when the basis is right and a strictly safe one when
    /// floating point has made it slightly wrong. Everything downstream divides
    /// by this to fit the pack inside its parent, so the nesting invariant is
    /// only as true as this radius is — and "expected linear, exact up to
    /// rounding" is worth far less here than "never too small".
    static func enclose(_ circles: [PackedCircle], count: Int) -> PackedCircle {
        let n = min(count, circles.count)
        guard n > 0 else { return PackedCircle(x: 0, y: 0, r: 0) }
        if n == 1 { return circles[0] }

        var order = Array(0..<n)
        var state: UInt32 = 1
        var i = n - 1
        while i > 0 {
            state = state &* 1_664_525 &+ 1_013_904_223
            order.swapAt(i, Int(state >> 8) % (i + 1))
            i -= 1
        }

        var basis: [PackedCircle] = []
        var best = PackedCircle(x: 0, y: 0, r: 0)
        var haveBest = false
        var k = 0
        var steps = 0
        // Same kind of guard as the front chain's: the restart-from-zero makes
        // the worst case quadratic, and a degenerate input could in principle
        // fail to converge at all. Falling out to the centroid below is a
        // slightly loose circle, which costs a little space and breaks nothing.
        let stepLimit = 32 * n + 64

        while k < n {
            steps += 1
            if steps > stepLimit { break }
            let candidate = circles[order[k]]
            if haveBest, enclosesWeak(best, candidate) {
                k += 1
                continue
            }
            guard let extended = extendBasis(basis, candidate) else { break }
            basis = extended
            best = encloseBasis(basis)
            haveBest = true
            k = 0
        }

        var centerX = best.x, centerY = best.y
        if !haveBest || !best.r.isFinite || !best.x.isFinite || !best.y.isFinite {
            var sumX = 0.0, sumY = 0.0
            for index in 0..<n {
                sumX += circles[index].x
                sumY += circles[index].y
            }
            centerX = sumX / Double(n)
            centerY = sumY / Double(n)
        }

        var radius = 0.0
        for index in 0..<n {
            let dx = circles[index].x - centerX, dy = circles[index].y - centerY
            radius = max(radius, (dx * dx + dy * dy).squareRoot() + circles[index].r)
        }
        return PackedCircle(x: centerX, y: centerY, r: radius)
    }

    /// True when `a` contains `b`, with a relative slack so a circle sitting
    /// exactly on the boundary — which is what a basis circle does — is not
    /// re-admitted forever.
    @inline(__always)
    private static func enclosesWeak(_ a: PackedCircle, _ b: PackedCircle) -> Bool {
        let slack = a.r - b.r + max(a.r, b.r, 1) * 1e-9
        guard slack > 0 else { return false }
        let dx = b.x - a.x, dy = b.y - a.y
        return slack * slack > dx * dx + dy * dy
    }

    @inline(__always)
    private static func enclosesNot(_ a: PackedCircle, _ b: PackedCircle) -> Bool {
        let slack = a.r - b.r
        if slack < 0 { return true }
        let dx = b.x - a.x, dy = b.y - a.y
        return slack * slack < dx * dx + dy * dy
    }

    private static func enclosesWeakAll(_ a: PackedCircle, _ basis: [PackedCircle]) -> Bool {
        for circle in basis where !enclosesWeak(a, circle) { return false }
        return true
    }

    /// The basis that has to change when `p` is found outside the current
    /// answer: the smallest of the sets containing `p` that still encloses
    /// everything the old basis did. nil means floating point has produced a
    /// configuration with no valid basis, and the caller falls back.
    private static func extendBasis(_ basis: [PackedCircle], _ p: PackedCircle) -> [PackedCircle]? {
        if enclosesWeakAll(p, basis) { return [p] }

        for i in basis.indices {
            if enclosesNot(p, basis[i]),
               enclosesWeakAll(encloseBasis2(basis[i], p), basis) {
                return [basis[i], p]
            }
        }

        guard basis.count >= 2 else { return nil }
        for i in 0..<(basis.count - 1) {
            for j in (i + 1)..<basis.count {
                if enclosesNot(encloseBasis2(basis[i], basis[j]), p),
                   enclosesNot(encloseBasis2(basis[i], p), basis[j]),
                   enclosesNot(encloseBasis2(basis[j], p), basis[i]),
                   enclosesWeakAll(encloseBasis3(basis[i], basis[j], p), basis) {
                    return [basis[i], basis[j], p]
                }
            }
        }
        return nil
    }

    private static func encloseBasis(_ basis: [PackedCircle]) -> PackedCircle {
        switch basis.count {
        case 1: basis[0]
        case 2: encloseBasis2(basis[0], basis[1])
        case 3: encloseBasis3(basis[0], basis[1], basis[2])
        default: PackedCircle(x: 0, y: 0, r: 0)
        }
    }

    /// The circle through the two far sides of `a` and `b`, along the line
    /// joining their centres.
    private static func encloseBasis2(_ a: PackedCircle, _ b: PackedCircle) -> PackedCircle {
        let dx = b.x - a.x, dy = b.y - a.y, dr = b.r - a.r
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else {
            return PackedCircle(x: a.x, y: a.y, r: max(a.r, b.r))
        }
        return PackedCircle(x: (a.x + b.x + dx / distance * dr) / 2,
                            y: (a.y + b.y + dy / distance * dr) / 2,
                            r: (distance + a.r + b.r) / 2)
    }

    /// The circle internally tangent to all three, found by writing the two
    /// tangency conditions as linear equations in the centre and solving the
    /// resulting quadratic for the radius.
    private static func encloseBasis3(_ a: PackedCircle, _ b: PackedCircle,
                                      _ c: PackedCircle) -> PackedCircle {
        let a2 = a.x - b.x, a3 = a.x - c.x
        let b2 = a.y - b.y, b3 = a.y - c.y
        let c2 = b.r - a.r, c3 = c.r - a.r
        let d1 = a.x * a.x + a.y * a.y - a.r * a.r
        let d2 = d1 - b.x * b.x - b.y * b.y + b.r * b.r
        let d3 = d1 - c.x * c.x - c.y * c.y + c.r * c.r
        let ab = a3 * b2 - a2 * b3
        // Collinear centres: the three-circle case degenerates and the answer is
        // whichever pair is widest apart. Falling back rather than dividing by
        // zero, because the caller repairs the radius but not a NaN centre.
        guard ab != 0, ab.isFinite else {
            let ab2 = encloseBasis2(a, b), ac2 = encloseBasis2(a, c), bc2 = encloseBasis2(b, c)
            return [ab2, ac2, bc2].max { $0.r < $1.r } ?? ab2
        }
        let xa = (b2 * d3 - b3 * d2) / (ab * 2) - a.x
        let xb = (b3 * c2 - b2 * c3) / ab
        let ya = (a3 * d2 - a2 * d3) / (ab * 2) - a.y
        let yb = (a2 * c3 - a3 * c2) / ab
        let qa = xb * xb + yb * yb - 1
        let qb = 2 * (a.r + xa * xb + ya * yb)
        let qc = xa * xa + ya * ya - a.r * a.r
        let radius: Double
        if abs(qa) > 1e-6 {
            let discriminant = qb * qb - 4 * qa * qc
            guard discriminant >= 0 else { return encloseBasis2(a, b) }
            radius = -(qb + discriminant.squareRoot()) / (2 * qa)
        } else {
            guard qb != 0 else { return encloseBasis2(a, b) }
            radius = -qc / qb
        }
        return PackedCircle(x: a.x + xa + xb * radius,
                            y: a.y + ya + yb * radius,
                            r: radius)
    }
}
