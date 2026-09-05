import Foundation
import LoupeCore

/// Turns an arena plus a focus node into a bounded `SunburstLayout`.
///
/// The arena may hold four million nodes; a layout holds a few thousand wedges.
/// This type is the whole of that reduction, and it is the only reason the main
/// actor can render a scan in flight without ever touching the tree.
///
/// A projection is a pure function of (arena, focus, basis). It caches nothing and
/// owns nothing mutable, so it can run on any thread — including concurrently with
/// the walker still appending to the arena, which is safe because arena structure
/// is append-only and subtree totals only ever grow.
public struct SunburstProjector: Sendable {
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    /// Deepest ring index emitted. `ring` is an *annulus index*: ring 0 is the
    /// first band of arcs outside the centre disc, holding the focus's direct
    /// children. The focus itself is the disc and is never a wedge, so it carries
    /// no ring number. `maximumRings` of 8 therefore means eight bands, 0...7.
    static let deepestRing: UInt8 =
        SunburstGeometry.maximumRings > 0 ? SunburstGeometry.maximumRings - 1 : 0

    /// Full circle, in the radians the contract speaks.
    static let fullCircle: Double = 2 * .pi

    public func project(arena: Arena, focus: NodeRef, basis: SizeBasis,
                        generation: UInt64, scannedAt: Date,
                        isComplete: Bool) -> SunburstLayout {

        func bare(focusPath: String = "", breadcrumb: [Breadcrumb] = [],
                  physical: UInt64 = 0, logical: UInt64 = 0) -> SunburstLayout {
            SunburstLayout(generation: generation, focus: focus, focusPath: focusPath,
                           breadcrumb: breadcrumb, wedges: [],
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
        // children, so there is nothing to lay out around it.
        guard focus.isDirectory else {
            let node = arena.files[slot]
            let bytes = contributedBytes(node)
            return bare(focusPath: focusPath, breadcrumb: crumbs,
                        physical: bytes.physical, logical: bytes.logical)
        }

        var wedges: [Wedge] = []
        var totalPhysical = arena.dirs[slot].subtreePhysicalBytes
        var totalLogical = arena.dirs[slot].subtreeLogicalBytes

        arena.files.withUnsafeBufferPointer { files in
            arena.dirs.withUnsafeBufferPointer { dirs in
                arena.names.withUnsafeBufferPointer { names in
                    let view = ArenaView(files: files, dirs: dirs, names: names)

                    // Mid-walk a subdirectory's bytes have not folded into its
                    // parent yet, so the focus's stored roll-up lags what its
                    // children already know. The children are the more current
                    // number and the one the geometry is normalised by, so the
                    // header must quote the same figure or the percentages the
                    // user reads off the chart will not add up.
                    let observed = view.childTotals(of: UInt32(slot))
                    totalPhysical = max(totalPhysical, observed.physical)
                    totalLogical = max(totalLogical, observed.logical)

                    wedges = layOut(focus: UInt32(slot), basis: basis, view: view)
                }
            }
        }

        return SunburstLayout(generation: generation, focus: focus, focusPath: focusPath,
                              breadcrumb: crumbs, wedges: wedges,
                              totalPhysicalBytes: totalPhysical,
                              totalLogicalBytes: totalLogical,
                              scannedAt: scannedAt, isComplete: isComplete)
    }

    // MARK: - Breadcrumb



    // MARK: - Layout

    /// One directory waiting to have its children laid out inside its own arc.
    private struct Frame {
        var dir: UInt32
        var start: Double
        var end: Double
        var seed: UInt16
    }

    /// Breadth-first, one ring at a time, so the wedge budget can be spent on
    /// whole rings — see the backstop below.
    private func layOut(focus: UInt32, basis: SizeBasis, view: ArenaView) -> [Wedge] {
        var wedges: [Wedge] = []
        var frontier: [Frame] = [Frame(dir: focus, start: 0, end: Self.fullCircle, seed: 0)]
        var nextFrontier: [Frame] = []
        var ringWedges: [Wedge] = []
        var kept: [SizedChild] = []

        var ring: UInt8 = 0
        while ring <= Self.deepestRing, !frontier.isEmpty {
            ringWedges.removeAll(keepingCapacity: true)
            nextFrontier.removeAll(keepingCapacity: true)
            let canDescend = ring < Self.deepestRing

            for frame in frontier {
                expand(frame, ring: ring, mintsSeeds: ring == 0, canDescend: canDescend,
                       basis: basis, view: view, kept: &kept,
                       into: &ringWedges, next: &nextFrontier)
            }

            if ringWedges.isEmpty { break }

            // The angular cull already caps a single ring at about 1028 arcs
            // (2π / 0.35°), so this only fires on a tree that is broad *and* deep.
            // When it does, the whole outermost ring goes: every ring that is drawn
            // stays complete. Truncating mid-ring instead would leave a wedge-shaped
            // hole in the chart with nothing to tell the user it was not real.
            if wedges.count + ringWedges.count > SunburstGeometry.maximumWedges { break }

            wedges.append(contentsOf: ringWedges)
            swap(&frontier, &nextFrontier)
            ring &+= 1
        }
        return wedges
    }

    /// Lays one directory's children out inside `frame`'s arc.
    private func expand(_ frame: Frame, ring: UInt8, mintsSeeds: Bool, canDescend: Bool,
                        basis: SizeBasis, view: ArenaView, kept: inout [SizedChild],
                        into wedges: inout [Wedge], next: inout [Frame]) {
        let span = frame.end - frame.start
        guard span > 0 else { return }

        let fileRange = view.fileChildren(of: frame.dir)
        let dirRange = view.directoryChildren(of: frame.dir)

        // Pass one: the denominator. Deliberately the children's sum rather than
        // the directory's own rolled-up total, for the same reason as the focus
        // header above — mid-walk the parent's total lags its children, and
        // normalising by it would leave a growing empty gap in the ring.
        var total: UInt64 = 0
        for slot in fileRange {
            total &+= sizedChild(file: slot, view.files[Int(slot)], basis: basis).size
        }
        for slot in dirRange {
            total &+= sizedChild(directory: slot, view.dirs[Int(slot)], basis: basis).size
        }
        // A zero-byte subtree has no proportions to compute. Bailing here is what
        // keeps the division below from ever producing NaN, and it is also the
        // honest answer: there is nothing to show.
        guard total > 0 else { return }
        let totalBytes = Double(total)

        // Pass two: partition. A child earns a wedge when its share of the parent's
        // arc clears the minimum sweep. Rearranged into bytes that is a single
        // comparison, so a directory with 200k children is partitioned in one linear
        // pass and only the survivors — at most ~1028 of them, and usually a handful
        // — are ever sorted. Sorting all 200k to then throw away 199k of them is the
        // obvious implementation and the one that misses the frame budget.
        let keepThreshold = totalBytes * SunburstGeometry.minimumSweepRadians / span

        kept.removeAll(keepingCapacity: true)
        var culled = CulledSiblings()

        for slot in fileRange {
            let child = sizedChild(file: slot, view.files[Int(slot)], basis: basis)
            if Double(child.size) >= keepThreshold { kept.append(child) }
            else { culled.absorb(child, view.names) }
        }
        for slot in dirRange {
            let child = sizedChild(directory: slot, view.dirs[Int(slot)], basis: basis)
            if Double(child.size) >= keepThreshold { kept.append(child) }
            else { culled.absorb(child, view.names) }
        }

        kept.sort { childSortsBefore($0, $1, view.names) }

        var cursor = frame.start
        var running = 0.0
        let lastIndex = kept.count - 1

        for (index, child) in kept.enumerated() {
            running += Double(child.size)
            // Each boundary is computed from a running *fraction* of the parent's
            // span rather than by accumulating per-child sweeps, so rounding cannot
            // drift the ring out of alignment across a thousand siblings. When
            // nothing was culled the last boundary is snapped to the parent's end so
            // the children fill the arc exactly, not to within an ulp.
            var end = frame.start + span * (running / totalBytes)
            if index == lastIndex, culled.size == 0 { end = frame.end }

            // A wedge's colour key is the index of its top-level ancestor under the
            // current focus; everything deeper inherits it. That is what keeps a
            // subtree one hue from the centre outwards, and keeps the hue the same
            // between two ticks of a running scan.
            let seed = mintsSeeds ? UInt16(clamping: index) : frame.seed

            wedges.append(Wedge(node: child.ref, startAngle: cursor, endAngle: end,
                                ring: ring,
                                physicalBytes: child.physicalBytes,
                                logicalBytes: child.logicalBytes,
                                itemCount: child.itemCount,
                                name: view.name(offset: child.nameOffset,
                                                length: child.nameLength),
                                kind: child.isIncomplete ? .stillScanning : .real,
                                colorSeed: seed))

            if canDescend, child.ref.isDirectory {
                next.append(Frame(dir: child.ref.slot, start: cursor, end: end, seed: seed))
            }
            cursor = end
        }

        // The culled siblings are the tail of the descending order by construction —
        // sweep is monotonic in size — so their combined arc is exactly what is left
        // between the last kept wedge and the parent's end. One wedge, drawn once,
        // instead of several thousand sub-pixel arcs nobody can see or click.
        // Siblings that are culled only because they hold nothing get counted into
        // no aggregate at all: a zero-width wedge would break `endAngle > startAngle`
        // and give hit testing something impossible to land on.
        if culled.size > 0, let representative = culled.representative, frame.end > cursor {
            wedges.append(Wedge(node: representative.ref, startAngle: cursor,
                                endAngle: frame.end, ring: ring,
                                physicalBytes: culled.physicalBytes,
                                logicalBytes: culled.logicalBytes,
                                itemCount: UInt32(clamping: culled.itemCount),
                                name: aggregatedLabel(count: culled.count),
                                kind: .aggregated(count: culled.count),
                                colorSeed: mintsSeeds ? UInt16(clamping: kept.count) : frame.seed))
        }
    }
}

// MARK: - Borrowed arena

/// Borrowed views of the three arenas, taken once per projection.
///
/// A projection of a broad tree touches tens of thousands of child records, ten
/// times a second, for the length of a scan. `ContiguousArray`'s bounds-checked
/// subscript is not free at that rate, and the arena cannot mutate underneath a
/// single `project` call, so the pointers are taken once at the top and passed
/// down rather than re-derived per directory.

