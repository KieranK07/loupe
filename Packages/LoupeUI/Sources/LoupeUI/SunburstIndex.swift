import CoreGraphics
import Foundation
import LoupeCore

/// A wedge's address: which ring, and how far round that ring.
///
/// Focus and hover are tracked by position rather than by `Wedge.id`. The
/// contract does promise every wedge a distinct ref — an aggregate borrows the
/// ref of the largest sibling it swallowed — but a position is unambiguous
/// without depending on that promise, and it is also what the navigator needs:
/// "the wedge next to this one" is an offset, not an identity.
public struct SunburstPosition: Sendable, Hashable {
    public let ring: Int
    /// Index within the ring, in ascending `startAngle` order.
    public let offset: Int

    public init(ring: Int, offset: Int) {
        self.ring = ring
        self.offset = offset
    }
}

public enum SunburstHit: Sendable, Hashable {
    /// The centre disc — the focus node, and the zoom-out target.
    case centre
    case wedge(SunburstPosition)
    /// Past the outer ring, or in a ring with no wedges.
    case none
}

/// A `SunburstLayout` arranged for drawing, hit testing and navigation.
///
/// Built once per layout, never per frame. Everything downstream — the renderer,
/// the binary-search hit test, the keyboard navigator, the accessibility roster —
/// reads this one ordering, so they cannot disagree about what is adjacent to what.
public struct SunburstIndex: Sendable {
    public let generation: UInt64
    public let focus: NodeRef
    public let focusName: String
    public let focusPath: String
    public let breadcrumb: [Breadcrumb]
    public let totalPhysicalBytes: UInt64
    public let totalLogicalBytes: UInt64
    public let scannedAt: Date
    public let isComplete: Bool

    /// Sorted by `(ring, startAngle)`. Iterating in order draws inner rings
    /// first, which is also the order the eye reads the chart in.
    public let wedges: [Wedge]
    /// `ringRanges[r]` slices `wedges` down to ring `r`.
    public let ringRanges: [Range<Int>]

    private let positionByNode: [UInt32: SunburstPosition]

    public var ringCount: Int { ringRanges.count }
    public var isEmpty: Bool { wedges.isEmpty }

    public init(_ layout: SunburstLayout) {
        generation = layout.generation
        focus = layout.focus
        focusPath = layout.focusPath
        breadcrumb = layout.breadcrumb
        totalPhysicalBytes = layout.totalPhysicalBytes
        totalLogicalBytes = layout.totalLogicalBytes
        scannedAt = layout.scannedAt
        isComplete = layout.isComplete
        focusName = layout.breadcrumb.last?.name
            ?? layout.focusPath.split(separator: "/").last.map(String.init)
            ?? "All items"

        // The projector already emits ring-major, angle-ascending order, and a
        // layout arrives up to ten times a second during a scan — so check
        // before paying for a sort of several thousand elements.
        let source = layout.wedges
        var ordered = source
        if !Self.isOrdered(source) {
            ordered.sort { a, b in
                a.ring == b.ring ? a.startAngle < b.startAngle : a.ring < b.ring
            }
        }
        wedges = ordered

        var ranges: [Range<Int>] = []
        var positions: [UInt32: SunburstPosition] = [:]
        positions.reserveCapacity(ordered.count)
        var i = 0
        while i < ordered.count {
            let ring = Int(ordered[i].ring)
            // Rings the projector skipped entirely still need a slot, otherwise
            // `ringRanges[r]` stops meaning "ring r".
            while ranges.count < ring { ranges.append(i..<i) }
            var j = i
            while j < ordered.count, Int(ordered[j].ring) == ring {
                // First writer wins. The contract promises distinct refs, but
                // a duplicate must degrade into "the later wedge is not
                // findable by ref" rather than silently retargeting the first.
                let key = ordered[j].id
                if positions[key] == nil {
                    positions[key] = SunburstPosition(ring: ring, offset: j - i)
                }
                j += 1
            }
            ranges.append(i..<j)
            i = j
        }
        ringRanges = ranges
        positionByNode = positions
    }

    private static func isOrdered(_ wedges: [Wedge]) -> Bool {
        var previous: Wedge?
        for wedge in wedges {
            if let p = previous {
                if wedge.ring < p.ring { return false }
                if wedge.ring == p.ring, wedge.startAngle < p.startAngle { return false }
            }
            previous = wedge
        }
        return true
    }

    // MARK: - Lookup

    public subscript(position: SunburstPosition) -> Wedge? {
        guard ringRanges.indices.contains(position.ring) else { return nil }
        let range = ringRanges[position.ring]
        let i = range.lowerBound + position.offset
        guard position.offset >= 0, i < range.upperBound else { return nil }
        return wedges[i]
    }

    public func wedges(inRing ring: Int) -> ArraySlice<Wedge> {
        guard ringRanges.indices.contains(ring) else { return wedges[0..<0] }
        return wedges[ringRanges[ring]]
    }

    public func count(inRing ring: Int) -> Int {
        ringRanges.indices.contains(ring) ? ringRanges[ring].count : 0
    }

    /// Where a node sits now, so keyboard focus survives the next layout
    /// arriving mid-scan and the wedges shuffling under it.
    public func position(ofNode node: NodeRef) -> SunburstPosition? {
        positionByNode[node.rawValue]
    }

    // MARK: - Angular search

    /// The wedge in `ring` covering `angle`, by binary search. O(log n).
    ///
    /// This is the hot path — it runs on every pointer move over a chart that
    /// can hold six thousand wedges — so it must never touch a `CGPath`.
    ///
    /// Three probes rather than one, because the seam is not free. The probe
    /// angle is normalised into `[0, 2π)`, but a ring's own angles need not be:
    /// the contract only promises they are sorted, strictly nested inside their
    /// parent and gapless, so a ring's last wedge may end past 2π, and in
    /// principle a whole ring may sit a turn away from where the probe landed.
    /// Whole-turn shifts of the probe cover every such case, and none of them
    /// can produce a false positive, because a wedge is at most one turn wide.
    public func position(inRing ring: Int, atAngle angle: Double) -> SunburstPosition? {
        guard ringRanges.indices.contains(ring) else { return nil }
        let range = ringRanges[ring]
        guard !range.isEmpty else { return nil }
        let theta = SunburstAngle.normalized(angle)

        // Spelled out rather than looped over an array literal: this runs per
        // pointer move and must not allocate.
        if let found = search(range, theta) {
            return SunburstPosition(ring: ring, offset: found - range.lowerBound)
        }
        if let found = search(range, theta + SunburstAngle.fullTurn) {
            return SunburstPosition(ring: ring, offset: found - range.lowerBound)
        }
        if let found = search(range, theta - SunburstAngle.fullTurn) {
            return SunburstPosition(ring: ring, offset: found - range.lowerBound)
        }
        return nil
    }

    /// The one wedge in `range` that can contain `theta`, or nil.
    ///
    /// The ring is sorted by `startAngle` and its wedges do not overlap, so the
    /// only candidate is the last wedge starting at or before `theta`. Finding
    /// it is a lower-bound partition; confirming it is one comparison.
    private func search(_ range: Range<Int>, _ theta: Double) -> Int? {
        var lo = range.lowerBound
        var hi = range.upperBound
        while lo < hi {
            let mid = lo &+ (hi &- lo) / 2
            if wedges[mid].startAngle <= theta { lo = mid &+ 1 } else { hi = mid }
        }
        guard lo > range.lowerBound else { return nil }
        let candidate = lo - 1
        let wedge = wedges[candidate]
        // Half-open, and deliberately so: a point exactly on a shared edge
        // belongs to the wedge that starts there. Adjacent wedges therefore tile
        // the ring with no point owned twice and none owned by nobody.
        return theta >= wedge.startAngle && theta < wedge.endAngle ? candidate : nil
    }

    public func wedge(inRing ring: Int, atAngle angle: Double) -> Wedge? {
        position(inRing: ring, atAngle: angle).flatMap { self[$0] }
    }

    /// Point to wedge, analytically: radius picks the ring, one binary search
    /// picks the wedge. No path containment anywhere in this call.
    public func hit(at point: CGPoint, metrics: SunburstMetrics) -> SunburstHit {
        let r = metrics.radius(at: point)
        if r < metrics.centreRadius { return .centre }
        guard let ring = metrics.ring(atRadius: r) else { return .none }
        guard let position = position(inRing: ring, atAngle: metrics.angle(at: point)) else { return .none }
        return .wedge(position)
    }
}
