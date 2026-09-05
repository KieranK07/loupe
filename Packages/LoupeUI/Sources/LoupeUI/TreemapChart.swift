import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI

// MARK: - The zoom transition

/// One tile, mid-transition.
///
/// The rectangle is carried separately from the tile because during a zoom it
/// is *not* the tile's rectangle: a folder that survives the zoom is somewhere
/// between where it used to be and where it is going, and for a third of a
/// second the only honest answer to "where is it" is a number that belongs to
/// neither layout.
public struct TreemapFrame: Sendable, Hashable {
    public let tile: TreemapTile
    public let rect: TreemapRect
    public let opacity: Double

    public init(tile: TreemapTile, rect: TreemapRect, opacity: Double) {
        self.tile = tile
        self.rect = rect
        self.opacity = opacity
    }

    /// A tile that is not moving. Building one of these is free, which matters
    /// because the steady state draws thousands of them per frame.
    public init(resting tile: TreemapTile) {
        self.init(tile: tile, rect: tile.frame, opacity: 1)
    }
}

/// The treemap's zoom transition, as pure arithmetic.
///
/// The sunburst's counterpart with the hard part removed. Wedges are matched by
/// `NodeRef` across the two layouts there and here, and for the same reason — a
/// folder that survives a zoom should slide and grow into its new place instead
/// of blinking out while a stranger blinks in. What differs is the
/// interpolation: an angle can go the wrong way round a circle, so
/// `SunburstAnimation` has to move the start angle the short way and carry the
/// sweep separately. A rectangle in normalised coordinates has no such
/// wraparound. Four independent lerps are not a simplification of the sunburst's
/// rule, they are the whole of the correct rule here.
public enum TreemapAnimation {
    /// The zoom clock is `SunburstAnimation`'s, borrowed rather than copied.
    ///
    /// Toggling between the two views must not change how long the disk takes to
    /// answer, and two constants that merely *agree* today are two constants
    /// that will disagree the first time either is tuned.
    public static var duration: Double { SunburstAnimation.duration }
    public static var entryDelay: Double { SunburstAnimation.entryDelay }
    public static var exitFraction: Double { SunburstAnimation.exitFraction }

    /// And the same clock for a mark rising to meet the pointer.
    public static var liftDuration: Double { SunburstAnimation.hoverDuration }

    /// The *curve*, though, is not shared, and that is not an oversight.
    ///
    /// The sunburst's zoom settles with an overshoot. A wedge that overshoots
    /// rotates a degree past its slot and comes back, which reads as weight. A
    /// treemap tiles its container exactly — a rectangle that overshoots is a
    /// rectangle lying on top of its neighbours, and there is nowhere for the
    /// overshoot to go. So: the same duration and the same schedule, eased.
    public static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }

    public static func lift(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: liftDuration)
    }

    public static func interpolate(from old: TreemapRect, to new: TreemapRect,
                                   progress t: Double) -> TreemapRect {
        let clamped = min(max(t, 0), 1)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * clamped }
        return TreemapRect(x: lerp(old.x, new.x), y: lerp(old.y, new.y),
                           width: lerp(old.width, new.width),
                           height: lerp(old.height, new.height))
    }

    /// Every tile to draw at `progress`, outermost-first.
    ///
    /// `progress == 1` with no `from` is the steady state; callers should skip
    /// this entirely there and iterate the index directly, because this
    /// allocates and the steady state is the per-frame path.
    public static func frames(from old: TreemapIndex?, to new: TreemapIndex,
                              progress: Double) -> [TreemapFrame] {
        let t = min(max(progress, 0), 1)
        guard let old, t < 1 else { return new.tiles.map(TreemapFrame.init(resting:)) }

        var frames: [TreemapFrame] = []
        frames.reserveCapacity(new.tiles.count + old.tiles.count / 4)

        // Arrivals hold back until the survivors are most of the way home, so
        // the new level does not appear on top of geometry that is still
        // moving. Departures leave early for the same reason, in reverse.
        let entryOpacity = t <= entryDelay ? 0 : (t - entryDelay) / (1 - entryDelay)
        let exitOpacity = t >= exitFraction ? 0 : 1 - t / exitFraction

        var survivors = Set<UInt32>()
        survivors.reserveCapacity(new.tiles.count)

        for tile in new.tiles {
            // Only a valid, not-yet-claimed `NodeRef` identifies a survivor.
            // The claim check is here for the same reason as in the sunburst: if
            // two tiles ever did share a ref they must not both slide out of the
            // same rectangle — the second fades in instead, which is at worst
            // dull. Aggregates borrow the ref of the largest sibling they
            // swallowed, so this is not hypothetical.
            if tile.node.isValid,
               let position = old.position(ofNode: tile.node),
               let previous = old[position],
               survivors.insert(tile.id).inserted {
                frames.append(TreemapFrame(
                    tile: tile,
                    rect: interpolate(from: previous.frame, to: tile.frame, progress: t),
                    opacity: 1))
            } else {
                frames.append(TreemapFrame(tile: tile, rect: tile.frame, opacity: entryOpacity))
            }
        }

        if exitOpacity > 0 {
            for tile in old.tiles where !(tile.node.isValid && survivors.contains(tile.id)) {
                frames.append(TreemapFrame(tile: tile, rect: tile.frame, opacity: exitOpacity))
            }
        }

        // Departing tiles were appended out of order. The painter's algorithm is
        // the *only* thing keeping parents underneath their children here — there
        // is no depth buffer — so the order has to be restored before drawing,
        // and it has to be total or two runs of the same transition would paint
        // differently.
        frames.sort { a, b in
            if a.tile.depth != b.tile.depth { return a.tile.depth < b.tile.depth }
            if a.rect.y != b.rect.y { return a.rect.y < b.rect.y }
            if a.rect.x != b.rect.x { return a.rect.x < b.rect.x }
            return a.tile.id < b.tile.id
        }
        return frames
    }
}

// MARK: - Gradients

/// Every gradient a tile can be filled with, resolved once.
///
/// The same bargain `SunburstColorTable` strikes, for the same reason: a tile's
/// fill is a function of `(colorSeed, depth, kind, highlighted)` and nothing
/// else, all four are small, so build the lot up front and let the draw loop do
/// an array subscript. A `Gradient` built per tile per frame would be a few
/// thousand allocations sixty times a second, and a treemap of a real disk is
/// exactly the case where that shows up.
///
/// It sits alongside the colour table rather than replacing it, because
/// `SunburstPalette.swatch` remains the reference colour — it is what the legend
/// draws and what label ink is chosen against — and `shading` only ever spreads
/// a bounded distance either side of it. See `SunburstShading`.
struct TreemapShadingTable: Sendable {
    private static let kindSlots = 3
    private static let stateSlots = 2

    /// Below this, in points on the short side, a tile gets the flat reference
    /// colour instead. Two reasons, and the first is not the interesting one: a
    /// six-point tile cannot show a two-stop ramp. The second is that a real
    /// disk produces thousands of tiles this size and a linear gradient per one
    /// of them is a shading object per one of them.
    static let gradientThreshold: Double = 8

    private let seedCount: Int
    private let gradients: [Gradient]

    init(palette: SunburstPalette, scheme: ColorScheme) {
        let seeds = max(1, palette.swatchCount(scheme))
        seedCount = seeds
        var built: [Gradient] = []
        built.reserveCapacity(seeds * SunburstColorTable.ringSlots * Self.kindSlots * Self.stateSlots)
        for seed in 0..<seeds {
            for depth in 0..<SunburstColorTable.ringSlots {
                for kind in 0..<Self.kindSlots {
                    for state in 0..<Self.stateSlots {
                        let shading = palette.shading(seed: UInt16(seed), ring: UInt8(depth),
                                                      kind: Self.kind(at: kind), scheme: scheme,
                                                      highlighted: state == 1)
                        built.append(Gradient(colors: shading.colors))
                    }
                }
            }
        }
        gradients = built
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

    func gradient(for tile: TreemapTile, highlighted: Bool = false) -> Gradient {
        let seedIndex = Int(tile.colorSeed) % seedCount
        // A layout should never exceed `maximumRings`, but a clamp is cheaper
        // than an out-of-bounds crash if a projector ever slips.
        let depthIndex = min(Int(tile.depth), SunburstColorTable.ringSlots - 1)
        let offset = ((seedIndex * SunburstColorTable.ringSlots + depthIndex) * Self.kindSlots
            + Self.slot(for: tile.kind)) * Self.stateSlots + (highlighted ? 1 : 0)
        return gradients[offset]
    }

    /// Whether this tile is worth a gradient rather than the flat reference
    /// colour.
    ///
    /// An aggregate is excluded on principle rather than on size: it is several
    /// things wearing one coat, and a dimensional fill would make it read as a
    /// single solid object, which is the one thing it must never look like.
    /// `SunburstShading` already flattens it, so asking for the gradient anyway
    /// would spend a shading object drawing the same colour twice.
    static func usesGradient(rect: CGRect, kind: WedgeKind) -> Bool {
        if case .aggregated = kind { return false }
        return min(rect.width, rect.height) >= gradientThreshold
    }
}

// MARK: - The hover lift

/// How far the tile under the pointer rises out of the map.
///
/// Pure, because the interesting part is the cap: a lift is an outset, and an
/// outset large enough to read on a quarter of the window is large enough to
/// bury a tile's neighbours when the tile is twelve points across.
enum TreemapHoverLift {
    /// The most a tile ever grows, in points, on each side. The distance a
    /// hovered wedge rides out of its ring, so a mark answers the pointer by the
    /// same amount whichever chart it is in.
    static var maximumOutset: Double { SunburstAnimation.hoverLift }
    static let shadowRadius: Double = 8
    static let shadowOpacity: Double = 0.38

    /// Capped at a fraction of the short side, so a small tile lifts a little
    /// and a large one lifts fully. Without the cap the lift stops reading as
    /// "this tile came forward" and starts reading as "this tile grew", which
    /// is a lie about area in a chart whose whole claim is that area is size.
    static func outset(for rect: CGRect, progress: Double) -> Double {
        let cap = min(rect.width, rect.height) * 0.12
        return min(maximumOutset, max(0, cap)) * min(max(progress, 0), 1)
    }

    /// A lifted tile is a card, and a card has corners. Small enough to vanish
    /// on a small tile, where a visible radius would eat the tile's own area.
    static func cornerRadius(for rect: CGRect) -> Double {
        min(4, min(rect.width, rect.height) * 0.16)
    }
}

// MARK: - The chart

/// The tiles themselves.
///
/// Painted in the contract's order — outermost first — so parents end up
/// beneath their children with no sorting and no depth buffer. Each tile is
/// drawn a hair inside its own rectangle, which leaves a thread of the parent's
/// colour showing round every child; that gutter is the only thing that makes
/// nesting visible in a treemap, and it costs nothing.
///
/// `Animatable` on two numbers: `progress` drives the zoom, `hoverLift` the
/// tile under the pointer. One `Canvas` cannot animate anything by itself, so
/// every moving quantity in the map has to arrive here as a number SwiftUI is
/// interpolating.
struct TreemapChart: View, @MainActor Animatable {
    var progress: Double
    var hoverLift: Double
    let index: TreemapIndex
    /// The layout we are zooming away from, held only for the length of the
    /// transition. `nil` in the steady state, which is the fast path.
    let departing: TreemapIndex?
    let metrics: TreemapMetrics
    let table: SunburstColorTable
    let shading: TreemapShadingTable
    let hovered: TreemapPosition?
    let hoverChain: Set<TreemapPosition>
    let keyboardFocus: TreemapPosition?
    let search: SunburstSearchResult
    let options: SunburstOptions

    init(index: TreemapIndex,
         metrics: TreemapMetrics,
         table: SunburstColorTable,
         shading: TreemapShadingTable,
         departing: TreemapIndex? = nil,
         progress: Double = 1,
         hoverLift: Double = 1,
         hovered: TreemapPosition? = nil,
         hoverChain: Set<TreemapPosition> = [],
         keyboardFocus: TreemapPosition? = nil,
         search: SunburstSearchResult = .inactive,
         options: SunburstOptions = SunburstOptions()) {
        self.index = index
        self.metrics = metrics
        self.table = table
        self.shading = shading
        self.departing = departing
        self.progress = progress
        self.hoverLift = hoverLift
        self.hovered = hovered
        self.hoverChain = hoverChain
        self.keyboardFocus = keyboardFocus
        self.search = search
        self.options = options
    }

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, hoverLift) }
        set {
            progress = newValue.first
            hoverLift = newValue.second
        }
    }

    var body: some View {
        Canvas { context, _ in
            draw(&context)
        }
    }

    // MARK: - Draw

    private func draw(_ context: inout GraphicsContext) {
        guard !metrics.isDegenerate, !index.isEmpty else { return }
        var hatchBudget = 96

        if let departing, progress < 1 {
            for frame in TreemapAnimation.frames(from: departing, to: index, progress: progress) {
                drawTile(&context, frame: frame, hatchBudget: &hatchBudget)
            }
            // No emphasis mid-zoom: hover is meaningless while the geometry is
            // moving, and a focus ring chasing a sliding tile reads as a glitch.
            // Labels are skipped for a second reason — the placement pass solves
            // non-overlap for one arrangement, and re-solving it every frame of
            // a transition would make names jump between tiles.
            return
        }

        for tile in index.tiles {
            drawTile(&context, frame: TreemapFrame(resting: tile), hatchBudget: &hatchBudget)
        }
        drawEmphasis(&context)
        if options.showsWedgeLabels { drawLabels(&context) }
    }

    /// The gutter that reveals nesting. Half a point at the deepest levels,
    /// where tiles are small and a thick border would eat the tile itself.
    private func gutter(for rect: CGRect) -> Double {
        min(0.75, min(rect.width, rect.height) * 0.08)
    }

    /// A tile's fill: lit at the top-left, shaded at the bottom-right.
    ///
    /// The light source is fixed in the *view*, not in the mark — every tile is
    /// lit from the same corner, so the map reads as one surface catching one
    /// light rather than as a few thousand independently shiny objects.
    private func fill(for tile: TreemapTile, in rect: CGRect,
                      highlighted: Bool = false) -> GraphicsContext.Shading {
        guard TreemapShadingTable.usesGradient(rect: rect, kind: tile.kind) else {
            return .color(table.color(for: tile, highlighted: highlighted))
        }
        return .linearGradient(shading.gradient(for: tile, highlighted: highlighted),
                               startPoint: CGPoint(x: rect.minX, y: rect.minY),
                               endPoint: CGPoint(x: rect.maxX, y: rect.maxY))
    }

    private func drawTile(_ context: inout GraphicsContext, frame: TreemapFrame,
                          hatchBudget: inout Int) {
        let tile = frame.tile
        let full = metrics.rect(for: frame.rect)
        // Under about half a point there is nothing to see. The layouter already
        // merged anything genuinely sub-pixel at its own assumed size; this
        // catches what a small window squeezes further.
        guard full.width >= 0.5, full.height >= 0.5 else { return }
        let inset = gutter(for: full)
        let rect = full.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = Path(rect)

        let restoreOpacity = context.opacity
        // A search dims what it did not find rather than removing it: the shape
        // of the disk has to stay intact or the user loses their bearings. The
        // transition's own opacity multiplies into the same number, so a tile
        // that is both leaving and unmatched fades once rather than twice.
        let emphasis = search.opacity(for: tile.id) * frame.opacity
        if emphasis < 1 { context.opacity = emphasis }
        context.fill(path, with: fill(for: tile, in: rect))

        let edge = min(rect.width, rect.height)
        if edge >= 3 {
            context.stroke(path,
                           with: .color(Color.primary.opacity(tile.depth == 0 ? 0.22 : 0.10)),
                           lineWidth: 0.5)
        }
        if search.isDimming, emphasis >= 1, edge >= 2 {
            // Dimming alone is a comparative signal, and a lone match among a
            // handful of tiles has nothing to be compared with.
            context.stroke(path, with: .color(Color.accentColor.opacity(0.9)), lineWidth: 1.5)
        }
        if tile.isAggregated, hatchBudget > 0, edge >= 6 {
            hatchBudget -= 1
            drawDiagonalHatch(&context, path: path,
                              ink: table.palette.hatchInk(on: table.swatch(for: tile)))
        }
        if tile.isStillScanning, edge >= 8 {
            // A dashed border on a directory still being walked: the boundary is
            // provisional, and a dashed line is the conventional way to say so.
            // The sunburst dashes only the outer arc because that is the edge
            // that grows; a rectangle has no single growing edge, so all four.
            context.stroke(Path(rect.insetBy(dx: 1, dy: 1)),
                           with: .color(table.palette.hatchInk(on: table.swatch(for: tile))),
                           style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: [2.5, 2.5]))
        }
        context.opacity = restoreOpacity
    }

    // MARK: - Emphasis

    private func rect(for position: TreemapPosition, inset extra: Double = 0) -> CGRect? {
        guard let tile = index[position] else { return nil }
        let full = metrics.rect(for: tile)
        let rect = full.insetBy(dx: gutter(for: full) + extra, dy: gutter(for: full) + extra)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private func drawEmphasis(_ context: inout GraphicsContext) {
        // Ancestors first, then the hovered tile on top of them, then the
        // keyboard ring on top of everything — exactly the sunburst's order and
        // exactly its two marks, so the two views are learned once.
        for position in hoverChain where position != hovered {
            // Ancestors are outlined rather than refilled: they are underneath
            // their children, so lifting their fill would show nowhere at all.
            guard let rect = rect(for: position) else { continue }
            context.stroke(Path(rect), with: .color(Color.primary.opacity(0.35)), lineWidth: 1.5)
        }

        if let hovered, let tile = index[hovered], let rect = rect(for: hovered) {
            drawLift(&context, tile: tile, rect: rect)
        }

        if let keyboardFocus, let tile = index[keyboardFocus] {
            if let rect = rect(for: keyboardFocus, inset: 1) {
                context.stroke(Path(rect), with: .color(Color.accentColor), lineWidth: 3)
            }
            if let inner = rect(for: keyboardFocus, inset: 3) {
                let ink = table.palette.labelInk(on: table.swatch(for: tile))
                context.stroke(Path(inner), with: .color(ink.opacity(0.55)), lineWidth: 1)
            }
        }
    }

    /// The hovered tile comes forward: slightly larger, rounded, with a shadow
    /// under it.
    ///
    /// A brighter fill alone — which is all this used to be — says "this one" in
    /// a chart where every neighbour is already a different colour, so it is the
    /// weakest possible signal. Depth is the one channel a treemap is not
    /// already using for something.
    private func drawLift(_ context: inout GraphicsContext, tile: TreemapTile, rect: CGRect) {
        let lift = TreemapHoverLift.outset(for: rect, progress: hoverLift)
        let raised = rect.insetBy(dx: -lift, dy: -lift)
        let path = Path(roundedRect: raised,
                        cornerRadius: TreemapHoverLift.cornerRadius(for: raised),
                        style: .continuous)
        // Its own layer, because the shadow filter applies to everything drawn
        // in the context it is added to — set on the outer context it would put
        // a shadow under the focus ring and every label after it.
        context.drawLayer { layer in
            if lift > 0 {
                layer.addFilter(.shadow(
                    color: .black.opacity(TreemapHoverLift.shadowOpacity * hoverLift),
                    radius: TreemapHoverLift.shadowRadius * hoverLift,
                    x: 0, y: lift))
            }
            layer.fill(path, with: fill(for: tile, in: raised, highlighted: true))
        }
        context.stroke(path, with: .color(Color.primary.opacity(0.55)), lineWidth: 1.5)
    }

    // MARK: - Labels

    /// The same pass the sunburst runs, over slots built from rectangles
    /// instead of sectors. Sharing it is the point: one non-overlap rule, one
    /// legibility floor, one truncation, tested once.
    private func drawLabels(_ context: inout GraphicsContext) {
        var slots = TreemapLabels.slots(for: index, metrics: metrics,
                                        hovered: hovered, keyboardFocus: keyboardFocus)
        guard !slots.isEmpty else { return }
        if search.isDimming {
            slots = slots.filter { search.matched.contains($0.id) || $0.isForced }
            guard !slots.isEmpty else { return }
        }

        let measuringContext = context
        let cache = LabelTextCache.shared
        let font = TreemapLabels.font
        let placed = LabelPlacement.place(slots: slots) { text in
            cache.size(of: text, font: font, in: measuringContext)
        }
        drawPlacedLabels(&context, placed: placed, font: font, scheme: table.scheme) { id in
            guard let position = index.position(ofNode: NodeRef(rawValue: id)),
                  let tile = index[position] else { return nil }
            return table.palette.labelInk(on: table.swatch(for: tile))
        }
    }
}
