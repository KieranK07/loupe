import Foundation
import LoupeCore

/// Keyboard movement over a sunburst, computed from layout geometry alone.
///
/// The measured maximum depth on a real machine is 25 levels; driving that with
/// a pointer is miserable, so this is a headline feature rather than a
/// courtesy. It is a separate value type — not view state — precisely so every
/// edge (the seam, ring 0, the outermost ring, the last sibling) is testable
/// without rendering anything.
///
/// Note what it does *not* need: any access to the tree. A ring is angle-sorted,
/// so siblings are array neighbours; a child's angular span is nested inside its
/// parent's, so containment recovers the parent/child relation the projector
/// already encoded in the geometry.
public struct SunburstNavigator: Sendable {
    public enum Move: Sendable, Hashable, CaseIterable {
        /// Left arrow: the wedge anticlockwise of this one, wrapping at the seam.
        case previousSibling
        /// Right arrow: the wedge clockwise of this one, wrapping at the seam.
        case nextSibling
        /// Down arrow: the largest wedge one ring out that sits inside this span.
        case largestChild
        /// Up arrow: the wedge one ring in whose span covers this one's midpoint.
        case parent
    }

    public let index: SunburstIndex

    public init(index: SunburstIndex) {
        self.index = index
    }

    /// Where the keyboard should land when the chart is focused with nothing
    /// selected: the biggest thing in the innermost ring, which is what the eye
    /// went to anyway.
    public func initialFocus() -> SunburstPosition? {
        largest(inRing: 0)
    }

    public func largest(inRing ring: Int) -> SunburstPosition? {
        let range = index.ringRanges.indices.contains(ring) ? index.ringRanges[ring] : nil
        guard let range, !range.isEmpty else { return nil }
        var best = range.lowerBound
        for i in range where index.wedges[i].sweep > index.wedges[best].sweep { best = i }
        return SunburstPosition(ring: ring, offset: best - range.lowerBound)
    }

    public func destination(from position: SunburstPosition, move: Move) -> SunburstPosition? {
        switch move {
        case .previousSibling: sibling(from: position, step: -1)
        case .nextSibling: sibling(from: position, step: 1)
        case .largestChild: largestChild(of: position)
        case .parent: parent(of: position)
        }
    }

    // MARK: - Siblings

    /// Siblings are ring neighbours, and the ring is a circle, so the ends join.
    /// Arrowing off the last wedge lands on the first rather than dead-ending —
    /// the same thing the chart does visually at 12 o'clock.
    private func sibling(from position: SunburstPosition, step: Int) -> SunburstPosition? {
        let count = index.count(inRing: position.ring)
        guard count > 0, index[position] != nil else { return nil }
        let next = ((position.offset + step) % count + count) % count
        return SunburstPosition(ring: position.ring, offset: next)
    }

    // MARK: - Parent

    /// The parent is the wedge one ring in that covers this wedge's midpoint.
    ///
    /// The midpoint rather than an edge: edges are shared with siblings, and a
    /// half-open span would hand a wedge sitting exactly on a parent boundary to
    /// whichever neighbour sorts first. A wedge's midpoint is strictly interior
    /// to its parent, so it is never ambiguous.
    public func parent(of position: SunburstPosition) -> SunburstPosition? {
        guard position.ring > 0, let wedge = index[position] else { return nil }
        let midpoint = wedge.startAngle + wedge.sweep / 2
        return index.position(inRing: position.ring - 1, atAngle: midpoint)
    }

    /// The chain from this wedge's parent inwards to ring 0. Used to light up
    /// the ancestry on hover, which is what makes a sunburst readable at depth.
    public func ancestors(of position: SunburstPosition) -> [SunburstPosition] {
        var chain: [SunburstPosition] = []
        var current = position
        // Bounded by the ring count, and layouts are capped at
        // `SunburstGeometry.maximumRings`, so this cannot run away even if a
        // malformed layout produced a containment cycle.
        while let next = parent(of: current), chain.count <= index.ringCount {
            chain.append(next)
            current = next
        }
        return chain
    }

    // MARK: - Children

    public func largestChild(of position: SunburstPosition) -> SunburstPosition? {
        children(of: position).max { a, b in
            (index[a]?.sweep ?? 0) < (index[b]?.sweep ?? 0)
        }
    }

    /// Every wedge one ring out whose span nests inside this one's.
    ///
    /// Found by binary search plus a short forward walk rather than a scan of
    /// the whole ring: a ring can hold thousands of wedges and only a handful
    /// belong to any one parent.
    public func children(of position: SunburstPosition) -> [SunburstPosition] {
        guard let parent = index[position] else { return [] }
        let ring = position.ring + 1
        guard index.ringRanges.indices.contains(ring) else { return [] }
        let range = index.ringRanges[ring]
        guard !range.isEmpty else { return [] }

        let tolerance = SunburstAngle.containmentTolerance
        var found: [SunburstPosition] = []

        // First index in the child ring whose startAngle is at or after the
        // parent's leading edge.
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if index.wedges[mid].startAngle < parent.startAngle - tolerance { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < range.upperBound, index.wedges[i].startAngle < parent.endAngle + tolerance {
            if isContained(index.wedges[i], in: parent) {
                found.append(SunburstPosition(ring: ring, offset: i - range.lowerBound))
            }
            i += 1
        }

        // If the parent runs past 2π, part of its span lives at the head of the
        // child ring, where the startAngles sort before everything the walk
        // above saw. Sweep that head separately.
        if parent.endAngle > SunburstAngle.fullTurn {
            var j = range.lowerBound
            while j < range.upperBound,
                  index.wedges[j].startAngle + SunburstAngle.fullTurn < parent.endAngle + tolerance {
                if isContained(index.wedges[j], in: parent) {
                    let candidate = SunburstPosition(ring: ring, offset: j - range.lowerBound)
                    if !found.contains(candidate) { found.append(candidate) }
                }
                j += 1
            }
        }
        return found
    }

    /// Containment, compared in the parent's own angular frame.
    ///
    /// Lifting into `[parent.start - ε, parent.start - ε + 2π)` is what makes
    /// the seam a non-event: a parent spanning 6.20 → 6.30 rad and a child at
    /// 0.02 rad are the same place on screen but nothing alike as raw numbers.
    /// The ε offset is part of the lift, not applied afterwards — a child whose
    /// start undershoots its parent's by an ulp must lift to *just before* the
    /// parent, not all the way round to just before the next turn.
    func isContained(_ child: Wedge, in parent: Wedge) -> Bool {
        let tolerance = SunburstAngle.containmentTolerance
        let base = parent.startAngle - tolerance
        let start = SunburstAngle.lifted(child.startAngle, into: base)
        return start >= parent.startAngle - tolerance
            && start + child.sweep <= parent.endAngle + tolerance
    }
}
