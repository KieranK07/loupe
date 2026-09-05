import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

/// The drawing itself cannot be asserted meaningfully, but it can be *run*.
/// These render the chart offscreen and check that the pixels are not blank —
/// enough to catch a path built the wrong way round, a divide by zero in the
/// metrics, or a crash in the hatching, none of which the pure tests can see.
///
/// They render `SunburstCanvas` rather than `SunburstChart`, because the rings,
/// the emphasis and the labels are three separate canvases now and a test that
/// only drew the bottom one could not tell you whether hover draws at all.
@Suite("The chart actually draws")
@MainActor
struct SunburstRenderSmokeTests {
    private func render(_ view: some View, size: CGFloat = 480) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        renderer.scale = 1
        return renderer.cgImage
    }

    private func inkCoverage(_ image: CGImage) -> Double { RenderProbe.inkCoverage(image) }

    static func index() -> SunburstIndex {
        SunburstIndex(Fixture.layout(
            levels: [[4, 3, 2, 1], [3, 2, 1], [2, 1]],
            kindForRing: { ring, child in
                if ring == 2, child == 0 { .aggregated(count: 318) }
                else if ring == 1, child == 1 { .stillScanning }
                else { .real }
            }))
    }

    private func chart(progress: Double = 1,
                       departing: SunburstIndex? = nil,
                       timing: SunburstAnimation.Timing = .immediate,
                       hovered: SunburstPosition? = nil,
                       hoverPhase: Double = 1,
                       pressed: SunburstPosition? = nil,
                       pressPhase: Double = 0,
                       keyboardFocus: SunburstPosition? = nil,
                       dashSeed: Double = 0,
                       scheme: ColorScheme = .light) -> some View {
        let index = Self.index()
        let navigator = SunburstNavigator(index: index)
        let palette = SunburstPalette()
        return SunburstCanvas(
            progress: progress,
            hoverPhase: hoverPhase,
            pressPhase: pressPhase,
            current: index,
            departing: departing,
            timing: timing,
            metrics: SunburstMetrics(size: CGSize(width: 480, height: 480),
                                     ringCount: index.ringCount),
            table: SunburstColorTable(palette: palette, scheme: scheme),
            gradients: MarkGradientTable(palette: palette, scheme: scheme),
            hoverA: .none,
            hoverB: SunburstHoverTarget(
                position: hovered,
                chain: hovered.map { Set(navigator.ancestors(of: $0)) } ?? []),
            pressed: pressed,
            keyboardFocus: keyboardFocus,
            search: .inactive,
            options: SunburstOptions(),
            dashSeed: dashSeed,
            hidesOverlays: false)
    }

    @Test("A resting chart paints the rings")
    func restingChart() throws {
        let image = try #require(render(chart()))
        let coverage = inkCoverage(image)
        // A three-ring chart in a 480pt square covers a good part of it, but
        // nowhere near all of it — the centre disc and the corners stay clear.
        #expect(coverage > 0.25, "the chart painted almost nothing: \(coverage)")
        #expect(coverage < 0.85, "the chart painted almost everything: \(coverage)")
    }

    @Test("Hover and keyboard focus both draw, and draw differently")
    func emphasisDraws() throws {
        let plain = try #require(render(chart()))
        let hovered = try #require(render(chart(hovered: SunburstPosition(ring: 1, offset: 2))))
        let focused = try #require(render(chart(keyboardFocus: SunburstPosition(ring: 1, offset: 2))))

        #expect(inkCoverage(hovered) > 0.2)
        #expect(inkCoverage(focused) > 0.2)
        #expect(!identical(plain, hovered), "hover changed nothing on screen")
        #expect(!identical(plain, focused), "keyboard focus changed nothing on screen")
        #expect(!identical(hovered, focused),
                "hover and keyboard focus must not look the same")
    }

    /// A lift that is only visible at full strength is a lift that snaps.
    @Test("The hover lift is drawn part-way through, not only at the end")
    func hoverAnimatesRatherThanSnapping() throws {
        let position = SunburstPosition(ring: 1, offset: 2)
        let none = try #require(render(chart(hovered: position, hoverPhase: 0)))
        let half = try #require(render(chart(hovered: position, hoverPhase: 0.5)))
        let full = try #require(render(chart(hovered: position, hoverPhase: 1)))
        #expect(!identical(none, half), "half a hover looks like no hover")
        #expect(!identical(half, full), "half a hover looks like a whole hover")
    }

    @Test("A click is acknowledged on screen before anything moves")
    func pressDraws() throws {
        let position = SunburstPosition(ring: 0, offset: 1)
        let plain = try #require(render(chart()))
        // `pressPulse` peaks near a quarter of the way through.
        let pressing = try #require(render(chart(pressed: position, pressPhase: 0.25)))
        #expect(!identical(plain, pressing), "the click left no mark on the chart")
    }

    @Test("Mid-zoom frames draw without falling over", arguments: [0.0, 0.25, 0.5, 0.75, 1.0])
    func transitionFrames(progress: Double) throws {
        let departing = SunburstIndex(Fixture.layout(levels: [[1, 1], [5, 1, 1]],
                                                     startAt: 5.9, generation: 1))
        let image = try #require(render(chart(progress: progress, departing: departing,
                                              timing: .zoom(depthChange: 1))))
        #expect(inkCoverage(image) > 0.15, "progress \(progress) painted almost nothing")
    }

    @Test("Growth frames draw without falling over", arguments: [0.0, 0.3, 0.7, 1.0])
    func growthFrames(progress: Double) throws {
        let departing = SunburstIndex(Fixture.layout(levels: [[4, 3, 2, 1], [3, 2, 1]],
                                                     generation: 1))
        let image = try #require(render(chart(progress: progress, departing: departing,
                                              timing: .growth(interval: 0.1), dashSeed: 3)))
        #expect(inkCoverage(image) > 0.15, "progress \(progress) painted almost nothing")
    }

    /// The bloom starts from nothing, so the early frames are genuinely emptier
    /// than the late ones.
    ///
    /// The margin is a *half*, not any increase at all. A looser assertion
    /// passes on the entrance's camera dolly alone — the rings start at 0.93
    /// and grow, which raises coverage a few percent whether or not a single
    /// wedge is opening. Half the disk missing a sixth of the way in can only
    /// be the entrance actually blooming.
    @Test("The first appearance sweeps in rather than popping")
    func entranceBlooms() throws {
        let empty = SunburstIndex(.empty)
        let early = try #require(render(chart(progress: 0.15, departing: empty, timing: .entrance)))
        let late = try #require(render(chart(progress: 0.95, departing: empty, timing: .entrance)))
        let rest = try #require(render(chart()))
        // A `Comment` is built from one string literal — concatenating two of
        // them does not type-check, however ordinary it looks.
        #expect(inkCoverage(early) < inkCoverage(late) * 0.5,
                "the disk was already full a sixth of the way in: \(inkCoverage(early)) against \(inkCoverage(late))")
        #expect(inkCoverage(late) <= inkCoverage(rest) + 0.02)
    }

    @Test("Dark mode paints too, and not the same as light")
    func darkMode() throws {
        let light = try #require(render(chart(scheme: .light)))
        let dark = try #require(render(chart(scheme: .dark)))
        #expect(inkCoverage(dark) > 0.25)
        #expect(!identical(light, dark))
    }

    @Test("A window too small for the rings draws nothing rather than crashing")
    func degenerateSize() throws {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1]]))
        let palette = SunburstPalette()
        let tiny = SunburstCanvas(
            progress: 1, hoverPhase: 0, pressPhase: 0, current: index, departing: nil,
            timing: .immediate,
            metrics: SunburstMetrics(size: CGSize(width: 8, height: 8),
                                     ringCount: index.ringCount),
            table: SunburstColorTable(palette: palette, scheme: .light),
            gradients: MarkGradientTable(palette: palette, scheme: .light),
            hoverA: .none, hoverB: .none, pressed: nil, keyboardFocus: nil,
            search: .inactive, options: SunburstOptions(), dashSeed: 0, hidesOverlays: false)
        _ = render(tiny, size: 8)
    }

    private func identical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        guard let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data? else {
            return false
        }
        return da == db
    }
}
