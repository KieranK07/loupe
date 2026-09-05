import CoreGraphics
import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Hit testing is analytic and exact")
struct SunburstHitTestTests {
    @Test("Every wedge owns its own start angle, and none owns its end")
    func exactBoundaries() {
        let index = SunburstIndex(Fixture.layout(levels: [[3, 1, 2, 5, 4]]))
        let ring = index.ringRanges[0]
        for i in ring {
            let wedge = index.wedges[i]
            let offset = i - ring.lowerBound

            let atStart = index.position(inRing: 0, atAngle: wedge.startAngle)
            #expect(atStart == SunburstPosition(ring: 0, offset: offset),
                    "wedge \(offset) does not own its own start angle")

            // The end belongs to the next wedge round, wrapping at the seam.
            let atEnd = index.position(inRing: 0, atAngle: wedge.endAngle)
            let expected = SunburstPosition(ring: 0, offset: (offset + 1) % ring.count)
            #expect(atEnd == expected,
                    "the edge after wedge \(offset) went to \(String(describing: atEnd))")
        }
    }

    @Test("The centre disc is the centre disc, and beyond the rim is nothing")
    func radialRegions() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1, 1, 1], [1, 2]]))
        let metrics = Fixture.metrics(ringCount: index.ringCount)
        let c = metrics.center

        #expect(index.hit(at: c, metrics: metrics) == .centre)
        #expect(index.hit(at: CGPoint(x: c.x, y: c.y - (metrics.centreRadius - 0.5)),
                          metrics: metrics) == .centre)

        // Exactly on the disc's edge is ring 0 — the disc is half-open outward,
        // the same rule the angular spans use.
        if case .wedge(let position) = index.hit(at: CGPoint(x: c.x, y: c.y - metrics.centreRadius),
                                                 metrics: metrics) {
            #expect(position.ring == 0)
        } else {
            Issue.record("the centre disc's outer edge should be ring 0")
        }

        #expect(index.hit(at: CGPoint(x: c.x, y: c.y - metrics.outerRadius),
                          metrics: metrics) == .none)
        #expect(index.hit(at: CGPoint(x: c.x, y: c.y - metrics.outerRadius - 40),
                          metrics: metrics) == .none)
        #expect(index.hit(at: CGPoint(x: c.x + 4000, y: c.y), metrics: metrics) == .none)
    }

    @Test("Radius picks the right ring, including the last one")
    func ringSelection() {
        let metrics = Fixture.metrics(ringCount: 4)
        #expect(metrics.ring(atRadius: metrics.centreRadius - 0.001) == nil)
        #expect(metrics.ring(atRadius: metrics.centreRadius) == 0)
        #expect(metrics.ring(atRadius: metrics.centreRadius + metrics.ringThickness) == 1)
        #expect(metrics.ring(atRadius: metrics.outerRadius - 0.001) == 3)
        #expect(metrics.ring(atRadius: metrics.outerRadius) == nil)
    }

    /// The 12 o'clock case, called out on its own because it is where a
    /// normalisation mistake hides: a point a hair anticlockwise of vertical
    /// must land in the ring's last wedge, not in nothing.
    @Test("A point just anticlockwise of 12 o'clock lands in the last wedge")
    func twelveOClockSeam() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1, 1, 1, 1, 1]]))
        let metrics = Fixture.metrics(ringCount: index.ringCount)
        let c = metrics.center
        let radius = metrics.centreRadius + metrics.ringThickness / 2
        let lastOffset = index.count(inRing: 0) - 1

        let justBefore = CGPoint(x: c.x - 0.05, y: c.y - radius)
        #expect(index.hit(at: justBefore, metrics: metrics)
            == .wedge(SunburstPosition(ring: 0, offset: lastOffset)))

        let justAfter = CGPoint(x: c.x + 0.05, y: c.y - radius)
        #expect(index.hit(at: justAfter, metrics: metrics)
            == .wedge(SunburstPosition(ring: 0, offset: 0)))

        // Dead on 12 o'clock is the start of wedge zero.
        #expect(index.hit(at: CGPoint(x: c.x, y: c.y - radius), metrics: metrics)
            == .wedge(SunburstPosition(ring: 0, offset: 0)))
    }

    @Test("A sub-ulp offset from 12 o'clock still hits something")
    func subUlpOffsetStillHits() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1, 1, 1]]))
        let metrics = Fixture.metrics(ringCount: index.ringCount)
        let c = metrics.center
        let radius = metrics.centreRadius + metrics.ringThickness / 2
        for exponent in 6...14 {
            let nudge = pow(10.0, -Double(exponent))
            let hit = index.hit(at: CGPoint(x: c.x - nudge, y: c.y - radius), metrics: metrics)
            #expect(hit != .none, "10^-\(exponent) left of vertical hit nothing")
        }
    }

    @Test("Binary search agrees with a brute-force scan over a few thousand wedges",
          arguments: [0.0, 1.7, 6.0])
    func matchesBruteForce(startAt: Double) {
        let index = SunburstIndex(Fixture.randomRing(count: 3000, seed: 0xA11CE, startAt: startAt))
        #expect(index.count(inRing: 0) == 3000)

        var rng = SplitMix64(seed: 0xBEEF)
        for _ in 0..<6_000 {
            let angle = Double.random(in: -12.0...12.0, using: &rng)
            let searched = index.position(inRing: 0, atAngle: angle)
            let scanned = index.bruteForcePosition(inRing: 0, atAngle: angle)
            #expect(searched == scanned,
                    "angle \(angle): search said \(String(describing: searched)), scan said \(String(describing: scanned))")
        }

        // And on every boundary, where off-by-one lives.
        for i in index.ringRanges[0] {
            for probe in [index.wedges[i].startAngle, index.wedges[i].endAngle] {
                #expect(index.position(inRing: 0, atAngle: probe)
                    == index.bruteForcePosition(inRing: 0, atAngle: probe))
            }
        }
    }

    @Test("Every angle in a gapless ring belongs to exactly one wedge")
    func ringIsTotal() {
        let index = SunburstIndex(Fixture.randomRing(count: 512, seed: 0xF00D))
        var rng = SplitMix64(seed: 7)
        for _ in 0..<20_000 {
            let angle = Double.random(in: 0..<SunburstAngle.fullTurn, using: &rng)
            #expect(index.position(inRing: 0, atAngle: angle) != nil,
                    "angle \(angle) belonged to no wedge")
        }
    }

    @Test("A ring the projector never emitted is empty, not a crash")
    func sparseRings() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1]]))
        #expect(index.position(inRing: 1, atAngle: 0.5) == nil)
        #expect(index.position(inRing: -1, atAngle: 0.5) == nil)
        #expect(index[SunburstPosition(ring: 0, offset: 99)] == nil)
        #expect(index[SunburstPosition(ring: 0, offset: -1)] == nil)

        let empty = SunburstIndex(.empty)
        #expect(empty.isEmpty)
        let emptyMetrics = Fixture.metrics(ringCount: 0)
        #expect(empty.hit(at: emptyMetrics.center, metrics: emptyMetrics) == .centre)
        #expect(empty.hit(at: .zero, metrics: emptyMetrics) == .none)
    }

    @Test("Point and angle round-trip through the contract's convention")
    func angleRoundTrip() {
        let metrics = Fixture.metrics(ringCount: 3)
        for degrees in stride(from: 0.0, to: 360.0, by: 7.0) {
            let angle = degrees * .pi / 180
            let point = metrics.point(radius: 120, angle: angle)
            #expect(abs(SunburstAngle.shortestDelta(from: angle, to: metrics.angle(at: point))) < 1e-9)
        }
        // 12 o'clock is straight up; a quarter turn clockwise is to the right.
        let up = metrics.point(radius: 100, angle: 0)
        #expect(abs(up.x - metrics.center.x) < 1e-9)
        #expect(up.y < metrics.center.y)
        let right = metrics.point(radius: 100, angle: .pi / 2)
        #expect(right.x > metrics.center.x)
        #expect(abs(right.y - metrics.center.y) < 1e-9)
    }
}
