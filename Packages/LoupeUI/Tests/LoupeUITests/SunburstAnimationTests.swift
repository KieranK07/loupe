import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Zoom transition")
struct SunburstAnimationTests {
    private func wedge(slot: UInt32, start: Double, end: Double, ring: UInt8) -> Wedge {
        Wedge(node: .directory(slot), startAngle: start, endAngle: end, ring: ring,
              physicalBytes: 1024, logicalBytes: 2048, itemCount: 1,
              name: "n\(slot)", kind: .real, colorSeed: 0)
    }

    @Test("At the ends of the transition the geometry is exactly old and new")
    func endpointsAreExact() {
        let old = wedge(slot: 1, start: 0.2, end: 1.0, ring: 2)
        let new = wedge(slot: 1, start: 3.0, end: 5.0, ring: 0)

        let atStart = SunburstAnimation.interpolate(from: old, to: new, progress: 0)
        #expect(abs(atStart.startAngle - old.startAngle) < 1e-12)
        #expect(abs(atStart.endAngle - old.endAngle) < 1e-12)
        #expect(atStart.ring == 2)

        let atEnd = SunburstAnimation.interpolate(from: old, to: new, progress: 1)
        #expect(abs(atEnd.startAngle - new.startAngle) < 1e-12)
        #expect(abs(atEnd.endAngle - new.endAngle) < 1e-12)
        #expect(atEnd.ring == 0)
    }

    /// Lerping start and end independently would send a wedge that moves two
    /// hundredths of a turn across the seam almost all the way round backwards.
    @Test("A wedge crossing the seam takes the short way round")
    func seamCrossingTakesTheShortWay() {
        let old = wedge(slot: 1, start: 6.24, end: 6.28, ring: 0)
        let new = wedge(slot: 1, start: 0.02, end: 0.06, ring: 0)
        let mid = SunburstAnimation.interpolate(from: old, to: new, progress: 0.5)
        let travelled = abs(SunburstAngle.shortestDelta(from: old.startAngle, to: mid.startAngle))
        #expect(travelled < 0.05, "the wedge went the long way: \(mid.startAngle)")
        // Sweep stays put; only position moved.
        #expect(abs((mid.endAngle - mid.startAngle) - 0.04) < 1e-9)
    }

    /// The clamp is no longer at exactly 1 — a settle has to be able to carry a
    /// wedge past its target and back, or it is an ease-out wearing a hat. It is
    /// still a clamp: an animation driver that hands us 5 must not fling a wedge
    /// five turns round the chart, and the bound is the same one `settle` is
    /// tested to stay inside.
    @Test("Progress outside the overshoot band is clamped rather than extrapolated")
    func progressClamped() {
        let old = wedge(slot: 1, start: 0, end: 1, ring: 0)
        let new = wedge(slot: 1, start: 2, end: 3, ring: 1)
        #expect(SunburstAnimation.interpolate(from: old, to: new, progress: -5).ring == 0)
        let far = SunburstAnimation.interpolate(from: old, to: new, progress: 5)
        #expect(far.ring == SunburstAnimation.overshootCeiling)
        #expect(far.ring <= 1.2)
        // And the size still stops dead on arrival however far the clock runs.
        #expect(abs((far.endAngle - far.startAngle) - new.sweep) < 1e-12)
    }

    @Test("Survivors are matched by id, and everything else fades")
    func survivorsAppearanceAndDeparture() {
        let before = SunburstIndex(Fixture.layout(levels: [[1, 1, 1]], generation: 1))
        // Same slots for the first two, a third that is new, and one dropped.
        var wedges = Array(before.wedges.prefix(2)).map {
            wedge(slot: $0.node.slot, start: $0.startAngle + 1.0, end: $0.endAngle + 1.0, ring: 1)
        }
        wedges.append(wedge(slot: 999, start: 4.0, end: 5.0, ring: 0))
        let after = SunburstIndex(SunburstLayout(
            generation: 2, focus: .directory(1), focusPath: "/x", breadcrumb: [],
            wedges: wedges, totalPhysicalBytes: 10, totalLogicalBytes: 10,
            scannedAt: Date(), isComplete: true))

        let early = SunburstAnimation.frames(from: before, to: after, progress: 0.05)
        let survivors = early.filter { $0.opacity == 1 }
        #expect(survivors.count == 2)
        // The newcomer has not begun to arrive yet.
        #expect(early.contains { $0.wedge.node.slot == 999 && $0.opacity == 0 })
        // And the dropped wedge is still on its way out.
        #expect(early.contains { $0.wedge.node.slot == before.wedges[2].node.slot && $0.opacity > 0 })

        let late = SunburstAnimation.frames(from: before, to: after, progress: 0.95)
        #expect(!late.contains { $0.wedge.node.slot == before.wedges[2].node.slot })
        #expect(late.first { $0.wedge.node.slot == 999 }?.opacity ?? 0 > 0.8)

        let done = SunburstAnimation.frames(from: before, to: after, progress: 1)
        #expect(done.count == after.wedges.count)
        #expect(done.allSatisfy { $0.opacity == 1 })
    }

    @Test("Frames stay in ring-then-angle order so inner rings draw first")
    func framesAreOrdered() {
        let before = SunburstIndex(Fixture.layout(levels: [[2, 1, 3], [1, 1]], generation: 1))
        let after = SunburstIndex(Fixture.layout(levels: [[1, 4], [2, 1, 1]],
                                                 startAt: 0.7, generation: 2))
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let frames = SunburstAnimation.frames(from: before, to: after, progress: progress)
            for (a, b) in zip(frames, frames.dropFirst()) {
                #expect(a.ring < b.ring || (a.ring == b.ring && a.startAngle <= b.startAngle))
            }
        }
    }

    @Test("With no previous layout the frames are simply the current ones")
    func steadyState() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 2]]))
        let frames = SunburstAnimation.frames(from: nil, to: index, progress: 0.3)
        #expect(frames.count == index.wedges.count)
        for (frame, wedge) in zip(frames, index.wedges) {
            #expect(frame.startAngle == wedge.startAngle)
            #expect(frame.endAngle == wedge.endAngle)
            #expect(frame.ring == Double(wedge.ring))
            #expect(frame.opacity == 1)
        }
    }

    @Test("Reduce Motion means no animation at all")
    func reduceMotion() {
        #expect(SunburstAnimation.animation(reduceMotion: true) == nil)
        #expect(SunburstAnimation.animation(reduceMotion: false) != nil)
    }
}
