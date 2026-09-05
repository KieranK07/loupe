import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

/// The safety property `SunburstShading` states and the palette has to keep.
///
/// A flat fill let ink be chosen against the one colour the wedge was. A
/// gradient means the label lies across a *range*, and an ink that is
/// comfortable against the middle of that range can be thin at one end of it —
/// invisible in a swatch, obvious on a disk, and impossible to find by eye
/// across two ramps, two appearances, nine rings, three kinds and two states.
///
/// So it is arithmetic instead. If a retune ever lands a base where the
/// gradient can no longer carry a legible label, this suite fails rather than
/// the chart quietly becoming unreadable.
@Suite("Colour: ink on a gradient")
struct PaletteShadingInkTests {
    private static let kinds: [WedgeKind] = [.real, .stillScanning, .aggregated(count: 12)]

    /// The whole point. Note it measures the ink chosen from `swatch` — the
    /// reference colour, which is what the renderer passes — against the ends
    /// the renderer actually fills with.
    @Test("Every label clears the comfort ratio at both ends of its gradient")
    func inkSurvivesBothEndpoints() {
        var worst = Double.infinity
        var worstCase = ""
        var checked = 0
        for ramp in SunburstRamp.allCases {
            let palette = SunburstPalette(ramp: ramp)
            for scheme in [ColorScheme.light, .dark] {
                for seed in 0..<palette.swatchCount(scheme) {
                    for ring in UInt8(0)...SunburstGeometry.maximumRings {
                        for kind in Self.kinds {
                            for highlighted in [false, true] {
                                let fill = palette.swatch(seed: UInt16(seed), ring: ring,
                                                          kind: kind, scheme: scheme,
                                                          highlighted: highlighted)
                                let shading = palette.shading(seed: UInt16(seed), ring: ring,
                                                              kind: kind, scheme: scheme,
                                                              highlighted: highlighted)
                                let ink = palette.ink(on: fill)
                                for end in [shading.inner, shading.outer] {
                                    let ratio = ink.contrastRatio(over: end)
                                    checked += 1
                                    if ratio < worst {
                                        worst = ratio
                                        worstCase = "\(ramp)/\(scheme) seed \(seed) ring \(ring) "
                                            + "\(kind) highlighted=\(highlighted), "
                                            + "fill luminance \(fill.relativeLuminance)"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(checked > 3000, "the sweep did not cover the palette")
        // Measured 5.002:1, which is as tight as it looks — the bases were
        // searched against this bound, so the ramp sits right on it. A failure
        // here is almost always one base drifting into the luminance near 0.18
        // where neither black nor white ink reaches 5:1; the fix is the base,
        // not the bound.
        #expect(worst >= SunburstPalette.inkComfortRatio,
                "worst label contrast across a gradient is \(worst):1 at \(worstCase)")
    }

    /// `ink(on:)` restates the shading rule instead of calling it, because it
    /// is handed a swatch and a swatch does not know which wedge it came from.
    /// This is the guard on that duplication: the two have to agree on every
    /// fill that is actually drawn as a gradient.
    @Test("The envelope the ink rule reasons about is the gradient that gets drawn")
    func envelopeMatchesShading() {
        for ramp in SunburstRamp.allCases {
            let palette = SunburstPalette(ramp: ramp)
            for scheme in [ColorScheme.light, .dark] {
                for seed in 0..<palette.swatchCount(scheme) {
                    for ring in UInt8(0)...SunburstGeometry.maximumRings {
                        for kind: WedgeKind in [.real, .stillScanning] {
                            let fill = palette.swatch(seed: UInt16(seed), ring: ring,
                                                      kind: kind, scheme: scheme)
                            let drawn = palette.shading(seed: UInt16(seed), ring: ring,
                                                        kind: kind, scheme: scheme)
                            let assumed = SunburstPalette.shadingEnvelope(of: fill)
                            #expect(assumed.lit == drawn.inner,
                                    "\(ramp)/\(scheme) seed \(seed) ring \(ring) lit end drifted")
                            #expect(assumed.shade == drawn.outer,
                                    "\(ramp)/\(scheme) seed \(seed) ring \(ring) shade end drifted")
                        }
                    }
                }
            }
        }
    }

    /// An aggregated mark is filled flat, so the envelope the ink rule assumes
    /// is wider than the mark really spans. That costs it some softness and
    /// nothing else — worth stating, because the alternative reading is that
    /// the rule is wrong there.
    @Test("The ink rule is conservative, never optimistic, about a flat fill")
    func flatFillsAreJudgedGenerously() {
        let palette = SunburstPalette()
        for scheme in [ColorScheme.light, .dark] {
            for seed in 0..<palette.swatchCount(scheme) {
                let fill = palette.swatch(seed: UInt16(seed), ring: 0,
                                          kind: .aggregated(count: 3), scheme: scheme)
                let shading = palette.shading(seed: UInt16(seed), ring: 0,
                                              kind: .aggregated(count: 3), scheme: scheme)
                #expect(shading.inner == fill)
                #expect(shading.outer == fill)
                let ink = palette.ink(on: fill)
                #expect(ink.contrastRatio(over: fill) >= SunburstPalette.inkComfortRatio)
            }
        }
    }

    /// The light source is fixed in the view rather than in the mark, so the
    /// near end is the lit one on every wedge of the disk at once. A ramp whose
    /// entries disagreed about that would read as a bag of separate objects.
    ///
    /// Stated as luminance rather than as brightness on purpose: the lit end
    /// gains a little saturation as well, and on a base already at full value
    /// that costs luminance back. The claim that has to hold is about the light,
    /// not about the HSB number.
    @Test("The near end is the lit end, on every fill, in both appearances")
    func gradientRunsTheSameWayEverywhere() {
        for ramp in SunburstRamp.allCases {
            let palette = SunburstPalette(ramp: ramp)
            for scheme in [ColorScheme.light, .dark] {
                for seed in 0..<palette.swatchCount(scheme) {
                    for ring in UInt8(0)...SunburstGeometry.maximumRings {
                        let fill = palette.swatch(seed: UInt16(seed), ring: ring, scheme: scheme)
                        let drawn = palette.shading(seed: UInt16(seed), ring: ring, scheme: scheme)
                        #expect(drawn.inner.relativeLuminance > drawn.outer.relativeLuminance,
                                "\(ramp)/\(scheme) seed \(seed) ring \(ring) is lit backwards")
                        // Hue never varies across a mark: that a folder has *a*
                        // colour is the thing the whole palette is for.
                        #expect(drawn.inner.hue == fill.hue)
                        #expect(drawn.outer.hue == fill.hue)
                    }
                }
            }
        }
    }
}
