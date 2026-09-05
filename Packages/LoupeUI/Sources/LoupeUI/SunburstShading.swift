import Foundation
import LoupeCore
import SwiftUI

/// A wedge's fill as a two-stop gradient rather than one flat colour.
///
/// ## Why this exists as a contract and not as a renderer detail
///
/// The colour of a mark and the *shape* of the gradient across it are decided
/// in two different places — the palette owns hue, the renderer owns geometry —
/// and the two have to agree or labels stop being legible. Flat fills made that
/// agreement trivial: ink was computed against the one colour the wedge was.
/// A gradient means a label now sits on a *range*, and the ink that was
/// comfortable against the mean can fail against one end of it.
///
/// So the rule is stated here, once, and pinned by a test:
///
/// **`SunburstPalette.swatch` remains the reference colour.** It is what the
/// legend draws, what ink is chosen against, and what every existing contrast
/// test measures. `shading` only ever spreads a bounded distance either side of
/// it — see `shadingLift` and `shadingDrop` — and `PaletteShadingInkTests`
/// asserts the ink chosen from `swatch` still clears `inkComfortRatio` against
/// *both* endpoints, for every seed, ring, kind, scheme and ramp.
///
/// That is the whole safety property. Retune the ramp freely; if a base is
/// pushed somewhere the gradient can no longer carry a legible label, the test
/// fails instead of the chart quietly becoming unreadable.
///
/// It is worth saying what happened the first time, because it is the argument
/// for writing the test before the feature rather than after. This file was
/// committed asserting that a suite called `SunburstShadingTests` enforced the
/// rule above. No such suite existed. Measured afterwards, the palette then in
/// the tree failed the rule badly — ink fell to **3.39:1** at the dim end of the
/// gradient, under even the 4.5 AA floor, on 5 of 10 light entries and 7 of 10
/// dark. Flat fills had hidden it, because with a flat fill the reference colour
/// *is* the fill. The gradient is what made the endpoints real, and the doc
/// comment claiming a guard is what nearly let it ship unnoticed.
public struct SunburstShading: Sendable, Hashable {
    /// The edge nearer the centre of the chart — for a treemap tile, the
    /// top-left corner; for a bubble, the upper-left of the sphere.
    public let inner: SunburstSwatch
    /// The far edge. Always the darker of the two in light appearance and the
    /// lighter in dark appearance, so the implied light source is consistent
    /// across the whole disk rather than per-wedge.
    public let outer: SunburstSwatch

    public init(inner: SunburstSwatch, outer: SunburstSwatch) {
        self.inner = inner
        self.outer = outer
    }

    /// A gradient that is not a gradient. For marks too small to show one, and
    /// for the aggregated fill, which must not read as dimensional.
    public init(flat swatch: SunburstSwatch) {
        self.init(inner: swatch, outer: swatch)
    }

    public var colors: [Color] { [inner.color, outer.color] }

    /// The endpoint a label is hardest to read on: whichever is nearer the ink
    /// it would be given. Renderers do not need this — tests do.
    public func worstEndpoint(for ink: SunburstInk) -> SunburstSwatch {
        ink.contrastRatio(over: inner) <= ink.contrastRatio(over: outer) ? inner : outer
    }
}

public extension SunburstPalette {
    /// How far the inner edge is carried *towards* the light, as a fraction of
    /// the headroom left. Fraction-of-headroom rather than a fixed step for the
    /// same reason the ring lift is: a fixed step clips against the ceiling on
    /// the bright half of the ramp and the gradient disappears exactly on the
    /// colours that most need it.
    static var shadingLift: Double { 0.20 }
    /// How far the outer edge is carried towards black. A plain multiplier is
    /// fine here — there is no floor to clip against that a wedge would notice.
    static var shadingDrop: Double { 0.13 }
    /// And a touch more saturation on the lit edge, so the gradient reads as
    /// light falling on a coloured thing rather than as a wash of white.
    static var shadingSaturationSpread: Double { 0.06 }

    /// The drawn fill for a wedge, tile or bubble.
    ///
    /// Hue never varies across the gradient. A hue ramp inside one mark would
    /// break the thing the whole palette is for — that a folder has *a* colour
    /// you can find again in another ring.
    func shading(seed: UInt16, ring: UInt8, kind: WedgeKind = .real,
                 scheme: ColorScheme = .light, highlighted: Bool = false) -> SunburstShading {
        let base = swatch(seed: seed, ring: ring, kind: kind,
                          scheme: scheme, highlighted: highlighted)

        // An aggregated mark is several things wearing one coat. Giving it a
        // dimensional fill would make it look like a single solid object, which
        // is the one thing it must never look like.
        if case .aggregated = kind { return SunburstShading(flat: base) }

        let lit = SunburstSwatch(
            hue: base.hue,
            saturation: min(1, base.saturation + Self.shadingSaturationSpread),
            brightness: base.brightness + (1 - base.brightness) * Self.shadingLift)
        let shade = SunburstSwatch(
            hue: base.hue,
            saturation: max(0, base.saturation - Self.shadingSaturationSpread * 0.5),
            brightness: base.brightness * (1 - Self.shadingDrop))

        // The light source is fixed in the view, not in the mark. In light
        // appearance the near edge is lit; in dark appearance the chart reads as
        // emissive rather than lit, so the near edge is the brighter one there
        // too — same assignment, different reason. Kept explicit because the
        // next person will assume these swap and they do not.
        return SunburstShading(inner: lit, outer: shade)
    }

    func shading(for wedge: Wedge, scheme: ColorScheme,
                 highlighted: Bool = false) -> SunburstShading {
        shading(seed: wedge.colorSeed, ring: wedge.ring, kind: wedge.kind,
                scheme: scheme, highlighted: highlighted)
    }
}
