import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI

// MARK: - Colour

/// Every fill a bubble layout can need, resolved once.
///
/// The sibling of `SunburstColorTable` and built for the same reason — a fill is
/// a pure function of `(colorSeed, depth, kind, highlighted)` and all four are
/// small, so 240 entries cover a chart of three thousand circles and the draw
/// loop only ever does an array subscript.
///
/// It is a separate table rather than a use of that one because a bubble is not
/// filled with a colour. It is filled with a *gradient* — `SunburstShading` —
/// and the ink that has to stay legible over it must be chosen against the
/// palette's reference swatch, not against either end of the ramp. Those are two
/// values per slot that the flat table has no place to keep.
struct BubbleShadingTable: Sendable {
    /// One more than the deepest level the packer will emit.
    static let depthSlots = Int(BubbleGeometry.maximumDepth)
    private static let kindSlots = 3
    private static let stateSlots = 2

    let palette: SunburstPalette
    let scheme: ColorScheme

    private let seedCount: Int
    private let shadings: [SunburstShading]
    /// The palette's reference swatch for the slot — what ink is chosen against,
    /// and what the legend draws. See `SunburstShading`'s doc comment for why
    /// this and not either end of the gradient.
    private let swatches: [SunburstSwatch]
    private let gradients: [Gradient]
    private let inks: [Color]
    private let hatches: [Color]

    init(palette: SunburstPalette, scheme: ColorScheme) {
        self.palette = palette
        self.scheme = scheme
        let seeds = max(1, palette.swatchCount(scheme))
        seedCount = seeds

        var builtShadings: [SunburstShading] = []
        var builtSwatches: [SunburstSwatch] = []
        var builtGradients: [Gradient] = []
        var builtInks: [Color] = []
        var builtHatches: [Color] = []
        let total = seeds * Self.depthSlots * Self.kindSlots * Self.stateSlots
        builtShadings.reserveCapacity(total)
        builtSwatches.reserveCapacity(total)
        builtGradients.reserveCapacity(total)
        builtInks.reserveCapacity(total)
        builtHatches.reserveCapacity(total)

        for seed in 0..<seeds {
            for depth in 0..<Self.depthSlots {
                for kind in 0..<Self.kindSlots {
                    for state in 0..<Self.stateSlots {
                        let resolved = Self.kind(at: kind)
                        let swatch = palette.swatch(seed: UInt16(seed), ring: UInt8(depth),
                                                    kind: resolved, scheme: scheme,
                                                    highlighted: state == 1)
                        let shading = palette.shading(seed: UInt16(seed), ring: UInt8(depth),
                                                      kind: resolved, scheme: scheme,
                                                      highlighted: state == 1)
                        builtShadings.append(shading)
                        builtSwatches.append(swatch)
                        builtGradients.append(Gradient(colors: shading.colors))
                        builtInks.append(palette.labelInk(on: swatch))
                        builtHatches.append(palette.hatchInk(on: swatch))
                    }
                }
            }
        }
        shadings = builtShadings
        swatches = builtSwatches
        gradients = builtGradients
        inks = builtInks
        hatches = builtHatches
    }

    private static func kind(at slot: Int) -> WedgeKind {
        switch slot {
        case 1: .aggregated(count: 0)
        case 2: .stillScanning
        default: .real
        }
    }

    private static func slot(for kind: WedgeKind) -> Int {
        switch kind {
        case .real: 0
        case .aggregated: 1
        case .stillScanning: 2
        }
    }

    @inline(__always)
    private func offset(_ circle: BubbleCircle, highlighted: Bool) -> Int {
        let seedIndex = Int(circle.colorSeed) % seedCount
        // A layout should never exceed `maximumDepth`, but a clamp here is
        // cheaper than an out-of-bounds crash if a packer ever slips.
        let depthIndex = min(Int(circle.depth), Self.depthSlots - 1)
        return ((seedIndex * Self.depthSlots + depthIndex) * Self.kindSlots
            + Self.slot(for: circle.kind)) * Self.stateSlots + (highlighted ? 1 : 0)
    }

    func gradient(for circle: BubbleCircle, highlighted: Bool = false) -> Gradient {
        gradients[offset(circle, highlighted: highlighted)]
    }

    func shading(for circle: BubbleCircle, highlighted: Bool = false) -> SunburstShading {
        shadings[offset(circle, highlighted: highlighted)]
    }

    func swatch(for circle: BubbleCircle, highlighted: Bool = false) -> SunburstSwatch {
        swatches[offset(circle, highlighted: highlighted)]
    }

    func color(for circle: BubbleCircle, highlighted: Bool = false) -> Color {
        swatches[offset(circle, highlighted: highlighted)].color
    }

    func ink(for circle: BubbleCircle, highlighted: Bool = false) -> Color {
        inks[offset(circle, highlighted: highlighted)]
    }

    func hatch(for circle: BubbleCircle, highlighted: Bool = false) -> Color {
        hatches[offset(circle, highlighted: highlighted)]
    }
}

// MARK: - Sphere geometry

/// Where the light is, and how a flat disc is turned into a ball by it.
///
/// Fixed in the *view*, not in the mark: every bubble is lit from the same
/// upper-left, which is what makes a screen of them read as a tray of spheres
/// rather than as a hundred separate objects each with its own sun.
enum BubbleLighting {
    /// The light point, as a fraction of the radius from the centre. Up and to
    /// the left, the direction every shaded UI object on this platform has been
    /// lit from for forty years.
    static let offset: Double = 0.42

    /// How far the gradient runs, as a multiple of the radius.
    ///
    /// The light point is `offset · √2 · r` from the centre, so the far rim is
    /// `1 + offset · √2 ≈ 1.59` radii away from it. Stopping short of that would
    /// leave a flat band of the darkest colour around the bottom-right; running
    /// well past it would compress the whole ramp into the lit side and the ball
    /// would look like a disc with a smudge on it.
    static let reach: Double = 1.62

    /// Below this drawn radius a gradient is a waste of a shading object: the
    /// mark is a few pixels across and the two ends of the ramp land in the same
    /// pixel. Flat fill instead, which is also what keeps a level of three
    /// thousand crumbs inside the frame budget.
    static let gradientFloor: Double = 3.5
    /// Below this, no specular highlight either — it would be one bright pixel
    /// sitting on a two-pixel mark and would read as noise.
    static let specularFloor: Double = 9
    /// How many specular highlights one frame may draw. They are the most
    /// expensive mark here and past a few dozen balls nobody is looking at any
    /// individual one.
    static let specularBudget = 64

    static func lightPoint(centre: CGPoint, radius: Double) -> CGPoint {
        CGPoint(x: centre.x - radius * offset, y: centre.y - radius * offset)
    }
}

// MARK: - The chart

/// The bubbles themselves.
///
/// Painted in the contract's order — shallowest first — so parents end up
/// beneath their children with no sorting and no depth buffer. `Animatable` so
/// SwiftUI drives `progress` frame by frame during a zoom; everything else about
/// it is a plain immutable draw.
struct BubbleChart: View, @MainActor Animatable {
    var progress: Double
    let current: BubbleIndex
    let departing: BubbleIndex?
    let metrics: BubbleMetrics
    let table: BubbleShadingTable
    let hovered: BubblePosition?
    let hoverChain: Set<BubblePosition>
    let keyboardFocus: BubblePosition?
    let search: SunburstSearchResult
    let options: SunburstOptions
    /// The user has asked for less transparency. Soft shadows and specular
    /// bloom both work by being see-through; the information they carry is
    /// re-stated as solid edges instead.
    let reduceTransparency: Bool

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
        guard !metrics.isDegenerate, !current.isEmpty else { return }
        var specularBudget = reduceTransparency ? 0 : BubbleLighting.specularBudget
        var hatchBudget = 96

        if let departing, progress < 1 {
            for frame in BubbleAnimation.frames(from: departing, to: current, progress: progress) {
                drawBubble(&context, frame: frame,
                           specularBudget: &specularBudget, hatchBudget: &hatchBudget)
            }
            // No emphasis mid-zoom: hover is meaningless while the camera is
            // moving, and a focus ring chasing a sliding circle reads as a glitch.
            return
        }

        for circle in current.circles {
            drawBubble(&context, frame: BubbleFrame(resting: circle),
                       specularBudget: &specularBudget, hatchBudget: &hatchBudget)
        }
        drawEmphasis(&context)
        if options.showsWedgeLabels { drawLabels(&context) }
    }

    private func drawBubble(_ context: inout GraphicsContext, frame: BubbleFrame,
                            specularBudget: inout Int, hatchBudget: inout Int,
                            highlighted: Bool = false, lift: Double = 1) {
        let centre = metrics.point(x: frame.centerX, y: frame.centerY)
        let radius = metrics.length(frame.radius) * lift
        // Under about half a point there is nothing to see. The packer already
        // merged anything genuinely sub-pixel at its own assumed size; this
        // catches what a small window squeezes further.
        guard radius >= 0.5, radius.isFinite, centre.x.isFinite, centre.y.isFinite else { return }
        let box = CGRect(x: centre.x - radius, y: centre.y - radius,
                         width: radius * 2, height: radius * 2)
        // Cheap frustum cull. A zoom flings the departing layout well outside
        // the view and every one of those circles would otherwise be composited.
        guard box.intersects(metrics.bounds) else { return }
        let path = Path(ellipseIn: box)

        let restoreOpacity = context.opacity
        // A search dims what it did not find rather than removing it: the shape
        // of the pack has to stay intact or the user loses their bearings.
        let emphasis = search.opacity(for: frame.circle.id) * frame.opacity
        if emphasis < 1 { context.opacity = max(0, emphasis) }
        defer { context.opacity = restoreOpacity }
        guard emphasis > 0.004 else { return }

        if radius >= BubbleLighting.gradientFloor {
            context.fill(path, with: .radialGradient(
                table.gradient(for: frame.circle, highlighted: highlighted),
                center: BubbleLighting.lightPoint(centre: centre, radius: radius),
                startRadius: 0, endRadius: radius * BubbleLighting.reach))
        } else {
            context.fill(path, with: .color(table.color(for: frame.circle, highlighted: highlighted)))
        }

        if radius >= BubbleLighting.specularFloor, specularBudget > 0 {
            specularBudget -= 1
            drawSpecular(&context, centre: centre, radius: radius)
        }

        if radius >= 2 {
            // The terminator: a hairline round the rim, semantic so it is right
            // in both appearances. It is what separates two balls of the same
            // hue that the packing has left touching, and — with Reduce
            // Transparency on, where the specular bloom is gone — it is the only
            // thing left saying where one ends.
            context.stroke(path,
                           with: .color(Color.primary.opacity(reduceTransparency ? 0.30 : 0.14)),
                           lineWidth: reduceTransparency ? 1 : 0.6)
        }

        if search.isDimming, emphasis >= 1, radius >= 2 {
            // Dimming alone is a comparative signal, and a lone match among a
            // handful of circles has nothing to be compared with.
            context.stroke(path, with: .color(Color.accentColor.opacity(0.9)), lineWidth: 1.5)
        }
        if frame.circle.isAggregated, hatchBudget > 0, radius >= 5 {
            hatchBudget -= 1
            drawDiagonalHatch(&context, path: path, ink: table.hatch(for: frame.circle))
        }
        if frame.circle.isStillScanning, radius >= 6 {
            // A dashed edge on a directory still being walked: the boundary is
            // provisional, and a dashed line is the conventional way to say so.
            context.stroke(Path(ellipseIn: box.insetBy(dx: 1.5, dy: 1.5)),
                           with: .color(table.hatch(for: frame.circle)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: [2.5, 2.5]))
        }
    }

    /// The glint that turns a shaded disc into a ball.
    ///
    /// Drawn as its own soft radial rather than as extra stops in the fill,
    /// because the fill's two ends are the palette's contract — `SunburstShading`
    /// pins the ink's contrast against exactly those two swatches, and adding a
    /// near-white stop inside the ramp would quietly break that. A separate,
    /// small, translucent mark near the light point cannot, because the label
    /// pass already refuses to write across the top-left of a circle.
    private func drawSpecular(_ context: inout GraphicsContext, centre: CGPoint, radius: Double) {
        let glintRadius = radius * 0.42
        let point = CGPoint(x: centre.x - radius * 0.40, y: centre.y - radius * 0.44)
        let box = CGRect(x: point.x - glintRadius, y: point.y - glintRadius,
                         width: glintRadius * 2, height: glintRadius * 2)
        context.fill(Path(ellipseIn: box), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(table.scheme == .dark ? 0.20 : 0.34),
                              Color.white.opacity(0)]),
            center: point, startRadius: 0, endRadius: glintRadius))
    }

    // MARK: - Emphasis

    private func circleRect(for position: BubblePosition, lift: Double = 1) -> CGRect? {
        guard let circle = current[position] else { return nil }
        let centre = metrics.center(of: circle)
        let radius = metrics.radius(of: circle) * lift
        guard radius > 0 else { return nil }
        return CGRect(x: centre.x - radius, y: centre.y - radius,
                      width: radius * 2, height: radius * 2)
    }

    private func drawEmphasis(_ context: inout GraphicsContext) {
        // Ancestors first, then the hovered circle on top of them, then the
        // keyboard ring on top of everything — exactly the other two charts'
        // order and exactly their two marks, so the three are learned once.
        for position in hoverChain where position != hovered {
            // Ancestors are outlined rather than refilled: they are underneath
            // their children, so lifting their fill would show only in the thin
            // ring the packing leaves round the outside.
            guard let rect = circleRect(for: position) else { continue }
            context.stroke(Path(ellipseIn: rect),
                           with: .color(Color.primary.opacity(0.35)), lineWidth: 1.5)
        }

        if let hovered { drawLift(&context, at: hovered) }

        if let keyboardFocus, let circle = current[keyboardFocus],
           let rect = circleRect(for: keyboardFocus, lift: 1.04) {
            context.stroke(Path(ellipseIn: rect), with: .color(Color.accentColor), lineWidth: 3)
            let inner = rect.insetBy(dx: 2.5, dy: 2.5)
            if inner.width > 0 {
                context.stroke(Path(ellipseIn: inner),
                               with: .color(table.ink(for: circle).opacity(0.55)), lineWidth: 1)
            }
        }
    }

    /// The hover lift: the ball under the pointer comes towards you — and it
    /// brings its contents with it.
    ///
    /// Redrawn a few percent larger with a shadow under it rather than merely
    /// recoloured, because in a pack every circle is already surrounded by other
    /// circles of the same family: a brightness change alone reads as "that one
    /// is a different colour", not as "that one is the one I am pointing at".
    /// The size change is the signal; the shadow is what makes it read as height
    /// rather than as growth.
    ///
    /// The subtree is scaled about the same centre by the same factor and
    /// redrawn on top. Filling the lifted circle and stopping there is the
    /// obvious version and it is wrong twice over: it hides the folder's
    /// contents at the exact moment the user is asking about the folder, and a
    /// ball that loses its texture when you point at it reads as *flattening*
    /// rather than as rising.
    private func drawLift(_ context: inout GraphicsContext, at position: BubblePosition) {
        guard let index = current.circleIndex(of: position) else { return }
        let circle = current.circles[index]
        let centre = metrics.center(of: circle)
        let radius = metrics.radius(of: circle)
        guard radius >= 1 else { return }
        // A small ball needs a proportionally bigger jump to be noticed at all;
        // a large one only needs a hint, because a five percent change across
        // two hundred points is already tens of points of movement.
        let factor = radius > 14 ? 1.05 : 1.18
        let lifted = radius * factor
        let box = CGRect(x: centre.x - lifted, y: centre.y - lifted,
                         width: lifted * 2, height: lifted * 2)
        let path = Path(ellipseIn: box)

        if reduceTransparency {
            context.fill(path, with: .color(table.color(for: circle, highlighted: true)))
        } else {
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: Color.black.opacity(0.38),
                                        radius: max(2, lifted * 0.22),
                                        x: 0, y: max(1, lifted * 0.10)))
                layer.fill(path, with: .radialGradient(
                    table.gradient(for: circle, highlighted: true),
                    center: BubbleLighting.lightPoint(centre: centre, radius: lifted),
                    startRadius: 0, endRadius: lifted * BubbleLighting.reach))
            }
            if lifted >= BubbleLighting.specularFloor {
                drawSpecular(&context, centre: centre, radius: lifted)
            }
        }
        if circle.isAggregated {
            drawDiagonalHatch(&context, path: path, ink: table.hatch(for: circle, highlighted: true))
        }

        var specularBudget = reduceTransparency ? 0 : 24
        var hatchBudget = 24
        for child in current.subtree(from: index) {
            let inner = current.circles[child]
            drawBubble(&context, frame: BubbleFrame(
                circle: inner,
                centerX: circle.centerX + (inner.centerX - circle.centerX) * factor,
                centerY: circle.centerY + (inner.centerY - circle.centerY) * factor,
                radius: inner.radius * factor, opacity: 1),
                specularBudget: &specularBudget, hatchBudget: &hatchBudget)
        }

        context.stroke(path, with: .color(Color.primary.opacity(0.55)), lineWidth: 1.5)
    }

    // MARK: - Labels

    /// The same pass the other two charts run, over slots built from circles
    /// instead of sectors or rectangles. Sharing it is the point: one non-overlap
    /// rule, one legibility floor, one truncation, tested once.
    private func drawLabels(_ context: inout GraphicsContext) {
        var slots = BubbleLabels.slots(for: current, metrics: metrics,
                                       hovered: hovered, keyboardFocus: keyboardFocus)
        guard !slots.isEmpty else { return }
        if search.isDimming {
            slots = slots.filter { search.matched.contains($0.id) || $0.isForced }
            guard !slots.isEmpty else { return }
        }

        let measuringContext = context
        let cache = LabelTextCache.shared
        let font = BubbleLabels.font
        let placed = LabelPlacement.place(slots: slots) { text in
            cache.size(of: text, font: font, in: measuringContext)
        }
        drawPlacedLabels(&context, placed: placed, font: font, scheme: table.scheme) { id in
            guard let position = current.position(ofNode: NodeRef(rawValue: id)),
                  let circle = current[position] else { return nil }
            return table.ink(for: circle, highlighted: position == hovered)
        }
    }
}

// MARK: - Label slots

/// Turning circle geometry into label slots.
///
/// Shares `LabelPlacement` with the other two charts, so the non-overlap rule is
/// literally the same code. What differs is only where a label may legitimately
/// go, and in a circle pack that is two questions at once: how much *chord* is
/// available at the height the text would sit at, and whether the middle of the
/// circle is its own colour or its children's.
enum BubbleLabels {
    static let font = SunburstLabels.font
    static let nominalLineHeight = SunburstLabels.nominalLineHeight
    /// The same legibility floor as the other two, for the same reason: four
    /// characters and an elision at 10pt is about 24pt of run, and a fragment
    /// shorter than that identifies nothing.
    static let minimumLabelWidth = SunburstLabels.minimumLabelWidth
    /// Clear space kept inside a circle's own rim.
    static let inset: Double = 3

    /// Where a parent's header sits, as a fraction of the radius above centre.
    ///
    /// A leaf is labelled across its middle, but a parent's middle is its
    /// children — the packing leaves only a thin ring of the parent showing, so a
    /// name written across the centre would look like a name for whichever child
    /// is under it. The header goes high in the circle, on a plate, which is the
    /// same answer `TreemapLabels` reaches for a tile buried under its own
    /// contents and for the same reason.
    static let headerHeight: Double = 0.60
    static let maximumHeaderWidth: Double = 200

    static let slotLimit: Int = 120

    static func slots(for index: BubbleIndex, metrics: BubbleMetrics,
                      hovered: BubblePosition? = nil,
                      keyboardFocus: BubblePosition? = nil,
                      limit: Int = slotLimit) -> [LabelSlot] {
        var slots: [LabelSlot] = []
        var forced = Set<UInt32>()
        guard !metrics.isDegenerate else { return slots }

        for position in [hovered, keyboardFocus] {
            guard let position, let i = index.circleIndex(of: position) else { continue }
            guard forced.insert(index.circles[i].id).inserted else { continue }
            if let slot = forcedSlot(index.circles[i], metrics: metrics) { slots.append(slot) }
        }
        guard limit > 0 else { return slots }

        var candidates: [(index: Int, priority: Double)] = []
        candidates.reserveCapacity(min(limit * 2, index.circles.count))
        for i in index.circles.indices where !forced.contains(index.circles[i].id) {
            let radius = metrics.radius(of: index.circles[i])
            // Cull before sorting, not after: a layout can hold three thousand
            // circles and almost none of them are big enough to hold a name, so
            // sorting the lot every frame would be work spent on nothing. The
            // floor is a diameter, because a circle's widest chord is the one
            // through its centre and nothing can beat it.
            guard radius * 2 >= minimumLabelWidth + inset * 2,
                  radius * 2 >= nominalLineHeight + inset * 2 else { continue }
            candidates.append((i, radius))
        }
        // Drawn radius, so the biggest balls claim their names first — the same
        // rule the other two apply to arc length and to area.
        candidates.sort { a, b in
            a.priority == b.priority ? a.index < b.index : a.priority > b.priority
        }

        var produced = 0
        for candidate in candidates {
            guard produced < limit else { break }
            if let slot = slot(index.circles[candidate.index], metrics: metrics) {
                slots.append(slot)
                produced += 1
            }
        }
        return slots
    }

    /// The half-width of the chord `dy` above or below a circle's centre, which
    /// is the only honest answer to "how much room does a line of text have in
    /// here" — a circle's bounding box is four-fifths bigger than the circle and
    /// a name budgeted against it would run out through the side.
    static func halfChord(radius: Double, offsetFromCentre dy: Double) -> Double {
        let squared = radius * radius - dy * dy
        return squared > 0 ? squared.squareRoot() : 0
    }

    static func slot(_ circle: BubbleCircle, metrics: BubbleMetrics) -> LabelSlot? {
        let text = SunburstDescription.chartLabel(for: circle.kind, name: circle.name)
        guard !text.isEmpty else { return nil }
        let centre = metrics.center(of: circle)
        let radius = metrics.radius(of: circle)
        let priority = radius

        if !circle.hasChildren {
            // A leaf is its own colour all the way across, so its name goes
            // through the middle where the chord is widest.
            let width = halfChord(radius: radius, offsetFromCentre: nominalLineHeight / 2) * 2
                - inset * 2
            guard width >= minimumLabelWidth else { return nil }
            return LabelSlot(id: circle.id, text: text, anchor: centre, rotation: 0,
                             widthBudget: width, heightBudget: nominalLineHeight,
                             priority: priority)
        }

        // Buried under its children. Only the outermost level earns a header:
        // the top-level folders are the coarse read of the whole volume, and
        // losing their names to their own contents would leave the chart
        // unreadable. Anything deeper stays unlabelled rather than stacking
        // plate on plate.
        guard circle.depth == 0 else { return nil }
        let anchorY = centre.y - radius * headerHeight
        // Budget against the *far* edge of the line box, so a descender cannot
        // poke out through the rim.
        let dy = radius * headerHeight + nominalLineHeight / 2
        let width = min(halfChord(radius: radius, offsetFromCentre: dy) * 2 - inset * 2,
                        maximumHeaderWidth)
        guard width >= minimumLabelWidth else { return nil }
        return LabelSlot(id: circle.id, text: text,
                         anchor: CGPoint(x: centre.x, y: anchorY), rotation: 0,
                         widthBudget: width, heightBudget: nominalLineHeight + 2,
                         priority: priority, wantsPlate: true)
    }

    static func forcedSlot(_ circle: BubbleCircle, metrics: BubbleMetrics) -> LabelSlot? {
        let text = SunburstDescription.chartLabel(for: circle.kind, name: circle.name)
        guard !text.isEmpty else { return nil }
        let centre = metrics.center(of: circle)
        let radius = metrics.radius(of: circle)
        return LabelSlot(id: circle.id, text: text, anchor: centre, rotation: 0,
                         widthBudget: max(0, radius * 2 - inset * 2),
                         heightBudget: max(0, radius * 2),
                         priority: 0, isForced: true)
    }
}
