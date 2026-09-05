import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

/// The drawing itself cannot be asserted meaningfully, but it can be *run*.
/// These render the map offscreen and check the pixels are not blank — enough
/// to catch a rectangle built the wrong way round, a divide by zero in the
/// metrics, or a crash in the hatching, none of which the pure tests can see.
@Suite("The treemap actually draws")
@MainActor
struct TreemapRenderSmokeTests {
    private func render(_ view: some View, width: CGFloat = 640, height: CGFloat = 420) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 1
        return renderer.cgImage
    }

    private func inkCoverage(_ image: CGImage) -> Double { RenderProbe.inkCoverage(image) }

    /// Mean brightness of a small block at `fraction` of the way across and
    /// down the image, in whatever orientation `CGContext` hands it back.
    ///
    /// Which way up that is does not matter and is deliberately not assumed —
    /// see `topLeftIsBrighter`. A block rather than one pixel because a single
    /// pixel can land on a hairline stroke.
    private func brightness(_ image: CGImage, at fraction: Double) -> Double? {
        let width = image.width, height = image.height
        guard width > 32, height > 32 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let cx = Int(Double(width) * fraction), cy = Int(Double(height) * fraction)
        var total = 0.0, samples = 0
        for row in (cy - 4)...(cy + 4) where row >= 0 && row < height {
            for column in (cx - 4)...(cx + 4) where column >= 0 && column < width {
                let i = (row * width + column) * 4
                total += (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 765
                samples += 1
            }
        }
        return samples > 0 ? total / Double(samples) : nil
    }

    /// Whether one diagonal corner is brighter than the other, or `nil` when the
    /// two are within noise — which is what a flat fill looks like.
    ///
    /// Sampled near the corners rather than near the middle: a two-stop gradient
    /// read at 30% and 70% only shows two fifths of its spread, and the palette
    /// spreads about five points of brightness either side of the reference
    /// colour on purpose. Measuring the small part of a deliberately small
    /// signal is how a real gradient reads as flat.
    private func topLeftIsBrighter(_ image: CGImage) -> Bool? {
        guard let near = brightness(image, at: 0.10), let far = brightness(image, at: 0.90) else {
            return nil
        }
        // Two levels out of 255. Sampled sixty points from the nearest edge, so
        // there is no antialiasing to confuse it with.
        guard abs(near - far) > 0.008 else { return nil }
        return near > far
    }

    private func chart(hovered: TreemapPosition? = nil,
                       keyboardFocus: TreemapPosition? = nil,
                       search: SunburstSearchResult = .inactive,
                       scheme: ColorScheme = .light,
                       departing: TreemapIndex? = nil,
                       progress: Double = 1,
                       hoverLift: Double = 1) -> TreemapChart {
        let index = TreemapIndex(TreemapFixture.layout(
            levels: [4, 3, 3],
            kindForDepth: { depth, child in
                if depth == 2, child == 0 { .aggregated(count: 318) }
                else if depth == 1, child == 1 { .stillScanning }
                else { .real }
            }))
        let navigator = TreemapNavigator(index: index)
        let palette = SunburstPalette()
        return TreemapChart(index: index,
                            metrics: TreemapMetrics(size: CGSize(width: 640, height: 420)),
                            table: SunburstColorTable(palette: palette, scheme: scheme),
                            shading: TreemapShadingTable(palette: palette, scheme: scheme),
                            departing: departing,
                            progress: progress,
                            hoverLift: hoverLift,
                            hovered: hovered,
                            hoverChain: hovered.map { Set(navigator.ancestors(of: $0)) } ?? [],
                            keyboardFocus: keyboardFocus,
                            search: search,
                            options: SunburstOptions())
    }

    @Test("A resting map paints its tiles")
    func restingMap() throws {
        let image = try #require(render(chart()))
        let coverage = inkCoverage(image)
        // A treemap fills its bounds, less the inset margin.
        #expect(coverage > 0.7, "the map painted almost nothing: \(coverage)")
        #expect(coverage <= 1.0)
    }

    @Test("Hover and keyboard focus both draw, and draw differently")
    func emphasisDraws() throws {
        let plain = try #require(render(chart()))
        let position = TreemapPosition(depth: 1, offset: 2)
        let hovered = try #require(render(chart(hovered: position)))
        let focused = try #require(render(chart(keyboardFocus: position)))
        #expect(!identical(plain, hovered), "hover changed nothing on screen")
        #expect(!identical(plain, focused), "keyboard focus changed nothing on screen")
        #expect(!identical(hovered, focused), "hover and keyboard focus must not look the same")
    }

    @Test("A search dims rather than hides")
    func searchDraws() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [4, 3, 3]))
        let result = SunburstSearch(query: "library").result(in: index)
        #expect(result.isDimming, "the fixture has no matches to dim against")
        let plain = try #require(render(chart()))
        let searched = try #require(render(chart(search: result)))
        #expect(!identical(plain, searched))
        // Still a full map: nothing was removed, only weakened.
        #expect(inkCoverage(searched) > 0.7)
    }

    @Test("Dark mode paints too, and not the same as light")
    func darkMode() throws {
        let light = try #require(render(chart(scheme: .light)))
        let dark = try #require(render(chart(scheme: .dark)))
        #expect(inkCoverage(dark) > 0.7)
        #expect(!identical(light, dark))
    }

    @Test("A view too small for the map draws nothing rather than crashing")
    func degenerateSize() {
        let index = TreemapIndex(TreemapFixture.layout(levels: [2]))
        let palette = SunburstPalette()
        let tiny = TreemapChart(index: index,
                                metrics: TreemapMetrics(size: CGSize(width: 8, height: 8)),
                                table: SunburstColorTable(palette: palette, scheme: .light),
                                shading: TreemapShadingTable(palette: palette, scheme: .light))
        _ = render(tiny, width: 8, height: 8)
    }

    /// The gradient is the difference between tiles and coloured rectangles, and
    /// it is exactly the kind of change that can be written, believed and never
    /// reach the screen — a shading built from two identical colours looks like
    /// working code. So this reads the pixels of one tile filling the whole map
    /// and checks the lit corner is genuinely lighter than the shaded one.
    ///
    /// The sampler calibrates itself against a gradient whose direction is known
    /// from its own declaration, rather than assuming which way up a `CGImage`
    /// read back through `CGContext` lands. That assumption is exactly the kind
    /// that makes a test pass for the wrong reason.
    @Test("A tile is lit at the top-left and shaded at the bottom-right")
    func tilesAreShaded() throws {
        let reference = try #require(render(
            LinearGradient(colors: [.white, .black], startPoint: .topLeading,
                           endPoint: .bottomTrailing)))
        guard let litCornerIsBrighter = topLeftIsBrighter(reference) else {
            Issue.record("the calibration gradient read as flat, so the sampler is broken")
            return
        }

        let index = TreemapIndex(TreemapFixture.grid(columns: 1, rows: 1))
        let palette = SunburstPalette()
        for scheme in [ColorScheme.light, .dark] {
            let chart = TreemapChart(
                index: index,
                metrics: TreemapMetrics(size: CGSize(width: 640, height: 420)),
                table: SunburstColorTable(palette: palette, scheme: scheme),
                shading: TreemapShadingTable(palette: palette, scheme: scheme))
            let image = try #require(render(chart))
            let near = brightness(image, at: 0.10) ?? -1
            let far = brightness(image, at: 0.90) ?? -1
            #expect(topLeftIsBrighter(image) == litCornerIsBrighter,
                    "flat, or lit from the wrong corner, in \(scheme): \(near) then \(far)")
        }
    }

    /// Under the threshold a tile gets the flat reference colour. Stated as a
    /// test because it is the reason the existing contrast and legend tests are
    /// still true of the small tiles: they measure `swatch`, and a small tile is
    /// still exactly `swatch`.
    @Test("Small tiles and aggregates stay flat")
    func flatCases() {
        let big = CGRect(x: 0, y: 0, width: 40, height: 40)
        let thin = CGRect(x: 0, y: 0, width: 40, height: 4)
        #expect(TreemapShadingTable.usesGradient(rect: big, kind: .real))
        #expect(!TreemapShadingTable.usesGradient(rect: thin, kind: .real))
        #expect(!TreemapShadingTable.usesGradient(rect: big, kind: .aggregated(count: 9)))
        #expect(TreemapShadingTable.usesGradient(rect: big, kind: .stillScanning))
    }

    @Test("A lifted tile draws differently from an unlifted one")
    func hoverLifts() throws {
        let position = TreemapPosition(depth: 0, offset: 1)
        let down = try #require(render(chart(hovered: position, hoverLift: 0)))
        let up = try #require(render(chart(hovered: position, hoverLift: 1)))
        #expect(!identical(down, up), "the lift changed nothing on screen")
    }

    /// Mid-zoom the map is drawing two layouts at once. The pure tests fix the
    /// arithmetic; this one fixes that the arithmetic reaches a `Canvas`
    /// without a divide by zero or a rectangle built the wrong way round.
    @Test("A map mid-zoom paints both layouts", arguments: [0.0, 0.25, 0.5, 0.75])
    func midZoomDraws(progress: Double) throws {
        let departing = TreemapIndex(TreemapFixture.layout(levels: [3, 3], generation: 1))
        let image = try #require(render(chart(departing: departing, progress: progress)))
        #expect(inkCoverage(image) > 0.5, "the transition painted almost nothing")
    }

    private func identical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        guard let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data? else {
            return false
        }
        return da == db
    }
}

/// What the placement pass does with the *real* font rather than a model of it.
///
/// The pure tests fix the geometry; this one fixes the assumption underneath
/// it — that a 10pt system line really does fit the nominal height the budgets
/// are computed for. If Apple ever changes those metrics, this fails rather
/// than the chart silently going label-less.
@MainActor
final class LabelProbe {
    var placed: [PlacedLabel] = []
    var measuredLineHeight: Double = 0
    var cacheMisses = 0
    var cacheHits = 0
}

struct LabelProbeView: View {
    let index: SunburstIndex
    let metrics: SunburstMetrics
    let probe: LabelProbe

    var body: some View {
        Canvas { context, _ in
            let cache = LabelTextCache.shared
            let font = SunburstLabels.font
            let snapshot = context
            probe.measuredLineHeight = cache.size(of: "Library", font: font, in: snapshot).height
            let slots = SunburstLabels.slots(for: index, metrics: metrics)
            probe.placed = LabelPlacement.place(slots: slots) { text in
                cache.size(of: text, font: font, in: snapshot)
            }
            probe.cacheHits = cache.hits
            probe.cacheMisses = cache.misses
        }
    }
}

@Suite("Real text metrics")
@MainActor
struct RealTextMetricTests {

    @Test("The real 10pt line fits the height the budgets assume")
    func lineHeightAssumption() throws {
        let probe = LabelProbe()
        LabelTextCache.shared.removeAll()
        var generator = SplitMix64(seed: 3_350_000)
        var levels: [[Double]] = []
        for count in [9, 11, 13] {
            var weights: [Double] = []
            for _ in 0..<count { weights.append(Double.random(in: 0.15...4, using: &generator)) }
            levels.append(weights)
        }
        let index = SunburstIndex(Fixture.layout(levels: levels,
                                                 nameForRing: { _, _, slot in
                                                     FixtureNames.name(Int(slot))
                                                 }))
        let metrics = SunburstMetrics(size: CGSize(width: 900, height: 900), ringCount: index.ringCount)
        let view = LabelProbeView(index: index, metrics: metrics, probe: probe)
        _ = ImageRenderer(content: view.frame(width: 900, height: 900)).cgImage

        #expect(probe.measuredLineHeight > 0, "nothing was measured at all")
        let assumed = SunburstLabels.nominalLineHeight
        #expect(probe.measuredLineHeight <= assumed,
                "a 10pt line measures \(probe.measuredLineHeight)pt, above the \(assumed)pt assumed")
        #expect(!probe.placed.isEmpty, "the pass placed no labels with real metrics")
        #expect(overlappingPairs(probe.placed.map(\.box)) == 0)
    }

    @Test("Measured sizes are cached across the strings on one frame")
    func measurementIsCached() {
        let cache = LabelTextCache.shared
        cache.removeAll()
        let probe = LabelProbe()
        let index = SunburstIndex(Fixture.layout(levels: [[3, 2, 1], [2, 1]],
                                                 nameForRing: { _, _, _ in "Library" }))
        let metrics = SunburstMetrics(size: CGSize(width: 700, height: 700), ringCount: index.ringCount)
        let view = LabelProbeView(index: index, metrics: metrics, probe: probe)
        _ = ImageRenderer(content: view.frame(width: 700, height: 700)).cgImage
        // Every wedge carries the same name, so after the first measurement the
        // rest are lookups. A pass that re-measured per wedge would not hold
        // 120 Hz on a dense scan.
        #expect(probe.cacheHits > probe.cacheMisses,
                "\(probe.cacheHits) hits against \(probe.cacheMisses) misses")
    }
}
