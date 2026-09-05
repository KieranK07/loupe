import Foundation
import LoupeCore
import SwiftUI

/// One wedge, mid-transition. `ring` is fractional because a wedge migrating
/// inward during a zoom genuinely sits between two rings for a third of a second.
public struct SunburstFrame: Sendable, Hashable {
    public let wedge: Wedge
    public let startAngle: Double
    public let endAngle: Double
    public let ring: Double
    public let opacity: Double

    public init(wedge: Wedge, startAngle: Double, endAngle: Double, ring: Double, opacity: Double) {
        self.wedge = wedge
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.ring = ring
        self.opacity = opacity
    }

    /// A wedge that is not moving. Building one of these is free, which matters
    /// because the steady state draws thousands of them per frame.
    public init(resting wedge: Wedge) {
        self.init(wedge: wedge, startAngle: wedge.startAngle, endAngle: wedge.endAngle,
                  ring: Double(wedge.ring), opacity: 1)
    }
}

/// Every transition the sunburst plays, as pure arithmetic.
///
/// ## Why the curve lives here and not in `Animation`
///
/// SwiftUI drives `progress` **linearly** for every transition in this file, and
/// the shape of the motion is applied by `Timing.geometricProgress`. That is one
/// extra step, and it buys three things a `.spring` in `withAnimation` cannot:
///
/// 1. The curve is testable. `settle` is a function; a spring is a promise.
/// 2. The chart can work out where it currently is from the clock alone, which
///    is what lets a scan re-base a half-finished growth animation onto the
///    layout that just arrived instead of snapping back to the last one.
/// 3. Overshoot can be applied to *position* and withheld from *size*. A spring
///    applied to `animatableData` cannot tell the two apart, and a wedge that
///    springs past its measured size is a chart reporting bytes that were never
///    counted. See `interpolate`.
///
/// Wedges are matched by `Wedge.id` across the two layouts, so a folder that
/// survives a zoom slides and grows into its new place instead of blinking out
/// and a stranger blinking in. Everything else fades.
public enum SunburstAnimation {

    // MARK: - Curves

    /// How far past its target the geometric progress is ever allowed to go.
    ///
    /// This is a clamp, not a licence: an animation driver that hands us 5 must
    /// not fling a wedge five turns round the chart. But it is not clamped at
    /// exactly 1 either, because a settle that cannot pass its target is not a
    /// settle — it is an ease-out with extra steps.
    public static let overshootCeiling: Double = 1.2

    /// A damped spring, normalised so `settle(0) == 0` and `settle(1) == 1`.
    ///
    /// `1 - e^{-at}·cos(bt)` with a ≈ 5.4, b ≈ 8.6: one visible overshoot of
    /// about 14%, peaking near t = 0.37, then flat. The residual at t = 1 is
    /// 0.003 — three tenths of a percent of one transition's travel, which is
    /// well under a pixel — and is snapped away rather than carried, because a
    /// transition that does not *exactly* reach its target leaves the chart
    /// permanently a hair off the geometry every other part of the app agrees on.
    public static func settle(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return 1 - exp(-5.4 * t) * cos(8.6 * t)
    }

    /// Quadratic-ish ease-out. Never exceeds 1 — this is the curve for motion
    /// that is reporting a measurement rather than moving a camera.
    public static func easeOut(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return 1 - pow(1 - c, 2.2)
    }

    /// The acknowledgement a click gets before the zoom takes over: up fast,
    /// down slower, peaking about a quarter of the way through.
    ///
    /// A pulse rather than a state, because the wedge that was clicked is about
    /// to stop existing — it becomes the centre disc. Latching a "selected" look
    /// onto something that is leaving would read as a stuck highlight.
    public static func pressPulse(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return sin(.pi * pow(c, 0.55))
    }

    // MARK: - Timing

    /// The shape and schedule of one transition.
    public struct Timing: Sendable, Hashable {
        /// How the linear clock is bent before it reaches geometry.
        public enum Shape: Sendable, Hashable {
            case linear
            case easeOut
            /// Overshoots. Only ever used for a zoom — see `interpolate`.
            case settle
        }

        public let duration: Double
        public let shape: Shape
        /// Appearing wedges hold back until the survivors are most of the way to
        /// their new positions, so a new ring does not arrive on top of geometry
        /// that is still moving.
        public let entryDelay: Double
        /// Departing wedges leave early for the same reason, in reverse.
        public let exitFraction: Double
        /// Extra delay per ring, as a fraction of the transition. Non-zero only
        /// for the first appearance, where it makes the disk assemble outward
        /// from the centre — which is also the order the scanner actually fills
        /// it in, because the walk is breadth-first for its first few levels.
        public let ringStagger: Double
        /// Entrants open from zero sweep at their own start angle instead of
        /// fading in at full width.
        public let opensEntrants: Bool
        /// Where the camera starts, as a scale about the chart centre. 1 means
        /// no camera move at all.
        public let startScale: Double

        public init(duration: Double, shape: Shape, entryDelay: Double, exitFraction: Double,
                    ringStagger: Double = 0, opensEntrants: Bool = false, startScale: Double = 1) {
            self.duration = max(0, duration)
            self.shape = shape
            self.entryDelay = min(max(entryDelay, 0), 0.95)
            self.exitFraction = min(max(exitFraction, 0), 1)
            self.ringStagger = max(0, ringStagger)
            self.opensEntrants = opensEntrants
            self.startScale = startScale
        }

        /// The linear clock, bent. May exceed 1 for `.settle`, never for the others.
        public func geometricProgress(_ t: Double) -> Double {
            switch shape {
            case .linear: min(max(t, 0), 1)
            case .easeOut: SunburstAnimation.easeOut(t)
            case .settle: SunburstAnimation.settle(t)
            }
        }

        /// The camera, as a scale on the rings at `t`. Drilling in starts small
        /// and rushes forward past its resting size before settling; stepping
        /// back starts large and pulls in. A scan tick never moves the camera —
        /// a disk that lurched ten times a second would be unusable, and nothing
        /// about the viewpoint has changed anyway.
        ///
        /// The renderer applies this about the **centre disc's edge**, not about
        /// the centre point. Scaling about the point is the obvious reading and
        /// it is wrong: the disc is a real `Button` sitting above the canvas and
        /// does not scale with it, so a camera above 1 would open an annular gap
        /// between the disc and ring 0 and the chart would look broken for a
        /// third of a second. Anchored at the disc edge the hole stays exactly
        /// where the hole is and only the rings breathe.
        public func cameraScale(at t: Double) -> Double {
            guard startScale != 1 else { return 1 }
            return 1 + (startScale - 1) * (1 - SunburstAnimation.settle(min(max(t, 0), 1)))
        }

        /// The stagger actually applied, once the ring count is known. Left
        /// unbounded it would push the outer rings past the end of the
        /// transition on a deep chart and they would never arrive.
        public func stagger(ringCount: Int) -> Double {
            guard ringStagger > 0, ringCount > 1 else { return 0 }
            return min(ringStagger, 0.6 / Double(ringCount - 1))
        }

        /// Nothing moves. What Reduce Motion gets, and what an empty layout gets.
        public static let immediate = Timing(duration: 0, shape: .linear,
                                             entryDelay: 0, exitFraction: 0)

        /// Drilling in or out. The one transition allowed to overshoot.
        public static func zoom(depthChange: Int) -> Timing {
            // Falling *into* a folder means its contents start far away and
            // rush forward; backing out means the reverse. A focus change that
            // is neither (a jump sideways from the breadcrumb rail) gets a
            // token push, because no movement at all reads as a broken click.
            // The outward figure is small and the inward one is not, because
            // they are bounded by different things. Pulling the rings *in*
            // toward the hole has the whole centre disc to hide under. Pushing
            // them *out* has only the metrics' 16 pt inset before the rim
            // leaves the window — and that inset is a fixed number of points,
            // so the ratio it can afford shrinks as the window grows: 1.10 on
            // a 2000 pt chart would clip the outer ring by 38 pt. The renderer
            // clamps this against the actual geometry
            // (`SunburstMetrics.maximumCameraScale`); this value is the
            // intent, kept low enough that the clamp rarely has to bite.
            let start: Double = depthChange > 0 ? 0.90 : (depthChange < 0 ? 1.05 : 0.96)
            return Timing(duration: 0.42, shape: .settle, entryDelay: 0.45,
                          exitFraction: 0.55, startScale: start)
        }

        /// A scan tick. `interval` is the observed gap between layouts.
        ///
        /// Duration tracks the measured cadence rather than a constant, because
        /// the tick rate is the app's to choose and it sags under load. Slightly
        /// longer than one interval so there is always motion in flight; the
        /// overlap is absorbed by re-basing rather than by a snap.
        public static func growth(interval: Double) -> Timing {
            Timing(duration: min(max(interval * 1.25, 0.09), 0.45),
                   // Linear, and this is the whole trick. Consecutive linear
                   // segments of matched length join at constant velocity, so a
                   // scan reads as one continuous fill. An ease-in-out per tick
                   // would make the disk pulse at exactly the tick rate, which
                   // is the "slideshow" feeling with extra polish on it.
                   shape: .linear,
                   entryDelay: 0.12, exitFraction: 0.7, opensEntrants: true)
        }

        /// The first layout landing. The disk blooms outward from the centre.
        public static let entrance = Timing(duration: 0.75, shape: .easeOut,
                                            entryDelay: 0, exitFraction: 0,
                                            ringStagger: 0.16, opensEntrants: true,
                                            startScale: 0.93)
    }

    /// Legacy spelling of the zoom duration, kept because it reads better at the
    /// call sites that only ever meant a zoom.
    public static var duration: Double { Timing.zoom(depthChange: 1).duration }
    public static var entryDelay: Double { Timing.zoom(depthChange: 1).entryDelay }
    public static var exitFraction: Double { Timing.zoom(depthChange: 1).exitFraction }

    /// How far a hovered wedge rides out of its ring, in points, at full lift.
    public static let hoverLift: Double = 2.5
    /// How far a clicked wedge presses in.
    public static let pressDepth: Double = 1.5
    /// Hover fades over this; short enough to feel attached to the pointer.
    public static let hoverDuration: Double = 0.14
    /// The click acknowledgement, and how long the zoom waits for it. The wait
    /// is deliberately shorter than the pulse: the point is that the wedge has
    /// visibly reacted before the geometry moves, not that the reaction finishes.
    public static let pressDuration: Double = 0.28
    public static let pressLead: Double = 0.07

    public static func animation(_ timing: Timing, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion, timing.duration > 0 else { return nil }
        // Linear on purpose. See the type comment: the curve is in `Timing`.
        return .linear(duration: timing.duration)
    }

    public static func animation(reduceMotion: Bool) -> Animation? {
        animation(.zoom(depthChange: 1), reduceMotion: reduceMotion)
    }

    // MARK: - Plan

    /// Which transition a new layout deserves. Pure, so the decision can be
    /// tested without a view — in particular the Reduce Motion path, which must
    /// resolve to "no transition at all" for every kind of layout change.
    public struct Plan: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// Adopt the new geometry directly. No departing layout is kept.
            case immediate
            case entrance
            case zoom
            case growth
        }

        public let kind: Kind
        public let timing: Timing
        public var isAnimated: Bool { kind != .immediate && timing.duration > 0 }
        /// A zoom hides the labels and the emphasis while it plays; a scan tick
        /// must not, or the names would be gone for the whole scan.
        public var hidesOverlays: Bool { kind == .zoom }
    }

    public static func plan(hasPrevious: Bool, previousIsEmpty: Bool, nextIsEmpty: Bool,
                            focusChanged: Bool, depthChange: Int,
                            tickInterval: Double, reduceMotion: Bool) -> Plan {
        guard !reduceMotion, !nextIsEmpty else {
            return Plan(kind: .immediate, timing: .immediate)
        }
        if !hasPrevious || previousIsEmpty {
            // Nothing to move away from — including a focus change made before
            // the first layout arrived, which is a first appearance and not a
            // zoom however it got here.
            return Plan(kind: .entrance, timing: .entrance)
        }
        if focusChanged {
            return Plan(kind: .zoom, timing: .zoom(depthChange: depthChange))
        }
        // A new generation ten times a second during a scan is not a zoom — the
        // wedges are just growing.
        return Plan(kind: .growth, timing: .growth(interval: tickInterval))
    }

    // MARK: - Interpolation

    /// Interpolate one wedge's geometry.
    ///
    /// The start angle moves the short way round and the sweep is interpolated
    /// separately. Lerping start and end independently would send a wedge that
    /// moves from 6.24 rad to 0.02 rad — two hundredths of a turn on screen —
    /// almost all the way round the chart backwards.
    ///
    /// `progress` may exceed 1 up to `overshootCeiling`, and when it does the
    /// overshoot reaches the *position* only. Two things are withheld from it,
    /// for two different reasons.
    ///
    /// **The sweep** stops dead on arrival. A wedge that springs past its final
    /// sweep is a folder drawn larger than it was measured to be, and no amount
    /// of "it settles in 200 ms" makes that an acceptable thing for a measuring
    /// instrument to draw. `size` is clamped to 1, so the sweep is always a
    /// convex combination of the two endpoints.
    ///
    /// **The ring** stops at 0, because the disk has a hole and nothing is ever
    /// drawn in it. Unclamped, a wedge migrating from ring 1 to ring 0 on a
    /// drill-in reaches ring −0.17 at the settle's peak, which puts its inner
    /// edge about 2 pt *inside* the centre disc — the disc is `.regularMaterial`
    /// and translucent, so that is a colour smear through the blur for about
    /// 70 ms on every drill-in, not a hidden one. Radially, inward is the one
    /// direction with a wall in front of it. Outward has the metrics' 16 pt
    /// inset to absorb it and is left free.
    ///
    /// Nothing is lost by clamping: the angle still carries past its target and
    /// settles back, and the angle is what sells a spring on a disk anyway.
    public static func interpolate(from old: Wedge, to new: Wedge, progress t: Double) -> SunburstFrame {
        let g = min(max(t, 0), overshootCeiling)
        let size = min(g, 1)
        let start = old.startAngle + SunburstAngle.shortestDelta(from: old.startAngle, to: new.startAngle) * g
        let sweep = max(0, old.sweep + (new.sweep - old.sweep) * size)
        let ring = max(0, Double(old.ring) + (Double(new.ring) - Double(old.ring)) * g)
        return SunburstFrame(wedge: new, startAngle: start, endAngle: start + sweep,
                             ring: ring, opacity: 1)
    }

    /// Where a new wedge came from in `old`, or nil if it is arriving.
    ///
    /// Matching is by `Wedge.id` — that is the contract — but the *search* has a
    /// fast path, because during a scan the two layouts are almost always the
    /// same wedges in the same order and only a handful of sweeps have changed.
    /// Index `i` is tried first and the dictionary is only consulted when that
    /// misses, which on a typical tick is never.
    ///
    /// `matched` replaces what used to be a `Set<UInt32>`. It does the same job —
    /// a wedge may only be claimed once, so that if two wedges ever did share a
    /// ref they would not both slide out of the same place — without hashing
    /// several thousand ids on every animation frame, which now means on every
    /// display frame for the whole of a scan. It also gives the departure pass
    /// its answer for free: an old wedge left iff nothing claimed it.
    @inline(__always)
    private static func survivorIndex(of wedge: Wedge, at i: Int, in old: SunburstIndex,
                                      matched: inout [Bool]) -> Int? {
        guard wedge.node.isValid else { return nil }
        if i < old.wedges.count, old.wedges[i].id == wedge.id, !matched[i] {
            matched[i] = true
            return i
        }
        guard let position = old.position(ofNode: wedge.node),
              old.ringRanges.indices.contains(position.ring) else { return nil }
        let j = old.ringRanges[position.ring].lowerBound + position.offset
        guard j >= 0, j < old.wedges.count, !matched[j] else { return nil }
        matched[j] = true
        return j
    }

    /// Every wedge to draw at `progress`, in ring-then-angle order.
    ///
    /// `progress == 1` with no `from` is the steady state; callers should skip
    /// this entirely there and iterate the index directly, because this
    /// allocates and the steady state is the per-frame path.
    public static func frames(from old: SunburstIndex?, to new: SunburstIndex,
                              progress: Double,
                              timing: Timing = .zoom(depthChange: 1)) -> [SunburstFrame] {
        // The scheduling clock stays in 0...1 whatever the shape does. Opacity
        // ramps and the stagger are read off this, not off the bent version:
        // a fade that overshoots is just a fade that flickers.
        let t = min(max(progress, 0), 1)
        guard let old, t < 1 else { return new.wedges.map(SunburstFrame.init(resting:)) }

        var frames: [SunburstFrame] = []
        frames.reserveCapacity(new.wedges.count + old.wedges.count / 4)

        let ringCount = max(new.ringCount, old.ringCount)
        let stagger = timing.stagger(ringCount: ringCount)
        let staggerSpan = max(1e-6, 1 - stagger * Double(max(0, ringCount - 1)))
        let entrySpan = max(1e-9, 1 - timing.entryDelay)
        let exitOpacity = timing.exitFraction <= 0 ? 0 : max(0, 1 - t / timing.exitFraction)

        // Only worth sorting if something actually landed out of order. During a
        // scan nothing does — no node changes ring under a fixed focus — and the
        // sort is several thousand comparisons on every animation frame.
        var needsSort = false

        var matched = [Bool](repeating: false, count: old.wedges.count)

        for (i, wedge) in new.wedges.enumerated() {
            let localClock = stagger <= 0 ? t
                : min(max((t - stagger * Double(wedge.ring)) / staggerSpan, 0), 1)

            if let j = survivorIndex(of: wedge, at: i, in: old, matched: &matched) {
                let frame = interpolate(from: old.wedges[j], to: wedge,
                                        progress: timing.geometricProgress(localClock))
                if frame.ring != Double(wedge.ring) { needsSort = true }
                frames.append(frame)
            } else {
                let arrival = min(max((localClock - timing.entryDelay) / entrySpan, 0), 1)
                if timing.opensEntrants {
                    // Opening from the start angle rather than fading in at full
                    // width. The gap a new wedge is arriving into is opened by
                    // its neighbours sliding apart, so growing into it is what
                    // the geometry is actually doing; a full-width cross-fade
                    // paints a translucent smear over whoever has not moved yet.
                    let open = min(1, timing.geometricProgress(arrival))
                    frames.append(SunburstFrame(wedge: wedge, startAngle: wedge.startAngle,
                                                endAngle: wedge.startAngle + wedge.sweep * open,
                                                ring: Double(wedge.ring), opacity: arrival))
                } else {
                    frames.append(SunburstFrame(wedge: wedge, startAngle: wedge.startAngle,
                                                endAngle: wedge.endAngle,
                                                ring: Double(wedge.ring), opacity: arrival))
                }
            }
        }

        if exitOpacity > 0 {
            for (i, wedge) in old.wedges.enumerated() where !matched[i] {
                needsSort = true
                frames.append(SunburstFrame(wedge: wedge, startAngle: wedge.startAngle,
                                            endAngle: wedge.endAngle, ring: Double(wedge.ring),
                                            opacity: exitOpacity))
            }
        }

        // Departing wedges were appended out of order; restore ring-then-angle
        // so the painter's algorithm still draws inner rings first.
        if needsSort {
            frames.sort { a, b in
                a.ring == b.ring ? a.startAngle < b.startAngle : a.ring < b.ring
            }
        }
        return frames
    }

    /// The geometry currently on screen, as a layout in its own right.
    ///
    /// A scan hands the chart a new layout every tenth of a second, which is
    /// faster than one growth animation finishes. Restarting from the *last*
    /// layout would yank every wedge back to where it was before the animation
    /// in flight had got it — a visible twitch on every tick, which is the
    /// slideshow this was all meant to fix. So the half-finished state becomes
    /// the new starting point.
    ///
    /// Wedges that were fading out are dropped rather than carried: `Wedge` has
    /// nowhere to record an opacity, and a wedge only leaves mid-scan when an
    /// aggregation boundary moves, which is rare and small.
    public static func rebased(from old: SunburstIndex, to new: SunburstIndex,
                               progress: Double, timing: Timing) -> SunburstIndex {
        let t = min(max(progress, 0), 1)
        guard t < 1 else { return new }

        let entrySpan = max(1e-9, 1 - timing.entryDelay)
        var wedges: [Wedge] = []
        wedges.reserveCapacity(new.wedges.count)
        var matched = [Bool](repeating: false, count: old.wedges.count)

        for (i, wedge) in new.wedges.enumerated() {
            var start = wedge.startAngle
            var sweep = wedge.sweep
            if let j = survivorIndex(of: wedge, at: i, in: old, matched: &matched) {
                let frame = interpolate(from: old.wedges[j], to: wedge,
                                        progress: timing.geometricProgress(t))
                start = frame.startAngle
                sweep = frame.endAngle - frame.startAngle
            } else if timing.opensEntrants {
                let arrival = min(max((t - timing.entryDelay) / entrySpan, 0), 1)
                sweep *= min(1, timing.geometricProgress(arrival))
            }
            // `endAngle > startAngle` is a contract invariant and a wedge that
            // has not begun to open would break it. A hair of sweep costs
            // nothing to draw and keeps the value legal.
            wedges.append(Wedge(node: wedge.node, startAngle: start,
                                endAngle: start + max(sweep, 1e-9), ring: wedge.ring,
                                physicalBytes: wedge.physicalBytes,
                                logicalBytes: wedge.logicalBytes,
                                itemCount: wedge.itemCount, name: wedge.name,
                                kind: wedge.kind, colorSeed: wedge.colorSeed))
        }

        return SunburstIndex(SunburstLayout(
            generation: new.generation, focus: new.focus, focusPath: new.focusPath,
            breadcrumb: new.breadcrumb, wedges: wedges,
            totalPhysicalBytes: new.totalPhysicalBytes,
            totalLogicalBytes: new.totalLogicalBytes,
            scannedAt: new.scannedAt, isComplete: new.isComplete))
    }
}
