import Foundation
import LoupeCore
import SwiftUI

/// Hue, saturation and brightness as plain numbers, so colour decisions can be
/// asserted in a test without rendering a pixel or introspecting a `Color`.
public struct SunburstSwatch: Sendable, Hashable {
    /// Turns, `0..<1`, matching `Color(hue:saturation:brightness:)`.
    public let hue: Double
    public let saturation: Double
    public let brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        self.saturation = min(max(saturation, 0), 1)
        self.brightness = min(max(brightness, 0), 1)
    }

    public var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }

    /// The swatch as gamma-encoded sRGB components, `0...1`.
    public var components: (red: Double, green: Double, blue: Double) {
        let (r, g, b) = Self.rgb(hue: hue, saturation: saturation, brightness: brightness)
        return (r, g, b)
    }

    /// Rec. 709 luma of the gamma-encoded components. Cheap, and good enough
    /// for "is this swatch light or dark" comparisons between two swatches.
    ///
    /// Not the quantity WCAG contrast is defined against — that is
    /// `relativeLuminance`, which linearises first. The two disagree by enough
    /// to matter on saturated colour, which is exactly what this palette is
    /// made of, so ink decisions use the linearised one.
    public var luminance: Double {
        let (r, g, b) = components
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// WCAG 2.1 relative luminance: linearise, then weight.
    public var relativeLuminance: Double {
        let (r, g, b) = components
        return Contrast.relativeLuminance(red: r, green: g, blue: b)
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let h = hue * 6
        let sector = floor(h)
        let f = h - sector
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch Int(sector) % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}

/// WCAG contrast, as arithmetic rather than as a guess.
///
/// A label on a wedge is one mark on top of another mark: there is no semantic
/// colour that can be correct for it, so the only way to know it is readable is
/// to compute the ratio. This is that computation, exposed so a test can hold
/// the whole palette to a number instead of to an opinion.
public enum Contrast {
    public static func linearise(_ channel: Double) -> Double {
        let c = min(max(channel, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * linearise(red) + 0.7152 * linearise(green) + 0.0722 * linearise(blue)
    }

    /// The WCAG ratio between two relative luminances, `1...21`.
    public static func ratio(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }
}

/// Ink for text drawn straight onto a wedge: a grey level and an opacity.
///
/// A value rather than a `Color` so the composite it will actually produce over
/// a given fill can be computed — and therefore tested — without rendering.
public struct SunburstInk: Sendable, Hashable {
    /// Grey level, `0` black to `1` white.
    public let white: Double
    public let opacity: Double

    public init(white: Double, opacity: Double) {
        self.white = min(max(white, 0), 1)
        self.opacity = min(max(opacity, 0), 1)
    }

    public var color: Color { Color(white: white).opacity(opacity) }

    /// The ink as it lands, composited source-over onto `fill`.
    ///
    /// Compositing is done in gamma-encoded sRGB, which is what the renderer
    /// does for a `.color` fill in a `Canvas`.
    public func composited(over fill: SunburstSwatch) -> (Double, Double, Double) {
        let (r, g, b) = fill.components
        return (white * opacity + r * (1 - opacity),
                white * opacity + g * (1 - opacity),
                white * opacity + b * (1 - opacity))
    }

    /// The contrast ratio this ink actually achieves over `fill`.
    public func contrastRatio(over fill: SunburstSwatch) -> Double {
        let (r, g, b) = composited(over: fill)
        return Contrast.ratio(Contrast.relativeLuminance(red: r, green: g, blue: b),
                              fill.relativeLuminance)
    }
}

/// Which categorical ramp the wedges use. Chrome never uses either — it uses
/// semantic system colours, so dark mode is correct for free.
public enum SunburstRamp: String, Sendable, Codable, CaseIterable, Identifiable {
    case standard
    case colourBlindSafe

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .standard: "Standard colours"
        case .colourBlindSafe: "Colour-blind-safe colours"
        }
    }

    public var explanation: String {
        switch self {
        case .standard:
            "Ten vivid hues, one per top-level folder."
        case .colourBlindSafe:
            "Seven hues chosen to stay distinct with red-green colour vision deficiency."
        }
    }
}

/// The sunburst's colour model.
///
/// Every value here is a pure function of `(colorSeed, ring, kind, colorScheme)`.
/// The projector guarantees `colorSeed` is the index of the wedge's top-level
/// ancestor under the focus and that it stays put across zooms, so a folder
/// keeps its colour when you drill into it — which is the whole point of
/// carrying the seed in the contract at all.
///
/// ## Why these colours
///
/// The chart is the one place in this app allowed to be beautiful, so the ramp
/// is jewels and citrus at the edge of what sRGB will hold — a hot pink, a real
/// electric blue, a deep violet, a lemon — rather than the system colours being
/// polite. It is still an inspection instrument: the chrome around it stays
/// semantic and calm, and nothing here glows.
///
/// ## Why there is a luminance every fill avoids
///
/// A label on a wedge is inked black or white; nothing between them can beat
/// both, and both run out at once at a relative luminance near 0.18, where each
/// manages about 4.5:1 and no grey does better. A flat fill could sit there. A
/// *gradient* cannot: `SunburstShading` spreads the fill either side of this
/// swatch, so the label has to clear `inkComfortRatio` at both ends, and a fill
/// centred on the dead band has one end inside it whichever ink it picks.
///
/// So every base sits firmly on one side of that band, and every ring, kind and
/// state keeps it there. `PaletteShadingInkTests` walks all of them and fails
/// if a retune lands one in the middle — which is the failure this arrangement
/// exists to prevent, not a cosmetic one: it is a wedge whose name cannot be
/// read.
///
/// That one rule is why the two appearances have different *shapes*, not just
/// different numbers:
///
/// - **Light.** Outer rings recede towards the white page, so every entry has
///   to start above the band and can only move further above it. Ten bright,
///   high-chroma colours. A deep entry is impossible here, not merely darker:
///   receding would drag it up through the band on the way to the paper.
/// - **Dark.** Recession runs the other way, so an entry may live on either
///   side, and the ramp splits along the line sRGB already draws. Hues that are
///   luminous at full chroma (lemon, lime, emerald, mint, cyan, tangerine) sit
///   high; hues that are intrinsically dark at full chroma (blue, violet,
///   magenta, red) sit deep, where they can carry far more chroma than any
///   light-appearance blue can. Flattening the dark ramp to one luminance is
///   the tempting move and it fails both ways at once: the yellows go olive, or
///   the blues go pastel.
///
/// ## Why this *order*
///
/// Seeds are handed out in angular order, so neighbouring wedges carry
/// neighbouring seeds and the ramp's own ordering — including the wrap from the
/// last entry back to the first — is what decides whether two touching wedges
/// can be told apart at two degrees of arc. The order below is not aesthetic
/// sequencing: it is the cyclic permutation that maximises the *minimum*
/// CIEDE2000 distance between adjacent entries, evaluated at the innermost and
/// outermost ring in both appearances at once, brute-forced over all 9!
/// distinct cycles. It measures ΔE2000 36.0 for the standard ramp, against
/// 23.4 for the ramp this replaced. `SunburstPaletteTests` re-checks that
/// number, so reordering this table without re-running the search fails the
/// suite rather than quietly muddying the chart.
public struct SunburstPalette: Sendable {
    public let ramp: SunburstRamp

    public init(ramp: SunburstRamp = .standard) {
        self.ramp = ramp
    }

    // MARK: - Ring modulation constants

    /// How fast a ring loses saturation as it recedes, per ring.
    ///
    /// Chroma is what a colour *is*, so the dark ramp now spends very little of
    /// it on depth — a fifteenth of the base per ring, where it used to be a
    /// seventh. Value carries the recession there instead, which reads as
    /// distance rather than as fading, and desaturating a deep fill would have
    /// pushed it up into the dead band besides: a saturated blue is dark
    /// *because* it is saturated.
    ///
    /// Light appearance cannot do the same, and this is not an oversight. Its
    /// entries sit at full value already, so the only route towards the white
    /// page is out of chroma. Holding chroma in light appearance does not read
    /// as depth; it reads as nine identical rings.
    private static let lightSaturationFalloff = 0.075
    private static let darkSaturationFalloff = 0.045
    /// How far a light ring is carried towards white, as a fraction of the
    /// headroom it has left, per ring. Interpolating into the headroom rather
    /// than adding a fixed step keeps the ramp strictly monotonic for *any*
    /// base — a bright base with a fixed step saturates against the ceiling and
    /// the outer rings stop receding at all.
    private static let lightBrightnessLift = 0.075
    private static let lightBrightnessLiftCap = 0.55
    /// Dark rings recede towards the background instead, with a floor: a wedge
    /// you cannot see is a wedge you cannot click.
    ///
    /// Gentler than it was, because the dark ramp's luminous half has to stay
    /// luminous for all nine rings — the old 0.062 took the outermost ring of a
    /// lemon down to a mid grey-gold sitting squarely in the band where its own
    /// label stops being readable.
    private static let darkBrightnessFalloff = 0.036
    private static let darkBrightnessFloor = 0.30

    // Bases are written out per scheme rather than derived from one another.
    // A dark palette computed by inverting a light one always ends up either
    // garish or muddy; two short tables cost nothing and both look right.
    //
    // Light: ten bright colours on a white page, each carrying as much chroma
    // as its hue allows while its whole family of fills — nine rings, three
    // kinds, hovered or not, both ends of the gradient — stays clear of the
    // dead band. The citrus and the greens are then pulled back one step from
    // the very top of the gamut, where ten hand-sized fields of it stop being
    // cheerful and start being loud; the blue and the violet are held down by
    // the band instead, because a saturated blue is dark and dark is the one
    // thing a light-appearance entry may not be. Both are why the numbers here
    // look arbitrary and are not.
    private static let standardLight: [SunburstSwatch] = [
        SunburstSwatch(hue: 6 / 360, saturation: 0.70, brightness: 0.94), // coral red
        SunburstSwatch(hue: 90 / 360, saturation: 1.00, brightness: 0.86), // lime
        SunburstSwatch(hue: 220 / 360, saturation: 0.64, brightness: 0.94), // blue
        SunburstSwatch(hue: 50 / 360, saturation: 1.00, brightness: 0.91), // citrus yellow
        SunburstSwatch(hue: 195 / 360, saturation: 1.00, brightness: 0.94), // cyan
        SunburstSwatch(hue: 32 / 360, saturation: 1.00, brightness: 0.94), // tangerine
        SunburstSwatch(hue: 275 / 360, saturation: 0.57, brightness: 0.94), // violet
        SunburstSwatch(hue: 145 / 360, saturation: 1.00, brightness: 0.87), // emerald
        SunburstSwatch(hue: 325 / 360, saturation: 0.69, brightness: 0.94), // hot pink
        SunburstSwatch(hue: 172 / 360, saturation: 1.00, brightness: 0.87), // mint
    ]

    // Dark: the same ten hues, deliberately *not* Apple's dark system colours.
    // Those are tuned for glyphs and tints a few points across; a wedge is a
    // hand-sized field of colour, and ten of them at that value on black is the
    // neon-arcade look this chart is not.
    //
    // Six of them sit luminous and four sit deep — see the type's doc comment
    // for why that split is forced rather than chosen. The deep four are the
    // ones that gain: on black a blue can be #0048D9 and a violet #8F00F5,
    // half as much chroma again as either can hold on white.
    private static let standardDark: [SunburstSwatch] = [
        SunburstSwatch(hue: 6 / 360, saturation: 1.00, brightness: 0.71), // ruby
        SunburstSwatch(hue: 90 / 360, saturation: 1.00, brightness: 0.91), // lime
        SunburstSwatch(hue: 220 / 360, saturation: 1.00, brightness: 0.85), // electric blue
        SunburstSwatch(hue: 50 / 360, saturation: 1.00, brightness: 0.95), // citrus yellow
        SunburstSwatch(hue: 195 / 360, saturation: 0.87, brightness: 0.96), // cyan
        SunburstSwatch(hue: 32 / 360, saturation: 0.80, brightness: 0.96), // tangerine
        SunburstSwatch(hue: 275 / 360, saturation: 1.00, brightness: 0.96), // violet
        SunburstSwatch(hue: 145 / 360, saturation: 1.00, brightness: 0.93), // emerald
        SunburstSwatch(hue: 325 / 360, saturation: 1.00, brightness: 0.69), // magenta
        SunburstSwatch(hue: 172 / 360, saturation: 1.00, brightness: 0.93), // mint
    ]

    // Okabe–Ito, at the hues the published ramp specifies and the values the
    // gradient will allow. The hues are the part that is load-bearing for a
    // dichromat and they are untouched. The lightnesses are not Okabe–Ito's,
    // and that is not a liberty taken for looks: at the published values, four
    // of the seven in light appearance and five in dark have some ring or state
    // that lands in the dead band, which is a wedge you cannot read the name
    // of. The ramp is only worth having if it is legible first.
    //
    // Two entries share a hue (blue and sky blue) and separate on lightness
    // instead, which is why the ramp is a table of full swatches and not a
    // table of hues, and why the order keeps those two off each other. This
    // ramp's order is searched against simulated deuteranopia and protanopia as
    // well as normal vision — separation for a dichromat is the entire reason
    // it exists, and an order that is merely pretty to trichromats is not the
    // thing being asked for.
    private static let safeLight: [SunburstSwatch] = [
        SunburstSwatch(hue: 202 / 360, saturation: 1.00, brightness: 0.94), // blue
        SunburstSwatch(hue: 26 / 360, saturation: 1.00, brightness: 0.94), // vermillion
        SunburstSwatch(hue: 202 / 360, saturation: 0.49, brightness: 0.94), // sky blue
        SunburstSwatch(hue: 41 / 360, saturation: 1.00, brightness: 0.94), // orange
        SunburstSwatch(hue: 327 / 360, saturation: 0.64, brightness: 0.94), // reddish purple
        SunburstSwatch(hue: 56 / 360, saturation: 1.00, brightness: 0.94), // yellow
        SunburstSwatch(hue: 164 / 360, saturation: 1.00, brightness: 0.83), // bluish green
    ]

    // Dark: vermillion and reddish purple go deep, the rest luminous, which
    // spreads the seven over a wide range of lightness — and lightness is what
    // a dichromat has left when two hues collapse onto each other.
    private static let safeDark: [SunburstSwatch] = [
        SunburstSwatch(hue: 202 / 360, saturation: 0.69, brightness: 0.96),
        SunburstSwatch(hue: 26 / 360, saturation: 1.00, brightness: 0.53),
        SunburstSwatch(hue: 202 / 360, saturation: 0.37, brightness: 0.96),
        SunburstSwatch(hue: 41 / 360, saturation: 0.90, brightness: 0.96),
        SunburstSwatch(hue: 327 / 360, saturation: 1.00, brightness: 0.69),
        SunburstSwatch(hue: 56 / 360, saturation: 1.00, brightness: 0.96),
        SunburstSwatch(hue: 164 / 360, saturation: 1.00, brightness: 0.89),
    ]

    private func bases(_ scheme: ColorScheme) -> [SunburstSwatch] {
        switch ramp {
        case .standard: scheme == .dark ? Self.standardDark : Self.standardLight
        case .colourBlindSafe: scheme == .dark ? Self.safeDark : Self.safeLight
        }
    }

    public func swatchCount(_ scheme: ColorScheme = .light) -> Int { bases(scheme).count }

    /// Every base swatch in ramp order. Exposed so a legend can draw the ramp
    /// and a test can walk it.
    public func baseSwatches(_ scheme: ColorScheme = .light) -> [SunburstSwatch] { bases(scheme) }

    /// The categorical hue for a seed. Pure, and independent of ring, kind and
    /// scheme — that independence is exactly what keeps a folder's identity
    /// stable when you zoom into it and its ring index changes.
    public func hue(forSeed seed: UInt16, scheme: ColorScheme = .light) -> Double {
        base(forSeed: seed, scheme: scheme).hue
    }

    public func base(forSeed seed: UInt16, scheme: ColorScheme = .light) -> SunburstSwatch {
        let table = bases(scheme)
        return table[Int(seed) % table.count]
    }

    /// The drawn colour of a wedge.
    ///
    /// Ring modulates lightness so the outer rings recede and the coarse,
    /// large-scale structure reads first — the inner rings are the ones worth
    /// looking at, and the outer ones are context.
    public func swatch(seed: UInt16, ring: UInt8, kind: WedgeKind = .real,
                       scheme: ColorScheme = .light, highlighted: Bool = false) -> SunburstSwatch {
        let base = base(forSeed: seed, scheme: scheme)
        let depth = Double(min(ring, SunburstGeometry.maximumRings))
        var saturation: Double
        var brightness: Double

        if scheme == .dark {
            saturation = base.saturation * (1 - depth * Self.darkSaturationFalloff)
            brightness = max(Self.darkBrightnessFloor,
                             base.brightness * (1 - depth * Self.darkBrightnessFalloff))
        } else {
            saturation = base.saturation * (1 - depth * Self.lightSaturationFalloff)
            let lift = min(Self.lightBrightnessLiftCap, depth * Self.lightBrightnessLift)
            brightness = base.brightness + (1 - base.brightness) * lift
        }

        switch kind {
        case .real:
            break
        case .aggregated:
            // An aggregated wedge is several things wearing one coat. It must
            // never be mistakable for a real single item, so it drops nearly
            // all of its hue and sits at a neutral tone; the renderer also
            // hatches it. Two independent signals, because one can be missed.
            //
            // Against this ramp it has to bite harder than it did: a tenth of
            // the chroma rather than a seventh, and a mid grey rather than a
            // pale or a dim one. Next to ten saturated fields of colour, "pale"
            // is just another light colour and "dim" is just another dark one,
            // while a mid grey is not a colour at all — it is the one tone in
            // the chart with nowhere on the hue circle to belong. Measured, it
            // is ΔE2000 13.6 from the nearest fill the ramp can otherwise draw,
            // where the old pair of constants managed 8.1.
            saturation *= 0.10
            brightness = scheme == .dark ? 0.56 : 0.72
        case .stillScanning:
            // Still itself, just unsettled. The dashed outer edge the renderer
            // draws carries most of this signal; the colour only softens.
            //
            // It softens much less in dark appearance, where half the ramp is
            // deep: pulling chroma out of a deep fill *raises* its luminance,
            // because a saturated blue is dark on account of being saturated,
            // and the light-appearance move of 0.62 would walk a violet
            // straight into the dead band.
            saturation *= scheme == .dark ? 0.85 : 0.62
        }

        if highlighted {
            saturation = min(1, saturation + 0.07)
            brightness = scheme == .dark ? min(1, brightness + 0.11) : min(1, brightness + 0.075)
        }
        return SunburstSwatch(hue: base.hue, saturation: saturation, brightness: brightness)
    }

    public func color(seed: UInt16, ring: UInt8, kind: WedgeKind = .real,
                      scheme: ColorScheme = .light, highlighted: Bool = false) -> Color {
        swatch(seed: seed, ring: ring, kind: kind, scheme: scheme, highlighted: highlighted).color
    }

    public func color(for wedge: Wedge, scheme: ColorScheme, highlighted: Bool = false) -> Color {
        color(seed: wedge.colorSeed, ring: wedge.ring, kind: wedge.kind,
              scheme: scheme, highlighted: highlighted)
    }

    // MARK: - Ink

    /// What a label drawn straight onto a wedge is inked with, softened.
    static let softDarkInk = SunburstInk(white: 0.10, opacity: 0.92)
    static let softLightInk = SunburstInk(white: 1.00, opacity: 0.95)
    /// The same two at full strength, for fills where softness costs legibility.
    static let fullDarkInk = SunburstInk(white: 0.00, opacity: 1.0)
    static let fullLightInk = SunburstInk(white: 1.00, opacity: 1.0)
    /// Below this, softness is no longer affordable. Above it, the softened ink
    /// is preferred — a chart of pure black and pure white labels reads as a
    /// diagram rather than as a picture of a disk.
    static let inkComfortRatio = 5.0

    /// Ink for a label drawn on top of a wedge.
    ///
    /// Not chrome — this is one mark sitting on another mark, so it has to be
    /// derived from the fill rather than taken from the semantic palette, or it
    /// will vanish on half the ramp. The rule is arithmetic, not a lightness
    /// threshold: pick whichever side actually wins the contrast, then soften
    /// it only where there is room to. A threshold on lightness gets saturated
    /// colour wrong, which is what this palette is made of.
    public func ink(on swatch: SunburstSwatch) -> SunburstInk {
        // Black and white are the two extremes available, so whichever of them
        // wins at full strength is the side to be on; nothing in between can
        // beat it.
        let fill = swatch.relativeLuminance
        let onBlack = Contrast.ratio(0, fill)
        let onWhite = Contrast.ratio(1, fill)
        let (soft, full) = onBlack >= onWhite
            ? (Self.softDarkInk, Self.fullDarkInk)
            : (Self.softLightInk, Self.fullLightInk)
        // Which side to be on is a question about the reference colour. Whether
        // the softened version is *affordable* is not: the wedge is drawn as a
        // gradient, so the label lies across a range, and softness has to hold
        // at the worst end of it. Asking only the reference colour picks the
        // soft ink for fills where it is comfortable in the middle and thin at
        // one edge — the failure is invisible in a swatch and obvious on a disk.
        let ends = Self.shadingEnvelope(of: swatch)
        let comfort = min(soft.contrastRatio(over: swatch),
                          soft.contrastRatio(over: ends.lit),
                          soft.contrastRatio(over: ends.shade))
        return comfort >= Self.inkComfortRatio ? soft : full
    }

    /// The two ends `SunburstShading` will spread `swatch` to.
    ///
    /// Restated from the shading rule rather than read back from
    /// `shading(seed:ring:kind:scheme:highlighted:)`, because ink is chosen
    /// from a swatch and a swatch no longer knows which wedge it came from.
    /// The duplication is deliberate and guarded: `PaletteShadingInkTests`
    /// measures the ink against the endpoints the renderer really gets, so if
    /// the two ever drift apart the suite says so.
    ///
    /// For an aggregated fill — drawn flat — this is a wider envelope than the
    /// mark actually spans, which costs it softness it could have kept. That is
    /// the right direction to be wrong in, and a grey wedge is the one place a
    /// full-strength label is least missed.
    static func shadingEnvelope(of swatch: SunburstSwatch)
        -> (lit: SunburstSwatch, shade: SunburstSwatch) {
        (SunburstSwatch(hue: swatch.hue,
                        saturation: swatch.saturation + shadingSaturationSpread,
                        brightness: swatch.brightness
                            + (1 - swatch.brightness) * shadingLift),
         SunburstSwatch(hue: swatch.hue,
                        saturation: swatch.saturation - shadingSaturationSpread * 0.5,
                        brightness: swatch.brightness * (1 - shadingDrop)))
    }

    /// Ink for a label drawn on top of a wedge, as a `Color`.
    public func labelInk(on swatch: SunburstSwatch) -> Color { ink(on: swatch).color }

    /// Hatching for aggregated wedges, at a contrast that reads as texture
    /// rather than as a second colour. Also used for the dashed edge on a
    /// directory still being walked.
    public func hatchInk(on swatch: SunburstSwatch) -> Color {
        swatch.relativeLuminance > 0.22
            ? Color(white: 0.15).opacity(0.32)
            : Color(white: 1.0).opacity(0.28)
    }
}
