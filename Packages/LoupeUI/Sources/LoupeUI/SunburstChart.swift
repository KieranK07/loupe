import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI

/// One annular sector, in the contract's angular convention.
///
/// Contract angles run clockwise from 12 o'clock. CoreGraphics measures from 3
/// o'clock, and Canvas's y axis points *down*, which already mirrors its sweep
/// into a visual clockwise — so the only correction needed is a quarter turn.
/// `clockwise: false` is the increasing-angle direction; that was verified
/// against `Path.boundingRect` rather than assumed, because the flag's meaning
/// is famously inverted relative to CoreGraphics in a y-down space.
@inline(__always)
func sunburstSectorPath(center: CGPoint, innerRadius: Double, outerRadius: Double,
                        start: Double, end: Double) -> Path {
    var path = Path()
    guard outerRadius > innerRadius, end > start else { return path }

    if end - start >= SunburstAngle.fullTurn - 1e-9 {
        // A wedge owning the whole turn is an annulus. Build it from two
        // circles filled even-odd: sweeping a single arc through exactly 2π is
        // the sort of degenerate case rasterisers disagree about, and a ring-0
        // wedge covering the entire focus is a perfectly ordinary layout.
        path.addEllipse(in: CGRect(x: center.x - outerRadius, y: center.y - outerRadius,
                                   width: outerRadius * 2, height: outerRadius * 2))
        path.addEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                   width: innerRadius * 2, height: innerRadius * 2))
        return path
    }

    let s = Angle.radians(start - .pi / 2)
    let e = Angle.radians(end - .pi / 2)
    path.addArc(center: center, radius: outerRadius, startAngle: s, endAngle: e, clockwise: false)
    // `addArc` joins from the current point, so this closes the radial edge at
    // `e` on its own before sweeping back along the inner radius.
    path.addArc(center: center, radius: innerRadius, startAngle: e, endAngle: s, clockwise: true)
    path.closeSubpath()
    return path
}

/// Where the hover emphasis is, and where it is coming from.
struct SunburstHoverTarget: Equatable {
    var position: SunburstPosition?
    /// The hovered wedge's ancestors, lit faintly so the path in is visible.
    var chain: Set<SunburstPosition> = []

    static let none = SunburstHoverTarget()
    var isEmpty: Bool { position == nil && chain.isEmpty }
}

// MARK: - Composition

/// The chart, as three stacked canvases.
///
/// Splitting them is not tidiness, it is the difference between a hover costing
/// one repaint and costing sixty. The rings redraw whenever `progress` moves —
/// which, now that a scan grows rather than jump-cuts, is every display frame
/// for the whole of a scan. Emphasis moves whenever the pointer does. Labels
/// have to be *placed*, which is a measuring pass over every candidate, and
/// placing them at the resting geometry means that pass runs once per layout
/// instead of once per animation frame.
///
/// Put all three in one `Canvas` and every one of those clocks invalidates all
/// of the others. That is the shape the previous version had, and it is why
/// animating the scan at all would have been unaffordable.
struct SunburstCanvas: View {
    var progress: Double
    var hoverPhase: Double
    var pressPhase: Double
    let current: SunburstIndex
    let departing: SunburstIndex?
    let timing: SunburstAnimation.Timing
    let metrics: SunburstMetrics
    let table: SunburstColorTable
    let gradients: MarkGradientTable
    let hoverA: SunburstHoverTarget
    let hoverB: SunburstHoverTarget
    let pressed: SunburstPosition?
    let keyboardFocus: SunburstPosition?
    let search: SunburstSearchResult
    let options: SunburstOptions
    /// Dash travel accumulated by earlier scan ticks, so the provisional edge on
    /// a directory still being walked marches continuously instead of restarting.
    let dashSeed: Double
    /// True only while a zoom plays. Hover is meaningless while the geometry is
    /// moving and a label chasing a sliding wedge reads as a glitch — but a scan
    /// tick must not hide either, or the names are gone for the whole scan.
    let hidesOverlays: Bool

    var body: some View {
        ZStack {
            SunburstChart(progress: progress, current: current, departing: departing,
                          timing: timing, metrics: metrics, table: table,
                          gradients: gradients, search: search, dashSeed: dashSeed)
            if !hidesOverlays {
                SunburstEmphasisLayer(hoverPhase: hoverPhase, pressPhase: pressPhase,
                                      current: current, metrics: metrics, table: table,
                                      gradients: gradients, hoverA: hoverA, hoverB: hoverB,
                                      pressed: pressed, keyboardFocus: keyboardFocus)
                    .allowsHitTesting(false)
                if options.showsWedgeLabels {
                    SunburstLabelLayer(current: current, metrics: metrics, table: table,
                                       hovered: hoverPhase >= 0.5 ? hoverB.position : hoverA.position,
                                       keyboardFocus: keyboardFocus, search: search)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Rings

/// The rings themselves. `Animatable` so SwiftUI drives `progress` frame by
/// frame; everything else about it is a plain immutable draw.
struct SunburstChart: View, @MainActor Animatable {
    var progress: Double
    let current: SunburstIndex
    let departing: SunburstIndex?
    let timing: SunburstAnimation.Timing
    let metrics: SunburstMetrics
    let table: SunburstColorTable
    let gradients: MarkGradientTable
    let search: SunburstSearchResult
    let dashSeed: Double

    /// Below this much arc a gradient is a waste of a rasteriser: there is not
    /// enough of the mark on screen for two stops to be distinguishable, and a
    /// chart of six thousand wedges is mostly slivers. `SunburstShading(flat:)`
    /// exists for exactly this case.
    ///
    /// It is also the entire reason the dimensional fill is affordable. Measured
    /// on 3280 wedges in a 900pt square, release build: flat everywhere 2.66 ms
    /// a frame, this threshold 2.65 ms, gradients on every sliver 3.55 ms at
    /// rest and 7.4 ms mid-transition with frames as bad as 20. The ~11% of
    /// wedges wide enough to show a gradient are free; the other 89% are not.
    static let gradientMinimumArc: Double = 3

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, _ in
            draw(&context)
        }
    }

    // MARK: - Draw

    private func draw(_ context: inout GraphicsContext) {
        guard metrics.ringThickness > 0 else { return }
        // Semantic, so the hairlines are right in both appearances without a
        // second palette. The wedge fills are the only non-semantic colour here.
        let separator = Color.primary.opacity(0.10)
        var hatchBudget = 96

        // The camera, not the data: uniform on every ring, so it changes no
        // proportion the chart is encoding. A sunburst spends *angle* on size
        // and radius on depth, and this only touches radius.
        //
        // Clamped against the geometry rather than trusted. The timing declares
        // an intent in the abstract; only the metrics know how much room there
        // actually is before the outer ring leaves the window.
        let camera = min(timing.cameraScale(at: progress), metrics.maximumCameraScale)

        if let departing, progress < 1 {
            for frame in SunburstAnimation.frames(from: departing, to: current,
                                                  progress: progress, timing: timing) {
                drawSector(&context, frame: frame, camera: camera,
                           separator: separator, hatchBudget: &hatchBudget)
            }
            return
        }

        for wedge in current.wedges {
            drawSector(&context, frame: SunburstFrame(resting: wedge), camera: 1,
                       separator: separator, hatchBudget: &hatchBudget)
        }
    }

    private func drawSector(_ context: inout GraphicsContext, frame: SunburstFrame,
                            camera: Double, separator: Color, hatchBudget: inout Int) {
        var radii = metrics.radii(forRingPosition: frame.ring)
        if camera != 1 {
            // Anchored at the centre disc's edge rather than at the centre
            // point. See `Timing.cameraScale`: the disc is a control layered
            // above this canvas and does not scale with it, so a camera about
            // the point would leave a visible gap around it.
            let hole = metrics.centreRadius
            radii = (hole + (radii.inner - hole) * camera,
                     hole + (radii.outer - hole) * camera)
        }
        // A settle is allowed to carry a wedge briefly inside the ring it came
        // from; it is not allowed to invert the annulus.
        let ringInner = max(0, radii.inner)
        // The gap between rings is cosmetic only. Hit testing uses the full
        // annulus, because a groove you can lose a click in is a chart that
        // ignores you.
        let radialInset = min(1.2, metrics.ringThickness * 0.06)
        let outer = radii.outer - radialInset
        guard outer > ringInner else { return }

        let sweep = frame.endAngle - frame.startAngle
        let arc = sweep * outer
        // Under about a third of a pixel of arc there is nothing to see. The
        // projector already merged anything genuinely sub-pixel at its assumed
        // radius; this catches what a small window squeezes further.
        guard arc >= 0.35 else { return }

        let pad = sweep >= SunburstAngle.fullTurn - 1e-9 ? 0 : min(0.0035, sweep * 0.08)
        let path = sunburstSectorPath(center: metrics.center, innerRadius: ringInner,
                                      outerRadius: outer,
                                      start: frame.startAngle + pad, end: frame.endAngle - pad)

        let restoreOpacity = context.opacity
        // A search dims what it did not find rather than removing it: the shape
        // of the disk has to stay intact or the user loses the spatial bearings
        // that are the whole reason for drawing it this way.
        let emphasis = search.opacity(for: frame.wedge.id)
        let opacity = frame.opacity * emphasis
        if opacity < 1 { context.opacity = opacity }
        context.fill(path, with: fill(for: frame, ringInner: ringInner, ringOuter: radii.outer,
                                      arc: arc),
                     style: FillStyle(eoFill: true))
        if arc >= 6 {
            context.stroke(path, with: .color(separator), lineWidth: 0.5)
        }
        if search.isDimming, emphasis >= 1, arc >= 4 {
            // Dimming alone is a comparative signal, and a lone match on a
            // sparse ring has nothing to be compared with. Outline it too.
            context.stroke(path, with: .color(Color.accentColor.opacity(0.9)), lineWidth: 1.5)
        }
        if frame.wedge.isAggregated, hatchBudget > 0, arc >= 8, metrics.ringThickness >= 8 {
            hatchBudget -= 1
            drawHatch(&context, path: path, wedge: frame.wedge)
        }
        if frame.wedge.isStillScanning, arc >= 10 {
            drawGrowingEdge(&context, frame: frame, outerRadius: outer, pad: pad)
        }
        context.opacity = restoreOpacity
    }

    /// The dimensional fill.
    ///
    /// The gradient's radii are the **ring's**, not the wedge's drawn bounds, and
    /// its centre is the chart's. That is the whole point: every wedge in a ring
    /// is a window onto the same radial ramp, so the ring reads as one lit band
    /// and the boundaries between wedges stay boundaries of *colour* rather than
    /// turning into a row of individually-lit beads. Giving each wedge its own
    /// axis was tried and looks like corrugated iron.
    private func fill(for frame: SunburstFrame, ringInner: Double, ringOuter: Double,
                      arc: Double) -> GraphicsContext.Shading {
        guard arc >= Self.gradientMinimumArc else {
            return .color(table.color(for: frame.wedge))
        }
        return .radialGradient(gradients.gradient(for: frame.wedge),
                               center: metrics.center,
                               startRadius: ringInner, endRadius: ringOuter)
    }

    private func drawHatch(_ context: inout GraphicsContext, path: Path, wedge: Wedge) {
        drawDiagonalHatch(&context, path: path,
                          ink: table.palette.hatchInk(on: table.swatch(for: wedge)))
    }

    /// A dashed outer edge on a directory still being walked: the boundary is
    /// provisional, and a dashed line is the conventional way to say so.
    ///
    /// The dashes travel while — and only while — layouts are still arriving.
    /// Motion here is not decoration: a still edge means nothing is being
    /// measured, and that is exactly what a still edge will mean once the walk
    /// stops and `dashSeed` stops advancing. Under Reduce Motion the caller
    /// holds `dashSeed` at zero and the dashes simply sit there, which loses the
    /// liveness cue but keeps the provisional-boundary one, which is the load-
    /// bearing half.
    private func drawGrowingEdge(_ context: inout GraphicsContext, frame: SunburstFrame,
                                 outerRadius: Double, pad: Double) {
        let ink = table.palette.hatchInk(on: table.swatch(for: frame.wedge))
        var edge = Path()
        edge.addArc(center: metrics.center, radius: max(0, outerRadius - 1.25),
                    startAngle: .radians(frame.startAngle + pad - .pi / 2),
                    endAngle: .radians(frame.endAngle - pad - .pi / 2),
                    clockwise: false)
        context.stroke(edge, with: .color(ink),
                       style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: [2.5, 2.5],
                                          dashPhase: (dashSeed + progress) * 5))
    }
}

// MARK: - Emphasis

/// Hover, click and keyboard focus. A separate canvas from the rings so that
/// twenty frames of a hover lift cost twenty repaints of *this*, which is a
/// handful of shapes, rather than twenty repaints of six thousand wedges.
struct SunburstEmphasisLayer: View, @MainActor Animatable {
    /// 0 means `hoverA` is showing, 1 means `hoverB` is. Hover changes flip the
    /// target between the two slots rather than resetting a single value, which
    /// is what lets one wedge fade out while the next fades in — and avoids the
    /// extra main-actor hop a 1 → 0 → 1 reset would need to animate at all.
    var hoverPhase: Double
    var pressPhase: Double
    let current: SunburstIndex
    let metrics: SunburstMetrics
    let table: SunburstColorTable
    let gradients: MarkGradientTable
    let hoverA: SunburstHoverTarget
    let hoverB: SunburstHoverTarget
    let pressed: SunburstPosition?
    let keyboardFocus: SunburstPosition?

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(hoverPhase, pressPhase) }
        set { hoverPhase = newValue.first; pressPhase = newValue.second }
    }

    var body: some View {
        Canvas { context, _ in
            draw(&context)
        }
    }

    private func draw(_ context: inout GraphicsContext) {
        guard metrics.ringThickness > 0 else { return }
        // Ancestors first, then the hovered wedge on top of them, then the
        // keyboard ring on top of everything — the keyboard ring is the one
        // piece of state a user cannot see any other way.
        drawHover(&context, target: hoverA, strength: 1 - hoverPhase)
        drawHover(&context, target: hoverB, strength: hoverPhase)
        drawPress(&context)
        drawKeyboardFocus(&context)
    }

    /// Inner and outer radius for a wedge that is riding `lift` points out of
    /// its ring. The inner edge follows at a fraction of the outer one, so the
    /// wedge grows very slightly as it lifts: a shape that only translates reads
    /// as sliding, and a shape that grows at the far edge reads as rising.
    private func path(for position: SunburstPosition, lift: Double = 0,
                      inset: Double = 0) -> Path? {
        guard let wedge = current[position] else { return nil }
        let radii = metrics.radii(forRing: position.ring)
        let radialInset = min(1.2, metrics.ringThickness * 0.06)
        let outer = radii.outer - radialInset - inset + lift
        let inner = radii.inner + inset + lift * 0.35
        guard outer > inner, inner >= 0 else { return nil }
        let sweep = wedge.sweep
        let pad = sweep >= SunburstAngle.fullTurn - 1e-9 ? 0 : min(0.0035, sweep * 0.08)
        return sunburstSectorPath(center: metrics.center, innerRadius: inner, outerRadius: outer,
                                  start: wedge.startAngle + pad, end: wedge.endAngle - pad)
    }

    private func drawHover(_ context: inout GraphicsContext, target: SunburstHoverTarget,
                           strength: Double) {
        let s = min(max(strength, 0), 1)
        guard s > 0.004, !target.isEmpty else { return }
        let restore = context.opacity

        for position in target.chain where position != target.position {
            guard let wedge = current[position], let path = path(for: position) else { continue }
            context.opacity = restore * s
            context.fill(path, with: .color(table.color(for: wedge, highlighted: true)),
                         style: FillStyle(eoFill: true))
            context.stroke(path, with: .color(Color.primary.opacity(0.20)), lineWidth: 1)
        }

        if let position = target.position, let wedge = current[position] {
            let radii = metrics.radii(forRing: position.ring)
            let lift = SunburstAnimation.hoverLift * s
            guard let path = path(for: position, lift: lift) else {
                context.opacity = restore
                return
            }
            context.opacity = restore * s
            // Brightened *and* lifted. Either alone is ambiguous on a chart
            // where neighbouring wedges are already different colours; together
            // they read as one shape coming forward.
            context.fill(path, with: .radialGradient(gradients.gradient(for: wedge,
                                                                       highlighted: true),
                                                     center: metrics.center,
                                                     startRadius: radii.inner + lift * 0.35,
                                                     endRadius: radii.outer + lift),
                         style: FillStyle(eoFill: true))
            context.stroke(path, with: .color(Color.primary.opacity(0.55)), lineWidth: 1.5)
            // A catch-light along the outer arc, taken from the lit end of this
            // wedge's own gradient rather than from white. A white rim would be
            // a glow; this is the same light source the whole disk already has,
            // caught on an edge that has moved into it.
            if let rim = outerArc(for: position, lift: lift) {
                let lit = table.palette.shading(for: wedge, scheme: table.scheme,
                                                highlighted: true).inner
                context.stroke(rim, with: .color(lit.color), lineWidth: 1)
            }
        }
        context.opacity = restore
    }

    private func outerArc(for position: SunburstPosition, lift: Double) -> Path? {
        guard let wedge = current[position] else { return nil }
        let radii = metrics.radii(forRing: position.ring)
        let radialInset = min(1.2, metrics.ringThickness * 0.06)
        let radius = radii.outer - radialInset + lift - 0.5
        guard radius > 0 else { return nil }
        let sweep = wedge.sweep
        let pad = sweep >= SunburstAngle.fullTurn - 1e-9 ? 0 : min(0.0035, sweep * 0.08)
        var arc = Path()
        arc.addArc(center: metrics.center, radius: radius,
                   startAngle: .radians(wedge.startAngle + pad - .pi / 2),
                   endAngle: .radians(wedge.endAngle - pad - .pi / 2), clockwise: false)
        return arc
    }

    /// The click, acknowledged before the geometry moves.
    ///
    /// Deliberately the opposite gesture from hover: hover rises, a press goes
    /// *in*. A click that made the wedge rise further would be indistinguishable
    /// from the pointer having arrived, which is the state the user is already in.
    private func drawPress(_ context: inout GraphicsContext) {
        guard let pressed, let wedge = current[pressed] else { return }
        let pulse = SunburstAnimation.pressPulse(pressPhase)
        guard pulse > 0.004 else { return }
        guard let path = path(for: pressed, lift: -SunburstAnimation.pressDepth * pulse,
                              inset: SunburstAnimation.pressDepth * pulse) else { return }
        let restore = context.opacity
        context.opacity = restore * pulse
        context.fill(path, with: .color(table.color(for: wedge, highlighted: true)),
                     style: FillStyle(eoFill: true))
        context.stroke(path, with: .color(Color.primary.opacity(0.7)), lineWidth: 2)
        context.opacity = restore
    }

    private func drawKeyboardFocus(_ context: inout GraphicsContext) {
        guard let keyboardFocus, let wedge = current[keyboardFocus] else { return }
        // Deliberately a different *kind* of mark from hover: hover lifts the
        // fill and draws a soft hairline, keyboard focus draws a hard accent
        // ring. They have to be told apart at a glance when both are showing.
        if let ring = path(for: keyboardFocus, inset: 1.5) {
            context.stroke(ring, with: .color(Color.accentColor), lineWidth: 3)
        }
        if let inner = path(for: keyboardFocus, inset: 3.5) {
            let ink = table.palette.labelInk(on: table.swatch(for: wedge))
            context.stroke(inner, with: .color(ink.opacity(0.55)), lineWidth: 1)
        }
    }
}

// MARK: - Labels

/// Names on the shapes big enough to hold one.
///
/// Every decision here — which wedges are candidates, how much room each one
/// has, what gets truncated and what collides with what — lives in
/// `SunburstLabels` and `LabelPlacement`, which are pure and tested. This view
/// measures strings through a cache and draws the answer.
///
/// It is deliberately *not* `Animatable`. Labels are placed at the resting
/// geometry even while the rings are still easing into it, so a growing wedge's
/// name leads it by a few degrees for a tenth of a second. The alternative is
/// re-running a global collision pass on every display frame of a scan, which
/// would cost more than the drawing does and would also make the labels jitter
/// as the placement flips between two nearly-equal solutions.
struct SunburstLabelLayer: View {
    let current: SunburstIndex
    let metrics: SunburstMetrics
    let table: SunburstColorTable
    let hovered: SunburstPosition?
    let keyboardFocus: SunburstPosition?
    let search: SunburstSearchResult

    var body: some View {
        Canvas { context, _ in
            draw(&context)
        }
    }

    private func draw(_ context: inout GraphicsContext) {
        guard metrics.ringThickness > 0 else { return }
        var slots = SunburstLabels.slots(for: current, metrics: metrics,
                                         hovered: hovered, keyboardFocus: keyboardFocus)
        guard !slots.isEmpty else { return }
        if search.isDimming {
            // While a search is running the names worth reading are the hits.
            slots = slots.filter { search.matched.contains($0.id) || $0.isForced }
            guard !slots.isEmpty else { return }
        }

        // A copy, so the measuring closure does not capture the inout context.
        // `GraphicsContext` is a value and resolving text does not mutate it.
        let measuringContext = context
        let cache = LabelTextCache.shared
        let font = SunburstLabels.font
        let placed = LabelPlacement.place(slots: slots) { text in
            cache.size(of: text, font: font, in: measuringContext)
        }

        drawPlacedLabels(&context, placed: placed, font: font, scheme: table.scheme) { id in
            guard let position = current.position(ofNode: NodeRef(rawValue: id)),
                  let wedge = current[position] else { return nil }
            return table.palette.labelInk(on: table.swatch(for: wedge))
        }
    }
}
