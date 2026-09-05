import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

/// The curves, the schedule, and the one rule that stops a pretty animation
/// telling a lie about the data.
///
/// All of this is arithmetic on purpose. A `.spring` in `withAnimation` would
/// have been fewer lines and none of it could be asserted; these are the tests
/// that curve earns its keep with.
@Suite("Sunburst motion")
struct SunburstMotionTests {
    private func wedge(slot: UInt32, start: Double, end: Double, ring: UInt8,
                       kind: WedgeKind = .real) -> Wedge {
        Wedge(node: .directory(slot), startAngle: start, endAngle: end, ring: ring,
              physicalBytes: 1024, logicalBytes: 2048, itemCount: 1,
              name: "n\(slot)", kind: kind, colorSeed: 0)
    }

    private var samples: [Double] {
        stride(from: 0.0, through: 1.0, by: 0.002).map { $0 }
    }

    // MARK: - Curves

    @Test("settle starts at nothing, ends exactly on target, and overshoots once")
    func settleShape() {
        #expect(SunburstAnimation.settle(0) == 0)
        #expect(SunburstAnimation.settle(1) == 1)
        #expect(SunburstAnimation.settle(-3) == 0)
        #expect(SunburstAnimation.settle(9) == 1)

        let peak = samples.map(SunburstAnimation.settle).max() ?? 0
        #expect(peak > 1.05, "no overshoot at all: \(peak)")
        #expect(peak <= SunburstAnimation.overshootCeiling,
                "the settle exceeds the clamp that is meant to bound it: \(peak)")

        // It must come back. A curve that peaks and stays there is an ease-out
        // wearing a hat.
        let tail = stride(from: 0.8, through: 0.999, by: 0.002).map(SunburstAnimation.settle)
        #expect(tail.allSatisfy { abs($0 - 1) < 0.02 })

        // And the seam at t = 1 must not be a visible jump.
        #expect(abs(SunburstAnimation.settle(0.9999) - 1) < 0.005)
    }

    @Test("easeOut never passes its target")
    func easeOutShape() {
        #expect(SunburstAnimation.easeOut(0) == 0)
        #expect(abs(SunburstAnimation.easeOut(1) - 1) < 1e-12)
        #expect(samples.allSatisfy { SunburstAnimation.easeOut($0) <= 1 })
        // Monotone, or the bloom would breathe.
        for (a, b) in zip(samples, samples.dropFirst()) {
            #expect(SunburstAnimation.easeOut(a) <= SunburstAnimation.easeOut(b) + 1e-12)
        }
    }

    @Test("The press pulse rises fast, comes back, and peaks early")
    func pressPulseShape() {
        #expect(SunburstAnimation.pressPulse(0) == 0)
        #expect(abs(SunburstAnimation.pressPulse(1)) < 1e-9)
        let values = samples.map(SunburstAnimation.pressPulse)
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
        let peakAt = zip(samples, values).max { $0.1 < $1.1 }?.0 ?? 1
        #expect(peakAt < 0.4, "the acknowledgement peaks too late to acknowledge anything: \(peakAt)")
        // The whole point is that it has visibly happened by the time the zoom
        // is allowed to start.
        let atLead = SunburstAnimation.pressPulse(
            SunburstAnimation.pressLead / SunburstAnimation.pressDuration)
        #expect(atLead > 0.6, "nothing has visibly happened when the zoom begins: \(atLead)")
    }

    // MARK: - The honesty rule

    /// The single place in this work where motion could misreport a measurement.
    ///
    /// A settle carries a wedge past its target and back. Applied to the *sweep*
    /// that would draw a folder larger than any measurement ever taken of it —
    /// briefly, prettily, and dishonestly. So the overshoot reaches the position
    /// and stops at the size, and this is the test that says so.
    @Test("Overshoot moves a wedge but never inflates it")
    func overshootNeverInflates() {
        let old = wedge(slot: 1, start: 0.2, end: 0.6, ring: 3)
        let new = wedge(slot: 1, start: 2.0, end: 3.0, ring: 0)

        for t in stride(from: 0.0, through: SunburstAnimation.overshootCeiling, by: 0.001) {
            let frame = SunburstAnimation.interpolate(from: old, to: new, progress: t)
            let sweep = frame.endAngle - frame.startAngle
            #expect(sweep >= min(old.sweep, new.sweep) - 1e-12,
                    "sweep collapsed below both endpoints at \(t): \(sweep)")
            #expect(sweep <= max(old.sweep, new.sweep) + 1e-12,
                    "sweep grew past both endpoints at \(t): \(sweep)")
        }

        // The same, the other way round: a folder that is shrinking must not be
        // drawn briefly larger than it ever was either.
        let shrinking = wedge(slot: 2, start: 0, end: 2.0, ring: 0)
        let smaller = wedge(slot: 2, start: 0, end: 0.5, ring: 0)
        for t in stride(from: 0.0, through: SunburstAnimation.overshootCeiling, by: 0.001) {
            let frame = SunburstAnimation.interpolate(from: shrinking, to: smaller, progress: t)
            #expect(frame.endAngle - frame.startAngle <= shrinking.sweep + 1e-12)
        }

        // But the position genuinely does overshoot, or none of this was worth
        // it. In *angle*, which is the component with no wall in front of it.
        let past = SunburstAnimation.interpolate(from: old, to: new, progress: 1.15)
        let carried = SunburstAngle.shortestDelta(from: new.startAngle, to: past.startAngle)
        #expect(carried > 0.01, "the angle did not carry past its target: \(past.startAngle)")
        #expect(abs((past.endAngle - past.startAngle) - new.sweep) < 1e-12,
                "the sweep overshot and it must not")
    }

    /// The disk has a hole, and nothing is ever drawn in it.
    ///
    /// Unclamped, a wedge migrating inward on a drill-in reaches ring −0.17 at
    /// the settle's peak. On eight rings in an 800 pt square that is an inner
    /// edge of 93.8 pt against a centre disc whose edge is at 95.8 — two points
    /// under a `.regularMaterial` circle, which is translucent, so it shows as a
    /// smear through the blur for about 70 ms of every zoom.
    @Test("Overshoot never carries a wedge into the centre hole")
    func overshootStaysOutOfTheHole() {
        for fromRing in UInt8(0)...UInt8(8) {
            for toRing in UInt8(0)...UInt8(8) {
                let old = wedge(slot: 1, start: 0.2, end: 0.6, ring: fromRing)
                let new = wedge(slot: 1, start: 2.0, end: 2.5, ring: toRing)
                for t in stride(from: 0.0, through: SunburstAnimation.overshootCeiling, by: 0.005) {
                    let frame = SunburstAnimation.interpolate(from: old, to: new, progress: t)
                    #expect(frame.ring >= 0,
                            "ring \(fromRing) → \(toRing) reached \(frame.ring) at \(t)")
                }
            }
        }

        // Outward is left free: it has the metrics' inset to land in, and that
        // is where the spring is still visible on a zoom out.
        let outward = SunburstAnimation.interpolate(
            from: wedge(slot: 1, start: 0, end: 1, ring: 0),
            to: wedge(slot: 1, start: 0, end: 1, ring: 1), progress: 1.15)
        #expect(outward.ring > 1, "the outward overshoot was clamped too: \(outward.ring)")
    }

    /// The same boundary question at the other end of the radius.
    ///
    /// A camera above 1 has only the metrics' fixed 16 pt inset to expand into,
    /// so the ratio it can afford shrinks as the chart grows. Left unclamped,
    /// the 1.10 this started at clipped the outer ring by 4 pt on a shallow
    /// 800 pt chart and by 38 pt on a 2000 pt one.
    @Test("The camera never pushes the outer ring out of the window")
    func cameraStaysInsideTheView() {
        for size in [320.0, 480.0, 800.0, 1200.0, 2000.0, 3000.0] {
            for rings in 1...Int(SunburstGeometry.maximumRings) {
                let metrics = SunburstMetrics(size: CGSize(width: size, height: size),
                                              ringCount: rings)
                let room = min(metrics.center.x, metrics.center.y)
                for timing in [SunburstAnimation.Timing.zoom(depthChange: -1),
                               .zoom(depthChange: 1), .zoom(depthChange: 0), .entrance] {
                    for t in stride(from: 0.0, through: 1.0, by: 0.01) {
                        let camera = min(timing.cameraScale(at: t), metrics.maximumCameraScale)
                        let rim = metrics.centreRadius
                            + (metrics.outerRadius - metrics.centreRadius) * camera
                        #expect(rim <= room + 1e-9,
                                "rim \(rim) past \(room) at size \(size), \(rings) rings, t \(t)")
                    }
                }
            }
        }
        // And it only ever caps the push outward — pulling in is unbounded.
        let metrics = SunburstMetrics(size: CGSize(width: 800, height: 800), ringCount: 8)
        #expect(metrics.maximumCameraScale > 1)
        #expect(SunburstMetrics(size: .zero, ringCount: 0).maximumCameraScale == 1)
    }

    @Test("Only a zoom is allowed to overshoot at all")
    func onlyZoomOvershoots() {
        let growth = SunburstAnimation.Timing.growth(interval: 0.1)
        let entrance = SunburstAnimation.Timing.entrance
        for t in samples {
            #expect(growth.geometricProgress(t) <= 1,
                    "a scan tick overshot at \(t) — that is a folder drawn bigger than measured")
            #expect(entrance.geometricProgress(t) <= 1, "the entrance overshot at \(t)")
        }
        let zoom = SunburstAnimation.Timing.zoom(depthChange: 1)
        #expect(samples.map(zoom.geometricProgress).max() ?? 0 > 1)
    }

    /// The end-to-end version of the same promise, through `frames`.
    @Test("No wedge is ever drawn wider than it has been measured, at any progress")
    func framesNeverInflate() {
        let before = SunburstIndex(Fixture.layout(levels: [[2, 1, 3], [1, 1]], generation: 1))
        let after = SunburstIndex(Fixture.layout(levels: [[3, 1, 4], [1, 2]], generation: 2))
        var ceilings: [UInt32: Double] = [:]
        for w in before.wedges { ceilings[w.id] = max(ceilings[w.id] ?? 0, w.sweep) }
        for w in after.wedges { ceilings[w.id] = max(ceilings[w.id] ?? 0, w.sweep) }

        for timing in [SunburstAnimation.Timing.growth(interval: 0.1),
                       .zoom(depthChange: 1), .entrance] {
            for t in stride(from: 0.0, through: 1.0, by: 0.01) {
                for frame in SunburstAnimation.frames(from: before, to: after,
                                                      progress: t, timing: timing) {
                    let sweep = frame.endAngle - frame.startAngle
                    #expect(sweep <= (ceilings[frame.wedge.id] ?? 0) + 1e-9,
                            "wedge \(frame.wedge.id) drawn at \(sweep) rad at progress \(t)")
                }
            }
        }
    }

    // MARK: - Reduce Motion

    @Test("Reduce Motion resolves every layout change to no transition at all")
    func reduceMotionPlansNothing() {
        for hasPrevious in [true, false] {
            for previousIsEmpty in [true, false] {
                for focusChanged in [true, false] {
                    for depthChange in [-1, 0, 1] {
                        let plan = SunburstAnimation.plan(
                            hasPrevious: hasPrevious, previousIsEmpty: previousIsEmpty,
                            nextIsEmpty: false, focusChanged: focusChanged,
                            depthChange: depthChange, tickInterval: 0.1, reduceMotion: true)
                        #expect(plan.kind == .immediate)
                        #expect(!plan.isAnimated)
                        #expect(plan.timing.duration == 0)
                        #expect(!plan.hidesOverlays)
                        // Nothing to hand `withAnimation`, so nothing animates.
                        #expect(SunburstAnimation.animation(plan.timing, reduceMotion: true) == nil)
                    }
                }
            }
        }
    }

    /// The view's Reduce Motion branch keeps no departing layout and pins
    /// progress at 1, so what it draws is `frames` at rest. This is that, as
    /// arithmetic: the resting geometry, exactly, with nothing interpolated.
    @Test("With motion off the geometry is the resting geometry, exactly")
    func reduceMotionDrawsRestingGeometry() {
        let before = SunburstIndex(Fixture.layout(levels: [[2, 1, 3], [1, 1]], generation: 1))
        let after = SunburstIndex(Fixture.layout(levels: [[1, 4], [2, 1, 1]],
                                                 startAt: 0.7, generation: 2))
        // Whatever the timing, progress 1 is the destination and only the
        // destination. The Reduce Motion path never leaves progress anywhere else.
        for timing in [SunburstAnimation.Timing.immediate,
                       .growth(interval: 0.1), .zoom(depthChange: 1), .entrance] {
            let frames = SunburstAnimation.frames(from: before, to: after, progress: 1,
                                                  timing: timing)
            #expect(frames.count == after.wedges.count)
            for (frame, wedge) in zip(frames, after.wedges) {
                #expect(frame.startAngle == wedge.startAngle)
                #expect(frame.endAngle == wedge.endAngle)
                #expect(frame.ring == Double(wedge.ring))
                #expect(frame.opacity == 1)
            }
        }
        // And no camera move is left applied.
        #expect(SunburstAnimation.Timing.immediate.cameraScale(at: 0) == 1)
        #expect(SunburstAnimation.Timing.immediate.cameraScale(at: 0.5) == 1)
        #expect(SunburstAnimation.Timing.immediate.cameraScale(at: 1) == 1)
    }

    @Test("Every timing animates only when motion is allowed")
    func animationHonoursReduceMotion() {
        for timing in [SunburstAnimation.Timing.growth(interval: 0.1),
                       .zoom(depthChange: 1), .zoom(depthChange: -1), .entrance] {
            #expect(SunburstAnimation.animation(timing, reduceMotion: true) == nil)
            #expect(SunburstAnimation.animation(timing, reduceMotion: false) != nil)
        }
        // Including the degenerate one, which has nothing to animate anyway.
        #expect(SunburstAnimation.animation(.immediate, reduceMotion: false) == nil)
    }

    // MARK: - Plan

    @Test("A new generation at the same focus is growth, not a zoom")
    func planKinds() {
        func plan(hasPrevious: Bool = true, previousIsEmpty: Bool = false,
                  nextIsEmpty: Bool = false, focusChanged: Bool = false,
                  depthChange: Int = 0) -> SunburstAnimation.Plan {
            SunburstAnimation.plan(hasPrevious: hasPrevious, previousIsEmpty: previousIsEmpty,
                                   nextIsEmpty: nextIsEmpty, focusChanged: focusChanged,
                                   depthChange: depthChange, tickInterval: 0.1,
                                   reduceMotion: false)
        }
        #expect(plan().kind == .growth)
        #expect(plan(focusChanged: true, depthChange: 1).kind == .zoom)
        #expect(plan(hasPrevious: false).kind == .entrance)
        #expect(plan(previousIsEmpty: true).kind == .entrance)
        // A focus change made before anything had been drawn is a first
        // appearance however it got here, not a zoom out of nothing.
        #expect(plan(previousIsEmpty: true, focusChanged: true, depthChange: 1).kind == .entrance)
        #expect(plan(nextIsEmpty: true).kind == .immediate)

        // Only a zoom takes the labels and the emphasis away. A scan must not,
        // or the names are gone for the whole scan.
        #expect(plan(focusChanged: true, depthChange: 1).hidesOverlays)
        #expect(!plan().hidesOverlays)
        #expect(!plan(hasPrevious: false).hidesOverlays)
    }

    @Test("Growth tracks the cadence it is actually given")
    func growthFollowsTickRate() {
        let fast = SunburstAnimation.Timing.growth(interval: 0.1)
        let slow = SunburstAnimation.Timing.growth(interval: 0.3)
        #expect(fast.duration < slow.duration)
        // Always a little longer than the gap, so there is motion in flight when
        // the next layout lands and the re-base has something to pick up.
        #expect(fast.duration > 0.1)
        #expect(slow.duration > 0.3)
        // And bounded at both ends, because a stalled scanner must not leave the
        // chart easing for a second and a half.
        #expect(SunburstAnimation.Timing.growth(interval: 0.0001).duration >= 0.09)
        #expect(SunburstAnimation.Timing.growth(interval: 60).duration <= 0.45)
        // Linear, and that is load-bearing: see `Timing.growth`.
        #expect(fast.shape == .linear)
    }

    // MARK: - Camera

    @Test("The camera moves in for a drill-in, out for a step back, and lands at 1")
    func cameraDirection() {
        let inward = SunburstAnimation.Timing.zoom(depthChange: 1)
        let outward = SunburstAnimation.Timing.zoom(depthChange: -1)
        #expect(inward.cameraScale(at: 0) < 1, "drilling in did not start further away")
        #expect(outward.cameraScale(at: 0) > 1, "stepping back did not start closer")
        #expect(abs(inward.cameraScale(at: 1) - 1) < 1e-12)
        #expect(abs(outward.cameraScale(at: 1) - 1) < 1e-12)

        // It passes its resting size and comes back — that is the "falling in".
        let scales = samples.map(inward.cameraScale(at:))
        #expect((scales.max() ?? 0) > 1.005, "the camera never overshoots")
        // But subtly. This is an instrument, not a title sequence.
        #expect((scales.max() ?? 0) < 1.03)
        #expect((scales.min() ?? 0) >= 0.89)

        // A scan tick never moves the camera at all. Ten lurches a second would
        // be unusable, and the viewpoint has not changed anyway.
        let growth = SunburstAnimation.Timing.growth(interval: 0.1)
        #expect(samples.allSatisfy { growth.cameraScale(at: $0) == 1 })
    }

    // MARK: - Entrance

    @Test("The bloom is staggered by ring but every ring still arrives")
    func entranceStagger() {
        let timing = SunburstAnimation.Timing.entrance
        #expect(timing.stagger(ringCount: 1) == 0, "one ring has nothing to stagger against")
        for rings in 2...Int(SunburstGeometry.maximumRings) + 1 {
            let stagger = timing.stagger(ringCount: rings)
            #expect(stagger > 0)
            #expect(stagger * Double(rings - 1) <= 0.6 + 1e-12,
                    "the outer rings start so late they cannot finish: \(stagger) × \(rings)")
        }

        // The outermost ring is behind the innermost early on, and level with it
        // by the end.
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1], [1, 1], [1, 1]]))
        let early = SunburstAnimation.frames(from: SunburstIndex(.empty), to: index,
                                             progress: 0.2, timing: timing)
        let inner = early.filter { $0.wedge.ring == 0 }
        let outer = early.filter { $0.wedge.ring == 2 }
        #expect(!inner.isEmpty && !outer.isEmpty)
        #expect((inner.map(\.opacity).min() ?? 0) > (outer.map(\.opacity).max() ?? 1),
                "the disk did not bloom outward")

        let late = SunburstAnimation.frames(from: SunburstIndex(.empty), to: index,
                                            progress: 0.995, timing: timing)
        #expect(late.allSatisfy { $0.opacity > 0.9 }, "a ring never finished arriving")
    }

    @Test("An entrant opens from its own start angle instead of appearing whole")
    func entrantsOpen() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1]]))
        let frames = SunburstAnimation.frames(from: SunburstIndex(.empty), to: index,
                                              progress: 0.4, timing: .entrance)
        for frame in frames {
            guard let final = index.wedges.first(where: { $0.id == frame.wedge.id }) else { continue }
            #expect(frame.startAngle == final.startAngle, "an opening wedge moved its anchor")
            let sweep = frame.endAngle - frame.startAngle
            #expect(sweep > 0)
            #expect(sweep < final.sweep, "the wedge was already fully open at 0.4")
        }
        // A zoom's entrants keep the old behaviour: full width, delayed fade.
        // That transition was already right and this work was not licence to
        // redo it.
        #expect(!SunburstAnimation.Timing.zoom(depthChange: 1).opensEntrants)
    }

    // MARK: - Re-basing

    @Test("Re-basing hands the next tick the geometry that is on screen")
    func rebaseIsContinuous() {
        let before = SunburstIndex(Fixture.layout(levels: [[2, 1, 3]], generation: 1))
        let after = SunburstIndex(Fixture.layout(levels: [[1, 4, 2]], generation: 2))
        let timing = SunburstAnimation.Timing.growth(interval: 0.1)

        for t in [0.0, 0.25, 0.5, 0.75, 0.99] {
            let rebased = SunburstAnimation.rebased(from: before, to: after,
                                                    progress: t, timing: timing)
            let drawn = SunburstAnimation.frames(from: before, to: after,
                                                 progress: t, timing: timing)
            // Every wedge in the re-based layout stands exactly where the frame
            // for it was being drawn. Anything else is a visible twitch on every
            // tick of every scan, which is the whole thing this is for.
            for wedge in rebased.wedges {
                guard let frame = drawn.first(where: { $0.wedge.id == wedge.id }) else {
                    Issue.record("re-based wedge \(wedge.id) was not being drawn")
                    continue
                }
                #expect(abs(wedge.startAngle - frame.startAngle) < 1e-9, "at \(t)")
                #expect(abs(wedge.sweep - (frame.endAngle - frame.startAngle)) < 1e-6, "at \(t)")
                #expect(wedge.ring == frame.wedge.ring)
            }
        }
    }

    @Test("A re-base at the very start is the old layout, and at the end the new one")
    func rebaseEndpoints() {
        let before = SunburstIndex(Fixture.layout(levels: [[2, 1, 3]], generation: 1))
        let after = SunburstIndex(Fixture.layout(levels: [[1, 4, 2]], generation: 2))
        let timing = SunburstAnimation.Timing.growth(interval: 0.1)

        let atStart = SunburstAnimation.rebased(from: before, to: after, progress: 0, timing: timing)
        for wedge in atStart.wedges {
            guard let previous = before.wedges.first(where: { $0.id == wedge.id }) else { continue }
            #expect(abs(wedge.startAngle - previous.startAngle) < 1e-12)
            #expect(abs(wedge.sweep - previous.sweep) < 1e-12)
        }

        let atEnd = SunburstAnimation.rebased(from: before, to: after, progress: 1, timing: timing)
        #expect(atEnd.wedges.count == after.wedges.count)
        for (a, b) in zip(atEnd.wedges, after.wedges) {
            #expect(a.startAngle == b.startAngle)
            #expect(a.endAngle == b.endAngle)
        }
    }

    /// `endAngle > startAngle` is a contract invariant of `Wedge`, and a
    /// re-based layout is a `SunburstLayout` like any other — the index built
    /// from it is binary-searched, so a zero-width wedge would be a hit test
    /// that silently stops matching.
    @Test("A re-based layout never contains a degenerate wedge")
    func rebaseKeepsWedgesLegal() {
        let before = SunburstIndex(Fixture.layout(levels: [[1, 1]], generation: 1))
        // A layout with wedges the old one has never seen: they are mid-open.
        let after = SunburstIndex(Fixture.layout(levels: [[1, 1, 1, 1]], generation: 2))
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let rebased = SunburstAnimation.rebased(from: before, to: after,
                                                    progress: t, timing: .growth(interval: 0.1))
            #expect(rebased.wedges.allSatisfy { $0.endAngle > $0.startAngle },
                    "degenerate wedge after re-basing at \(t)")
        }
    }

    // MARK: - The dashed edge survives

    /// A directory still being walked has a dashed outer edge, and that signal
    /// is not the renderer's to lose. The dash *phase* moves while layouts keep
    /// arriving; the dash itself is unconditional.
    @Test("Still-scanning wedges keep their provisional edge through a transition")
    func stillScanningSurvivesTransitions() {
        let index = SunburstIndex(Fixture.layout(
            levels: [[1, 1, 1]],
            kindForRing: { _, child in child == 1 ? .stillScanning : .real }))
        let empty = SunburstIndex(.empty)
        for timing in [SunburstAnimation.Timing.growth(interval: 0.1), .entrance,
                       .zoom(depthChange: 1)] {
            for t in stride(from: 0.0, through: 1.0, by: 0.1) {
                let frames = SunburstAnimation.frames(from: empty, to: index,
                                                      progress: t, timing: timing)
                #expect(frames.contains { $0.wedge.isStillScanning },
                        "the still-scanning wedge vanished at \(t)")
            }
        }
    }
}
