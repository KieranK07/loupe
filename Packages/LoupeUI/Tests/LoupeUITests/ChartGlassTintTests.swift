import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

/// The tint the floating chrome picks up from the data, as arithmetic.
///
/// Everything worth asserting about a tint is a number: how strong it is, which
/// way round the hue wheel it travels, and whether the text on top of it is
/// still readable. None of that needs a screen, and all of it is the kind of
/// thing that gets nudged in a hurry and noticed six months later on somebody
/// else's display.
@Suite("Tinting glass with the data")
struct ChartGlassTintTests {

    // MARK: - Compositing, for the legibility proofs below

    /// Stand-ins for the semantic window background the Reduce Transparency
    /// fallback draws on.
    ///
    /// Not the exact system colours — reading those would need an `NSColor`
    /// round-trip and would make this a test of AppKit — but within a point or
    /// two of them and pessimistic in the direction that matters: the light one
    /// is the brightest a panel ever is, so a dark tint has the furthest to
    /// drag it, and the dark one the darkest.
    private static let lightBackdrop = (1.0, 1.0, 1.0)
    private static let darkBackdrop = (0.118, 0.118, 0.125)

    private func backdrop(_ scheme: ColorScheme) -> (Double, Double, Double) {
        scheme == .dark ? Self.darkBackdrop : Self.lightBackdrop
    }

    /// Source-over, in the encoded space Core Graphics blends sRGB in.
    private func composite(_ tint: SunburstSwatch, strength: Double,
                           over backdrop: (Double, Double, Double)) -> Double {
        let c = tint.components
        let r = c.red * strength + backdrop.0 * (1 - strength)
        let g = c.green * strength + backdrop.1 * (1 - strength)
        let b = c.blue * strength + backdrop.2 * (1 - strength)
        return Contrast.relativeLuminance(red: r, green: g, blue: b)
    }

    /// Every swatch the chrome could ever be handed a tint from.
    private func everySwatch() -> [(swatch: SunburstSwatch, scheme: ColorScheme, what: String)] {
        var all: [(SunburstSwatch, ColorScheme, String)] = []
        for ramp in SunburstRamp.allCases {
            let palette = SunburstPalette(ramp: ramp)
            for scheme in [ColorScheme.light, .dark] {
                for seed in 0..<palette.swatchCount(scheme) {
                    for ring in 0...SunburstGeometry.maximumRings {
                        for kind in [WedgeKind.real, .aggregated(count: 7), .stillScanning] {
                            for highlighted in [false, true] {
                                let swatch = palette.swatch(seed: UInt16(seed), ring: ring,
                                                            kind: kind, scheme: scheme,
                                                            highlighted: highlighted)
                                all.append((swatch, scheme,
                                            "\(ramp)/\(scheme)/seed \(seed)/ring \(ring)/\(kind)"))
                            }
                        }
                    }
                }
            }
        }
        return all
    }

    // MARK: - A whisper, not a fill

    /// The claim the whole tint rests on. A panel that flipped across the middle
    /// would leave `Color.primary` — which is chosen by the appearance, not by
    /// the panel — the wrong colour, with no line of code having been wrong.
    @Test("A tinted panel stays on the right side of its appearance")
    func tintKeepsPolarity() {
        for case (let swatch, let scheme, let what) in everySwatch() {
            let luminance = composite(swatch, strength: ChartGlassTint.strength,
                                      over: backdrop(scheme))
            switch scheme {
            case .dark:
                #expect(luminance <= ChartGlassTint.maximumDarkPanelLuminance,
                        "\(what) lifted a dark panel to \(luminance)")
            default:
                #expect(luminance >= ChartGlassTint.minimumLightPanelLuminance,
                        "\(what) dropped a light panel to \(luminance)")
            }
        }
    }

    /// The readout's title is the line that identifies what you are pointing at,
    /// so it is held to WCAG AA for body text on every tint the chart can hand
    /// the chrome. Measured against the Reduce Transparency fallback, because
    /// that is the surface whose composition is knowable — glass samples a chart
    /// nobody can predict, which is exactly why the fallback exists.
    @Test("The readout's title clears WCAG AA on every tint, in both appearances")
    func titleStaysLegible() {
        for case (let swatch, let scheme, let what) in everySwatch() {
            let panel = composite(swatch, strength: ChartGlassTint.strength,
                                  over: backdrop(scheme))
            // `Color.primary` is black in a light appearance and white in a dark
            // one, and it is chosen by the appearance rather than by the panel.
            let ink = scheme == .dark ? 1.0 : 0.0
            let ratio = Contrast.ratio(ink, panel)
            #expect(ratio >= 4.5, "\(what) left the title at \(ratio):1")
        }
    }

    @Test("The tint is a fraction of the panel rather than the panel")
    func tintIsAWhisper() {
        #expect(ChartGlassTint.strength > 0, "an invisible tint carries no information")
        #expect(ChartGlassTint.strength <= 0.35)
    }

    // MARK: - Which way round the wheel

    @Test("Hue takes the short way round, including across the wrap")
    func hueGoesTheShortWay() {
        // Red at 0.02 to magenta at 0.94 is a twelfth of the wheel backwards,
        // not eleven twelfths forwards through orange, green and cyan.
        let backwards = ChartGlassTint.shortestHueDelta(from: 0.02, to: 0.94)
        #expect(backwards < 0)
        #expect(abs(backwards + 0.08) < 1e-9)

        let forwards = ChartGlassTint.shortestHueDelta(from: 0.94, to: 0.02)
        #expect(forwards > 0)
        #expect(abs(forwards - 0.08) < 1e-9)

        #expect(abs(ChartGlassTint.shortestHueDelta(from: 0.1, to: 0.3) - 0.2) < 1e-9)
        #expect(abs(ChartGlassTint.shortestHueDelta(from: 0.3, to: 0.1) + 0.2) < 1e-9)
        // Exactly opposite is a coin toss; it only has to be half a turn.
        #expect(abs(abs(ChartGlassTint.shortestHueDelta(from: 0.0, to: 0.5)) - 0.5) < 1e-9)
    }

    /// The property behind the example above: an interpolated hue never leaves
    /// the short arc between its endpoints. A lerp that went the long way would
    /// pass through hues that are in neither swatch, which on screen is a
    /// rainbow wipe across the chrome.
    @Test("A blend never visits a hue outside the short arc")
    func blendStaysOnTheShortArc() {
        for a in stride(from: 0.0, to: 1.0, by: 0.05) {
            for b in stride(from: 0.0, to: 1.0, by: 0.05) {
                let from = SunburstSwatch(hue: a, saturation: 0.8, brightness: 0.8)
                let to = SunburstSwatch(hue: b, saturation: 0.8, brightness: 0.8)
                let arc = abs(ChartGlassTint.shortestHueDelta(from: a, to: b))
                for t in stride(from: 0.0, through: 1.0, by: 0.1) {
                    guard let hue = ChartGlassTint.blend(from: from, to: to, progress: t).swatch?.hue
                    else { Issue.record("blend of two swatches produced none"); continue }
                    #expect(hue >= 0 && hue < 1, "hue \(hue) left the wheel")
                    let travelled = abs(ChartGlassTint.shortestHueDelta(from: a, to: hue))
                    #expect(travelled <= arc + 1e-9,
                            "\(a) to \(b) at \(t) reached \(hue), \(travelled) round from the start")
                }
            }
        }
    }

    // MARK: - Appearing, changing, disappearing

    private let red = SunburstSwatch(hue: 0.0, saturation: 0.9, brightness: 0.9)
    private let teal = SunburstSwatch(hue: 0.5, saturation: 0.9, brightness: 0.9)

    /// The three cases are genuinely different, and collapsing them is the bug
    /// this function exists to avoid.
    @Test("Colour to colour slides at full strength; nothing to colour fades up")
    func blendCases() {
        // Sliding. If this cross-faded through zero the readout would blink pale
        // every time the pointer crossed a boundary.
        for t in stride(from: 0.0, through: 1.0, by: 0.25) {
            let mid = ChartGlassTint.blend(from: red, to: teal, progress: t)
            #expect(mid.strength == ChartGlassTint.strength, "the slide dipped at \(t)")
            #expect(mid.swatch != nil)
        }
        #expect(ChartGlassTint.blend(from: red, to: teal, progress: 0).swatch == red)
        #expect(ChartGlassTint.blend(from: red, to: teal, progress: 1).swatch == teal)

        // Fading up out of nothing, and back down into it.
        #expect(ChartGlassTint.blend(from: nil, to: teal, progress: 0) == .none)
        #expect(ChartGlassTint.blend(from: nil, to: teal, progress: 0.5).strength
            == ChartGlassTint.strength / 2)
        #expect(ChartGlassTint.blend(from: nil, to: teal, progress: 1).strength
            == ChartGlassTint.strength)
        #expect(ChartGlassTint.blend(from: red, to: nil, progress: 1) == .none,
                "a finished fade-out must leave no swatch, or the next fade-in starts opaque")
        #expect(ChartGlassTint.blend(from: nil, to: nil, progress: 0.5) == .none)
    }

    @Test("Progress outside 0...1 is clamped rather than extrapolated")
    func blendClamps() {
        #expect(ChartGlassTint.blend(from: red, to: teal, progress: -3).swatch == red)
        #expect(ChartGlassTint.blend(from: red, to: teal, progress: 4).swatch == teal)
        #expect(ChartGlassTint.blend(from: nil, to: teal, progress: 9).strength
            == ChartGlassTint.strength)
    }

    /// Zero strength and no swatch are the same state, and a `ChartTint` that let
    /// them come apart would put an invisible colour into the interpolator and
    /// restart the next fade from it.
    @Test("A tint with no strength has no colour")
    func strengthAndSwatchAgree() {
        #expect(ChartTint(swatch: red, strength: 0).swatch == nil)
        #expect(ChartTint(swatch: red, strength: 0).color == nil)
        #expect(ChartTint(swatch: nil, strength: 0.4).strength == 0)
        #expect(ChartTint(swatch: red, strength: 0.4).color != nil)
    }

    // MARK: - Reduce Motion

    /// Every animation in the chrome comes from `ChartGlassMotion`, so this is
    /// the whole of the Reduce Motion contract for the cluster, the rail and the
    /// readout: no caller can animate without asking, and asking honours it.
    @Test("Reduce Motion means no animation at all, everywhere in the chrome")
    func reduceMotionIsHonoured() {
        #expect(ChartGlassMotion.morph(reduceMotion: true) == nil)
        #expect(ChartGlassMotion.crumbs(reduceMotion: true) == nil)
        #expect(ChartGlassMotion.tint(reduceMotion: true) == nil)
        #expect(ChartGlassMotion.morph(reduceMotion: false) != nil)
        #expect(ChartGlassMotion.crumbs(reduceMotion: false) != nil)
        #expect(ChartGlassMotion.tint(reduceMotion: false) != nil)
    }

    /// The two group spacings are only correct *relative* to the container's
    /// merge distance: members have to fuse into one pill and groups have to
    /// stay apart, and both are decided by this comparison rather than by how
    /// the numbers look.
    @Test("Members merge and groups do not")
    func spacingsStraddleTheMergeDistance() {
        #expect(ChartGlassMetrics.memberSpacing < ChartGlassMetrics.containerSpacing)
        #expect(ChartGlassMetrics.groupSpacing > ChartGlassMetrics.containerSpacing)
    }
}

/// How the trail moves when you navigate.
@Suite("The breadcrumb rail moves with the navigation")
struct ChartBreadcrumbMotionTests {
    private func crumbs(_ names: [Int]) -> [Breadcrumb] {
        names.map { Breadcrumb(node: .directory(UInt32($0)), name: "f\($0)") }
    }

    @Test("Going in is a descent and coming out is not")
    func directions() {
        #expect(ChartBreadcrumbTrail.change(from: crumbs([1, 2]), to: crumbs([1, 2, 3])) == .deeper)
        #expect(ChartBreadcrumbTrail.change(from: crumbs([1, 2, 3]), to: crumbs([1, 2])) == .shallower)
        #expect(ChartBreadcrumbTrail.change(from: crumbs([1, 2]), to: crumbs([1, 2])) == .unchanged)
    }

    /// The case the distinction exists for. Switching volumes shares nothing
    /// with the trail before it, and sliding the new crumbs in from where the
    /// old ones left would claim a continuity that is not there.
    @Test("A different disk is a replacement, not a move along the same path")
    func replacement() {
        #expect(ChartBreadcrumbTrail.change(from: crumbs([1, 2, 3]), to: crumbs([9, 8])) == .replaced)
        #expect(ChartBreadcrumbTrail.change(from: crumbs([1, 2]), to: crumbs([1, 9, 3])) == .replaced)
        // The first trail of a session arrives out of nothing. That is a
        // replacement too — there is nowhere for it to have come from.
        #expect(ChartBreadcrumbTrail.change(from: [], to: crumbs([1, 2])) == .replaced)
    }

    /// Compared by node rather than by name: two folders can share a name, and a
    /// scan regenerating the same trail ten times a second must not read as ten
    /// jumps.
    @Test("Identity is the node, not the name")
    func comparedByNode() {
        let one = [Breadcrumb(node: .directory(1), name: "Library"),
                   Breadcrumb(node: .directory(2), name: "Caches")]
        let renamed = [Breadcrumb(node: .directory(1), name: "Library"),
                       Breadcrumb(node: .directory(2), name: "Caches (2)")]
        #expect(ChartBreadcrumbTrail.change(from: one, to: renamed) == .unchanged)

        let sameNames = [Breadcrumb(node: .directory(7), name: "Library"),
                         Breadcrumb(node: .directory(8), name: "Caches")]
        #expect(ChartBreadcrumbTrail.change(from: one, to: sameNames) == .replaced)
    }
}
