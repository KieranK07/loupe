import CoreGraphics
import Foundation
import LoupeCore
@testable import LoupeUI

/// Deterministic 64-bit PRNG, so a failure is a failure every time and not a
/// story about which seed the machine felt like using.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixture {
    /// Build a layout by recursive subdivision.
    ///
    /// `levels[r]` is the list of weights every wedge in ring `r-1` is split by,
    /// with `levels[0]` splitting the full turn. The result satisfies the three
    /// invariants the projector declares — angle-sorted within a ring, strictly
    /// contained in the parent, gapless — because navigation and hit testing are
    /// only meaningful against a layout that does.
    ///
    /// The last child of every parent is snapped to the parent's exact end
    /// rather than being left where repeated addition put it. That is what a
    /// careful projector does, and it makes exact-boundary assertions honest.
    static func layout(levels: [[Double]],
                       startAt: Double = 0,
                       generation: UInt64 = 1,
                       focusSlot: UInt32 = 0,
                       breadcrumb: [Breadcrumb] = [Breadcrumb(node: .directory(0), name: "Data"),
                                                   Breadcrumb(node: .directory(1), name: "Users")],
                       isComplete: Bool = true,
                       kindForRing: (Int, Int) -> WedgeKind = { _, _ in .real },
                       nameForRing: (Int, Int, UInt32) -> String = { ring, child, slot in
                           "r\(ring)c\(child)-\(slot)"
                       }) -> SunburstLayout {
        var wedges: [Wedge] = []
        var slot: UInt32 = 100
        var parents: [(start: Double, end: Double, seed: UInt16)] =
            [(startAt, startAt + SunburstAngle.fullTurn, 0)]

        for (ringIndex, weights) in levels.enumerated() {
            var next: [(start: Double, end: Double, seed: UInt16)] = []
            let total = weights.reduce(0, +)
            for parent in parents {
                var cursor = parent.start
                for (childIndex, weight) in weights.enumerated() {
                    let isLast = childIndex == weights.count - 1
                    let span = (parent.end - parent.start) * weight / total
                    let end = isLast ? parent.end : cursor + span
                    let seed = ringIndex == 0 ? UInt16(childIndex) : parent.seed
                    let sweepFraction = (end - cursor) / SunburstAngle.fullTurn
                    wedges.append(Wedge(node: .directory(slot),
                                        startAngle: cursor,
                                        endAngle: end,
                                        ring: UInt8(ringIndex),
                                        physicalBytes: UInt64((sweepFraction * 1_000_000_000).rounded()),
                                        logicalBytes: UInt64((sweepFraction * 3_000_000_000).rounded()),
                                        itemCount: UInt32(childIndex + 1),
                                        name: nameForRing(ringIndex, childIndex, slot),
                                        kind: kindForRing(ringIndex, childIndex),
                                        colorSeed: seed))
                    next.append((cursor, end, seed))
                    slot += 1
                    cursor = end
                }
            }
            parents = next
        }

        return SunburstLayout(generation: generation,
                              focus: .directory(focusSlot),
                              focusPath: "/System/Volumes/Data/Users",
                              breadcrumb: breadcrumb,
                              wedges: wedges,
                              totalPhysicalBytes: 1_000_000_000,
                              totalLogicalBytes: 3_000_000_000,
                              scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              isComplete: isComplete)
    }

    /// A single ring of `count` wedges with pseudo-random widths, tiling exactly
    /// one turn from `startAt`. Used to check the binary search against a
    /// brute-force scan at a scale the search actually has to earn.
    static func randomRing(count: Int, seed: UInt64, startAt: Double = 0) -> SunburstLayout {
        var rng = SplitMix64(seed: seed)
        var weights: [Double] = []
        weights.reserveCapacity(count)
        for _ in 0..<count { weights.append(Double.random(in: 0.2...4.0, using: &rng)) }
        return layout(levels: [weights], startAt: startAt)
    }

    static func metrics(ringCount: Int) -> SunburstMetrics {
        SunburstMetrics(center: CGPoint(x: 400, y: 400), centreRadius: 80,
                        ringThickness: 40, ringCount: ringCount)
    }
}

extension SunburstIndex {
    /// Reference implementation: a linear scan with seam-aware containment.
    /// Deliberately as dumb as possible — its only job is to disagree with the
    /// binary search if the binary search is wrong.
    func bruteForcePosition(inRing ring: Int, atAngle angle: Double) -> SunburstPosition? {
        guard ringRanges.indices.contains(ring) else { return nil }
        let range = ringRanges[ring]
        let theta = SunburstAngle.normalized(angle)
        for i in range {
            let wedge = wedges[i]
            if SunburstAngle.span(wedge.startAngle, wedge.endAngle, contains: theta) {
                return SunburstPosition(ring: ring, offset: i - range.lowerBound)
            }
        }
        return nil
    }
}
