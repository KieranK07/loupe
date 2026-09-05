import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

@Suite("Colour")
struct SunburstPaletteTests {
    /// The point of carrying `colorSeed` in the contract at all: a folder keeps
    /// its colour when you zoom into it and everything about its position
    /// changes. Two unrelated layouts, same seed, same hue.
    @Test("The same seed gives the same hue across two different layouts",
          arguments: [SunburstRamp.standard, SunburstRamp.colourBlindSafe])
    func hueIsStableAcrossLayouts(ramp: SunburstRamp) {
        let palette = SunburstPalette(ramp: ramp)

        let outer = SunburstIndex(Fixture.layout(levels: [[1, 2, 3, 4, 5], [1, 1]],
                                                 generation: 1))
        let zoomed = SunburstIndex(Fixture.layout(levels: [[3, 1], [2, 2, 1]],
                                                 startAt: 1.3, generation: 2, focusSlot: 7))

        for scheme in [ColorScheme.light, .dark] {
            for seed in UInt16(0)...UInt16(12) {
                #expect(palette.hue(forSeed: seed, scheme: scheme)
                    == palette.hue(forSeed: seed, scheme: scheme))
            }

            // And through the full swatch pipeline, at different rings, for
            // wedges actually drawn from two separate layouts.
            var hueBySeed: [UInt16: Double] = [:]
            for index in [outer, zoomed] {
                for wedge in index.wedges {
                    let hue = palette.swatch(seed: wedge.colorSeed, ring: wedge.ring,
                                             kind: wedge.kind, scheme: scheme).hue
                    if let known = hueBySeed[wedge.colorSeed] {
                        #expect(known == hue,
                                "seed \(wedge.colorSeed) drifted hue between layouts")
                    } else {
                        hueBySeed[wedge.colorSeed] = hue
                    }
                }
            }
            #expect(hueBySeed.count >= 3)
        }
    }

    @Test("Ring modulates lightness without touching hue")
    func ringModulatesLightnessOnly() {
        let palette = SunburstPalette()
        for scheme in [ColorScheme.light, .dark] {
            let inner = palette.swatch(seed: 3, ring: 0, scheme: scheme)
            let outer = palette.swatch(seed: 3, ring: 5, scheme: scheme)
            #expect(inner.hue == outer.hue)
            #expect(inner.saturation > outer.saturation)
            if scheme == .light {
                #expect(outer.brightness > inner.brightness, "light rings should recede lighter")
            } else {
                #expect(outer.brightness < inner.brightness, "dark rings should recede darker")
            }
            // Never so far that the wedge stops being visible or clickable.
            #expect(outer.brightness > 0.25)
        }
    }

    @Test("Rings past the layout maximum are clamped, not wrapped")
    func ringClamping() {
        let palette = SunburstPalette()
        let atMax = palette.swatch(seed: 1, ring: SunburstGeometry.maximumRings, scheme: .light)
        let beyond = palette.swatch(seed: 1, ring: 200, scheme: .light)
        #expect(atMax == beyond)
    }

    /// An aggregate is several things wearing one coat and must never be
    /// mistakable for a real single item.
    @Test("Aggregated wedges are visibly not real items")
    func aggregatedIsDistinct() {
        let palette = SunburstPalette()
        for scheme in [ColorScheme.light, .dark] {
            let real = palette.swatch(seed: 2, ring: 1, kind: .real, scheme: scheme)
            let merged = palette.swatch(seed: 2, ring: 1, kind: .aggregated(count: 412), scheme: scheme)
            #expect(merged.saturation < real.saturation * 0.3)
            #expect(merged != real)
            // The count does not change the colour — only the number of items
            // behind it, which the label carries.
            #expect(merged == palette.swatch(seed: 2, ring: 1, kind: .aggregated(count: 7), scheme: scheme))
        }
    }

    @Test("Still-scanning wedges are softened but still themselves")
    func stillScanningIsSubtle() {
        let palette = SunburstPalette()
        for scheme in [ColorScheme.light, .dark] {
            let real = palette.swatch(seed: 4, ring: 0, kind: .real, scheme: scheme)
            let scanning = palette.swatch(seed: 4, ring: 0, kind: .stillScanning, scheme: scheme)
            #expect(scanning.hue == real.hue)
            #expect(scanning.saturation < real.saturation)
            #expect(scanning.saturation > real.saturation * 0.4)
        }
        // And the dark move is deliberately the smaller of the two: half that
        // ramp is deep, and chroma is what keeps a deep fill dark.
        func softening(_ scheme: ColorScheme) -> Double {
            palette.swatch(seed: 4, ring: 0, kind: .stillScanning, scheme: scheme).saturation
                / palette.swatch(seed: 4, ring: 0, kind: .real, scheme: scheme).saturation
        }
        #expect(softening(.dark) > softening(.light))
    }

    @Test("Highlighting lifts a wedge without recolouring it")
    func highlightLiftsOnly() {
        let palette = SunburstPalette()
        for scheme in [ColorScheme.light, .dark] {
            let plain = palette.swatch(seed: 6, ring: 2, scheme: scheme)
            let lifted = palette.swatch(seed: 6, ring: 2, scheme: scheme, highlighted: true)
            #expect(lifted.hue == plain.hue)
            #expect(lifted.brightness > plain.brightness)
        }
    }

    @Test("Light and dark are defined separately, not derived from one another")
    func schemesDiffer() {
        let palette = SunburstPalette()
        for seed in UInt16(0)..<UInt16(10) {
            let light = palette.swatch(seed: seed, ring: 0, scheme: .light)
            let dark = palette.swatch(seed: seed, ring: 0, scheme: .dark)
            #expect(light.hue == dark.hue)
            #expect(light.brightness != dark.brightness)
        }
    }

    @Test("The colour-blind-safe ramp is a different set of colours")
    func rampsDiffer() {
        let standard = SunburstPalette(ramp: .standard)
        let safe = SunburstPalette(ramp: .colourBlindSafe)
        #expect(standard.swatchCount() != safe.swatchCount())
        var differences = 0
        for seed in UInt16(0)..<UInt16(7) where
            standard.hue(forSeed: seed) != safe.hue(forSeed: seed) {
            differences += 1
        }
        #expect(differences >= 5)
    }

    /// Okabe-Ito separates its blues by lightness, not hue, so the safe ramp is
    /// only safe if consecutive entries stay apart on *some* axis.
    @Test("Adjacent entries in each ramp are distinguishable",
          arguments: [SunburstRamp.standard, SunburstRamp.colourBlindSafe])
    func adjacentEntriesSeparate(ramp: SunburstRamp) {
        let palette = SunburstPalette(ramp: ramp)
        let count = palette.swatchCount()
        for seed in 0..<count {
            let a = palette.base(forSeed: UInt16(seed))
            let b = palette.base(forSeed: UInt16((seed + 1) % count))
            let hueGap = min(abs(a.hue - b.hue), 1 - abs(a.hue - b.hue))
            let lightnessGap = abs(a.luminance - b.luminance)
            #expect(hueGap > 0.04 || lightnessGap > 0.10,
                    "entries \(seed) and \((seed + 1) % count) are too close in \(ramp)")
        }
    }

    @Test("Label ink flips to stay readable on the fill it sits on")
    func labelInkContrast() {
        let palette = SunburstPalette()
        let bright = SunburstSwatch(hue: 0.15, saturation: 0.3, brightness: 0.95)
        let dim = SunburstSwatch(hue: 0.6, saturation: 0.6, brightness: 0.25)
        #expect(palette.labelInk(on: bright) != palette.labelInk(on: dim))
    }

    @Test("The precomputed colour table agrees with the palette it came from")
    func colourTableMatchesPalette() {
        for ramp in SunburstRamp.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let palette = SunburstPalette(ramp: ramp)
                let table = SunburstColorTable(palette: palette, scheme: scheme)
                let index = SunburstIndex(Fixture.layout(
                    levels: [[1, 2, 3], [1, 1]],
                    kindForRing: { ring, child in
                        if ring == 1, child == 0 { .aggregated(count: 9) }
                        else if ring == 1 { .stillScanning }
                        else { .real }
                    }))
                for wedge in index.wedges {
                    for highlighted in [false, true] {
                        #expect(table.swatch(for: wedge, highlighted: highlighted)
                            == palette.swatch(seed: wedge.colorSeed, ring: wedge.ring,
                                              kind: wedge.kind, scheme: scheme,
                                              highlighted: highlighted))
                    }
                }
            }
        }
    }

    @Test("Swatch components are clamped into range")
    func swatchClamping() {
        let wild = SunburstSwatch(hue: 3.25, saturation: 4, brightness: -1)
        #expect(wild.hue >= 0 && wild.hue < 1)
        #expect(wild.saturation == 1)
        #expect(wild.brightness == 0)
        #expect(SunburstSwatch(hue: -0.25, saturation: 0.5, brightness: 0.5).hue == 0.75)
    }

    // MARK: - Separation, as a number

    /// The claim the ramp's *ordering* exists to make.
    ///
    /// Seeds are handed out in angular order, so two touching wedges carry
    /// consecutive seeds — including the wrap from the last entry back to the
    /// first, which is where a ramp designed as a list rather than as a cycle
    /// always falls over. A ramp that looks well spaced as a row of swatches
    /// and muddies at two degrees of arc has failed, and only a perceptual
    /// distance can tell the two apart.
    @Test("Consecutive seeds are far apart perceptually, at every ring and in both schemes",
          arguments: [SunburstRamp.standard, SunburstRamp.colourBlindSafe])
    func adjacentSeedsSeparatePerceptually(ramp: SunburstRamp) {
        let palette = SunburstPalette(ramp: ramp)
        for scheme in [ColorScheme.light, .dark] {
            let count = palette.swatchCount(scheme)
            var worst = Double.infinity
            var worstPair = ""
            for ring in UInt8(0)...SunburstGeometry.maximumRings {
                for seed in 0..<count {
                    let a = palette.swatch(seed: UInt16(seed), ring: ring, scheme: scheme)
                    let b = palette.swatch(seed: UInt16((seed + 1) % count), ring: ring, scheme: scheme)
                    let delta = ColourMetrics.difference(a, b)
                    if delta < worst {
                        worst = delta
                        worstPair = "seeds \(seed)/\((seed + 1) % count) at ring \(ring)"
                    }
                }
            }
            // The number the ordering search actually returned for the table
            // that shipped, less a hair for arithmetic: standard 36.22 (light)
            // and 36.03 (dark), safe 23.20 and 23.93. Pinning the measured
            // value rather than a comfortable floor is the point — it is what
            // makes an unsearched reordering fail here instead of quietly
            // muddying two neighbours on someone's disk.
            let measured = ramp == .standard ? 35.5 : 23.0
            #expect(worst >= measured,
                    "\(ramp)/\(scheme): closest adjacent pair is ΔE2000 \(worst) — \(worstPair)")
        }
    }

    /// The innermost ring is the one being read, so hold it to a higher bar
    /// than the washed-out outer rings.
    @Test("At ring 0 the standard ramp is emphatically ten different colours")
    func ringZeroSeparation() {
        let palette = SunburstPalette(ramp: .standard)
        for scheme in [ColorScheme.light, .dark] {
            let count = palette.swatchCount(scheme)
            var worst = Double.infinity
            for seed in 0..<count {
                worst = min(worst, ColourMetrics.difference(
                    palette.swatch(seed: UInt16(seed), ring: 0, scheme: scheme),
                    palette.swatch(seed: UInt16((seed + 1) % count), ring: 0, scheme: scheme)))
            }
            // Measured 53.27 light, 51.82 dark.
            #expect(worst >= 51, "\(scheme): ring 0 closest adjacent pair is ΔE2000 \(worst)")
        }
    }

    /// What the alternate ramp is *for*. The standard ramp is not held to this
    /// — it cannot be, and pretending otherwise is how a ramp ends up both drab
    /// and unsafe.
    @Test("The colour-blind-safe ramp keeps its neighbours apart under simulated dichromacy",
          arguments: [ColourMetrics.Vision.deuteranope, .protanope])
    func safeRampSurvivesDichromacy(vision: ColourMetrics.Vision) {
        let palette = SunburstPalette(ramp: .colourBlindSafe)
        for scheme in [ColorScheme.light, .dark] {
            let count = palette.swatchCount(scheme)
            var worst = Double.infinity
            var worstPair = ""
            for ring in UInt8(0)...SunburstGeometry.maximumRings {
                for seed in 0..<count {
                    let a = vision.lab(palette.swatch(seed: UInt16(seed), ring: ring, scheme: scheme))
                    let b = vision.lab(palette.swatch(seed: UInt16((seed + 1) % count),
                                                      ring: ring, scheme: scheme))
                    let delta = ColourMetrics.difference(a, b)
                    if delta < worst {
                        worst = delta
                        worstPair = "seeds \(seed)/\((seed + 1) % count) at ring \(ring)"
                    }
                }
            }
            // Measured 19.35 deuteranope, 17.04 protanope — the safe ramp's
            // order is searched against these two simulations as well as
            // against normal vision, which is why it can be held this high.
            #expect(worst >= 17,
                    "\(vision)/\(scheme): closest adjacent pair is ΔE2000 \(worst) — \(worstPair)")
        }
    }

    /// The vivid ramp made this harder, not easier: a saturated mid-tone is the
    /// one fill where neither black nor white is comfortable. Every fill the
    /// chart can produce is checked, not a sample of them.
    @Test("Every label on every fill the chart can draw clears WCAG AA")
    func labelContrastEverywhere() {
        var worst = Double.infinity
        var worstCase = ""
        var checked = 0
        for ramp in SunburstRamp.allCases {
            let palette = SunburstPalette(ramp: ramp)
            for scheme in [ColorScheme.light, .dark] {
                for seed in 0..<palette.swatchCount(scheme) {
                    for ring in UInt8(0)...SunburstGeometry.maximumRings {
                        for kind: WedgeKind in [.real, .stillScanning, .aggregated(count: 12)] {
                            for highlighted in [false, true] {
                                let fill = palette.swatch(seed: UInt16(seed), ring: ring, kind: kind,
                                                          scheme: scheme, highlighted: highlighted)
                                let ratio = palette.ink(on: fill).contrastRatio(over: fill)
                                checked += 1
                                if ratio < worst {
                                    worst = ratio
                                    worstCase = "\(ramp)/\(scheme) seed \(seed) ring \(ring) "
                                        + "\(kind) highlighted=\(highlighted)"
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(checked > 1500, "the sweep did not cover the palette")
        // 4.5:1 is the AA floor for text this small. The theoretical ceiling for
        // any two-ink rule is 4.58:1, on a fill sitting exactly where black and
        // white are equally bad, so this is as close to tight as it gets.
        #expect(worst >= 4.5, "worst label contrast is \(worst):1 at \(worstCase)")
    }

    /// Softness is the default because a chart of pure black and pure white
    /// labels reads as a diagram. It is not the default when it costs
    /// legibility, and that switch has to actually happen.
    @Test("Ink softens where it can afford to and goes to full strength where it cannot")
    func inkEscalates() {
        let palette = SunburstPalette()
        // A pale fill: dark ink, and it can afford to be soft.
        let pale = SunburstSwatch(hue: 0.13, saturation: 0.25, brightness: 0.97)
        #expect(palette.ink(on: pale).opacity < 1)
        #expect(palette.ink(on: pale).white < 0.5)
        // A mid-tone where neither ink has room to spare: the ink stops being
        // soft rather than stopping being readable.
        let awkward = SunburstSwatch(hue: 0.33, saturation: 0.60, brightness: 0.50)
        #expect(palette.ink(on: awkward).opacity == 1)
        #expect(palette.ink(on: awkward).contrastRatio(over: awkward) >= 4.5)

        // And the escalation is not a special case invented for this test: the
        // shipped ramp really does contain fills that need it.
        var escalations = 0
        for scheme in [ColorScheme.light, .dark] {
            for seed in 0..<palette.swatchCount(scheme) {
                for ring in UInt8(0)...SunburstGeometry.maximumRings {
                    for highlighted in [false, true] where palette.ink(
                        on: palette.swatch(seed: UInt16(seed), ring: ring,
                                           scheme: scheme, highlighted: highlighted)).opacity == 1 {
                        escalations += 1
                    }
                }
            }
        }
        #expect(escalations > 0, "no fill in the ramp ever needs full-strength ink")
    }

    /// Desaturation is one of the two signals that a wedge is a group rather
    /// than an item; against a vivid ramp it has to be a big move.
    @Test("An aggregated wedge is a long way from the real wedge it sits next to")
    func aggregatedIsPerceptuallyDistant() {
        for ramp in SunburstRamp.allCases {
            let palette = SunburstPalette(ramp: ramp)
            for scheme in [ColorScheme.light, .dark] {
                for seed in 0..<palette.swatchCount(scheme) {
                    for ring in UInt8(0)...SunburstGeometry.maximumRings {
                        let real = palette.swatch(seed: UInt16(seed), ring: ring, scheme: scheme)
                        let merged = palette.swatch(seed: UInt16(seed), ring: ring,
                                                    kind: .aggregated(count: 40), scheme: scheme)
                        #expect(ColourMetrics.difference(real, merged) >= 6,
                                "\(ramp)/\(scheme) seed \(seed) ring \(ring)")
                    }
                }
            }
        }
    }

    /// The stronger claim, and the one that actually matters on a disk: an
    /// aggregate is not merely unlike *its own* hue, it is unlike every fill
    /// the ramp can draw anywhere. A grey that happens to land on top of some
    /// other folder's washed-out outer ring would be a lie about the same
    /// number of items, in the same chart, at the same time.
    @Test("An aggregated wedge is unmistakable for any real fill in the ramp")
    func aggregatedIsDistantFromEveryFill() {
        for ramp in SunburstRamp.allCases {
            let palette = SunburstPalette(ramp: ramp)
            for scheme in [ColorScheme.light, .dark] {
                let count = palette.swatchCount(scheme)
                var worst = Double.infinity
                var worstCase = ""
                for seed in 0..<count {
                    for ring in UInt8(0)...SunburstGeometry.maximumRings {
                        let merged = palette.swatch(seed: UInt16(seed), ring: ring,
                                                    kind: .aggregated(count: 40), scheme: scheme)
                        for other in 0..<count {
                            for otherRing in UInt8(0)...SunburstGeometry.maximumRings {
                                let real = palette.swatch(seed: UInt16(other), ring: otherRing,
                                                          scheme: scheme)
                                let delta = ColourMetrics.difference(merged, real)
                                if delta < worst {
                                    worst = delta
                                    worstCase = "grey \(seed)/\(ring) vs real \(other)/\(otherRing)"
                                }
                            }
                        }
                    }
                }
                // Measured 13.84 for the standard ramp and 9.29 for the safe
                // one, whose outermost rings wash out further. The pair of
                // constants this replaced managed 8.1.
                #expect(worst >= 9,
                        "\(ramp)/\(scheme): nearest real fill is ΔE2000 \(worst) — \(worstCase)")
            }
        }
    }

    /// Nesting has to read, and "the outer rings recede" is a perceptual claim
    /// rather than a claim about a saturation multiplier.
    @Test("The outermost ring is visibly further away than the innermost")
    func ringRecessionIsVisible() {
        for ramp in SunburstRamp.allCases {
            let palette = SunburstPalette(ramp: ramp)
            for scheme in [ColorScheme.light, .dark] {
                for seed in 0..<palette.swatchCount(scheme) {
                    let inner = palette.swatch(seed: UInt16(seed), ring: 0, scheme: scheme)
                    let outer = palette.swatch(seed: UInt16(seed),
                                               ring: SunburstGeometry.maximumRings, scheme: scheme)
                    #expect(ColourMetrics.difference(inner, outer) >= 8,
                            "\(ramp)/\(scheme) seed \(seed) barely recedes")
                    #expect(inner.hue == outer.hue)
                }
            }
        }
    }
}
