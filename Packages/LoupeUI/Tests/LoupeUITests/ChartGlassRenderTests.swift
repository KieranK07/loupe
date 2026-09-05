import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

/// The floating chrome, actually rendered.
///
/// With one honest limitation stated up front: Liquid Glass is a compositor
/// effect that samples what is behind it, and offscreen in an `ImageRenderer`
/// there is nothing behind it — so a glass surface rasterises to almost
/// nothing here however correct it is. That makes pixels a useless oracle for
/// the glass path and a good one for the fallback, which is the path that has
/// to keep working when someone turns Reduce Transparency on and which nobody
/// looks at. So: the fallback is checked in pixels, and the glass path is
/// checked for building and rendering without falling over.
@Suite("The floating chrome actually draws")
@MainActor
struct ChartGlassRenderTests {

    private func render(_ view: some View, surface: ChartSurface,
                        scheme: ColorScheme, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .environment(\.chartSurfaceOverride, surface)
            .environment(\.colorScheme, scheme)
            .padding(20)
            .frame(width: size.width, height: size.height))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// The Reduce Transparency path, in pixels. `floor` is deliberately loose:
    /// what is being asserted is "this drew", not a layout.
    private func expectFallbackDraws(_ view: some View, size: CGSize, floor: Double,
                                     what: String,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        for scheme in [ColorScheme.light, .dark] {
            guard let image = render(view, surface: .solid, scheme: scheme, size: size) else {
                Issue.record("\(what) produced no image on the fallback in \(scheme)",
                             sourceLocation: sourceLocation)
                continue
            }
            #expect(RenderProbe.inkCoverage(image) > floor,
                    "\(what) drew nothing on the fallback in \(scheme)",
                    sourceLocation: sourceLocation)
        }
    }

    /// Both surfaces, both appearances, no assertion about what came out —
    /// this is here to catch a crash, an infinite layout or a nil unwrap.
    private func expectRenders(_ view: some View, size: CGSize, what: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        for surface in ChartSurface.allCases {
            for scheme in [ColorScheme.light, .dark] {
                #expect(render(view, surface: surface, scheme: scheme, size: size) != nil,
                        "\(what) produced no image on \(surface)/\(scheme)",
                        sourceLocation: sourceLocation)
            }
        }
    }

    @Test("The hover readout falls back to an opaque surface and still paints")
    func hoverReadoutFallback() {
        expectFallbackDraws(ChartHoverReadout(title: "Application Support",
                                              detail: "4.21 GB on disk · 38 percent of Library"),
                            size: CGSize(width: 340, height: 120), floor: 0.10,
                            what: "readout")
        expectFallbackDraws(ChartHoverReadout(title: "318 smaller items",
                                              detail: "12 MB on disk · less than 1 percent of Caches",
                                              footnote: "Each is too small to draw separately.",
                                              tint: SunburstPalette()
                                                  .color(seed: 4, ring: 1, scheme: .light).opacity(0.3)),
                            size: CGSize(width: 340, height: 150), floor: 0.10,
                            what: "tinted readout")
    }

    @Test("The legend falls back to an opaque surface and still paints")
    func legendFallback() {
        let index = SunburstIndex(Fixture.layout(
            levels: [[6, 4, 3, 2, 1]],
            kindForRing: { _, child in
                if child == 3 { .aggregated(count: 214) }
                else if child == 4 { .stillScanning }
                else { .real }
            }))
        for scheme in [ColorScheme.light, .dark] {
            let entries = ChartLegendEntry.entries(for: index, palette: SunburstPalette(),
                                                   scheme: scheme, basis: .physical)
            #expect(entries.count == 5)
            expectFallbackDraws(ChartLegend(entries: entries),
                                size: CGSize(width: 300, height: 280), floor: 0.20,
                                what: "legend/\(scheme)")
        }
    }

    @Test("The breadcrumb rail falls back to an opaque surface and still paints")
    func breadcrumbFallback() {
        let long = (0..<9).map { Breadcrumb(node: .directory(UInt32($0)), name: "folder\($0)") }
        expectFallbackDraws(ChartBreadcrumbRail(crumbs: long) { _ in },
                            size: CGSize(width: 640, height: 100), floor: 0.005,
                            what: "condensed rail")
    }

    /// A legend with nothing in it is nothing, not an empty panel hovering over
    /// the chart.
    @Test("An empty legend draws nothing at all")
    func emptyLegend() {
        guard let image = render(ChartLegend(entries: []), surface: .solid,
                                 scheme: .light, size: CGSize(width: 300, height: 240))
        else { return }
        #expect(RenderProbe.inkCoverage(image) < 0.001, "an empty legend painted something")
    }

    /// The readout on the shipping path: handed a swatch rather than a colour,
    /// so it owns the transition between one mark's colour and the next. The
    /// fallback still has to be an opaque panel with legible text on it — the
    /// tint arithmetic is proved in `ChartGlassTintTests`, and this is only
    /// asserting that the tinted path still reaches a surface at all.
    @Test("The readout that carries a mark's colour paints on both surfaces")
    func swatchTintedReadout() {
        let palette = SunburstPalette()
        let text = ChartReadoutText(title: "Application Support",
                                    detail: "4.21 GB on disk · 38 percent of Library")
        for seed: UInt16 in [0, 3, 9] {
            let readout = ChartHoverReadout(text, swatch: palette.swatch(seed: seed, ring: 1))
            expectFallbackDraws(readout, size: CGSize(width: 340, height: 120),
                                floor: 0.10, what: "readout tinted by seed \(seed)")
            expectRenders(readout, size: CGSize(width: 340, height: 120),
                          what: "readout tinted by seed \(seed)")
        }
        // No mark under the pointer is a real state — the readout is shown over
        // the margin of the map on the way to a tile — and it must not be a
        // crash on the way to an optional.
        expectRenders(ChartHoverReadout(text, swatch: nil),
                      size: CGSize(width: 340, height: 120), what: "untinted readout")
    }

    @Test("Every floating component renders on both surfaces without falling over")
    func everythingRenders() {
        expectRenders(ChartControlCluster(viewMode: .constant(.sunburst),
                                          basis: .constant(.physical),
                                          zoomOutTarget: "Users") {},
                      size: CGSize(width: 480, height: 100), what: "control cluster")
        // Three chart modes, two bases and a way out that comes and goes. The
        // busiest configuration is the one that overflows a row, so every
        // combination gets rendered rather than the one that fits.
        for mode in ChartViewMode.allCases {
            for basis in SizeBasis.allCases {
                for target in [nil, "Application Support"] {
                    expectRenders(ChartControlCluster(viewMode: .constant(mode),
                                                      basis: .constant(basis),
                                                      zoomOutTarget: target),
                                  size: CGSize(width: 560, height: 100),
                                  what: "cluster \(mode)/\(basis)/\(target ?? "no way out")")
                }
            }
        }
        expectRenders(ChartHoverReadout(title: "Library", detail: "1 GB on disk"),
                      size: CGSize(width: 320, height: 100), what: "readout")
        expectRenders(ChartBreadcrumbRail(crumbs: [
            Breadcrumb(node: .directory(1), name: "Macintosh HD"),
            Breadcrumb(node: .directory(2), name: "Users"),
        ]) { _ in }, size: CGSize(width: 420, height: 100), what: "short rail")
        expectRenders(ChartLegend(entries: []), size: CGSize(width: 240, height: 120),
                      what: "empty legend")
    }
}
