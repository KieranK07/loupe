import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

/// The drawing itself cannot be asserted meaningfully, but it can be *run*.
/// These render the pack offscreen and check the pixels — enough to catch a
/// gradient built the wrong way round, a divide by zero in the metrics, or a
/// crash in the hatching, none of which the pure tests can see.
@Suite("The bubbles actually draw")
@MainActor
struct BubbleRenderSmokeTests {
    private static let width: CGFloat = 640
    private static let height: CGFloat = 420

    private func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: Self.width, height: Self.height))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Mean brightness of a small block around a point, in whatever orientation
    /// `CGContext` hands the image back. Which way up that is does not matter and
    /// is deliberately not assumed — see `litFromTheUpperLeft`.
    private func brightness(_ image: CGImage, at point: CGPoint) -> Double? {
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

        let cx = Int(point.x), cy = Int(point.y)
        var total = 0.0, samples = 0
        for row in (cy - 3)...(cy + 3) where row >= 0 && row < height {
            for column in (cx - 3)...(cx + 3) where column >= 0 && column < width {
                let i = (row * width + column) * 4
                total += (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 765
                samples += 1
            }
        }
        return samples > 0 ? total / Double(samples) : nil
    }

    /// One ball filling the view, so a sample lands on its fill and nothing else.
    private func loneBall(scheme: ColorScheme = .light,
                          reduceTransparency: Bool = false) -> BubbleChart {
        let ball = BubbleFixture.circle(slot: 1, x: 0.5, y: 0.5, r: 0.45, depth: 0,
                                        seed: 0, hasChildren: false, name: "Library")
        return chart(BubbleFixture.layout([ball]), scheme: scheme,
                     reduceTransparency: reduceTransparency)
    }

    private func chart(_ layout: BubbleLayout,
                       hovered: BubblePosition? = nil,
                       keyboardFocus: BubblePosition? = nil,
                       search: SunburstSearchResult = .inactive,
                       scheme: ColorScheme = .light,
                       departing: BubbleIndex? = nil,
                       progress: Double = 1,
                       reduceTransparency: Bool = false) -> BubbleChart {
        let index = BubbleIndex(layout)
        let hoverChain = hovered.map { Set(BubbleNavigator(index: index).ancestors(of: $0)) } ?? []
        return BubbleChart(progress: progress,
                           current: index,
                           departing: departing,
                           metrics: BubbleMetrics(size: CGSize(width: Self.width,
                                                               height: Self.height)),
                           table: BubbleShadingTable(palette: SunburstPalette(), scheme: scheme),
                           hovered: hovered,
                           hoverChain: hoverChain,
                           keyboardFocus: keyboardFocus,
                           search: search,
                           options: SunburstOptions(),
                           reduceTransparency: reduceTransparency)
    }

    private func busyChart(hovered: BubblePosition? = nil,
                           keyboardFocus: BubblePosition? = nil,
                           search: SunburstSearchResult = .inactive,
                           scheme: ColorScheme = .light,
                           departing: BubbleIndex? = nil,
                           progress: Double = 1,
                           reduceTransparency: Bool = false) -> BubbleChart {
        let layout = BubbleFixture.nested { depth, offset in
            if depth == 2, offset == 0 { .aggregated(count: 318) }
            else if depth == 1, offset == 1 { .stillScanning }
            else { .real }
        }
        return chart(layout, hovered: hovered, keyboardFocus: keyboardFocus, search: search,
                     scheme: scheme, departing: departing, progress: progress,
                     reduceTransparency: reduceTransparency)
    }

    // MARK: - It draws

    @Test("A pack of bubbles puts ink on the screen")
    func drawsSomething() throws {
        let image = try #require(render(busyChart()))
        let coverage = RenderProbe.inkCoverage(image)
        // Circles do not tile, so a full container is nowhere near full ink —
        // four balls of radius 0.18 in a 420-point square is about a fifth of it,
        // before their children. Well above blank, well below a treemap.
        #expect(coverage > 0.10, "the chart came out nearly blank: \(coverage)")
        #expect(coverage < 0.75, "circles that tile are not circles: \(coverage)")
    }

    @Test("Hover, keyboard focus, dark mode, search and Reduce Transparency all render")
    func everyStateRenders() throws {
        let hovered = BubblePosition(depth: 0, offset: 1)
        let focused = BubblePosition(depth: 1, offset: 3)
        let index = BubbleIndex(BubbleFixture.nested())
        let hit = try #require(index.circles.last?.id)
        let variants: [(String, BubbleChart)] = [
            ("hover", busyChart(hovered: hovered)),
            ("keyboard", busyChart(keyboardFocus: focused)),
            ("both", busyChart(hovered: hovered, keyboardFocus: focused)),
            ("dark", busyChart(scheme: .dark)),
            ("search", busyChart(search: SunburstSearchResult(query: "x", matched: [hit],
                                                              onPath: []))),
            ("reduce transparency", busyChart(reduceTransparency: true)),
        ]
        for (name, chart) in variants {
            let image = try #require(render(chart), "\(name) rendered nothing")
            #expect(RenderProbe.inkCoverage(image) > 0.05, "\(name) came out blank")
        }
    }

    @Test("A degenerate view and an empty layout draw nothing and crash nothing")
    func degenerateCasesAreSafe() throws {
        let empty = BubbleChart(progress: 1, current: BubbleIndex(.empty), departing: nil,
                                metrics: BubbleMetrics(size: CGSize(width: Self.width,
                                                                    height: Self.height)),
                                table: BubbleShadingTable(palette: SunburstPalette(),
                                                          scheme: .light),
                                hovered: nil, hoverChain: [], keyboardFocus: nil,
                                search: .inactive, options: SunburstOptions(),
                                reduceTransparency: false)
        let image = try #require(render(empty))
        #expect(RenderProbe.inkCoverage(image) < 0.01)

        let squashed = BubbleChart(progress: 1, current: BubbleIndex(BubbleFixture.nested()),
                                   departing: nil, metrics: BubbleMetrics(size: .zero),
                                   table: BubbleShadingTable(palette: SunburstPalette(),
                                                             scheme: .light),
                                   hovered: nil, hoverChain: [], keyboardFocus: nil,
                                   search: .inactive, options: SunburstOptions(),
                                   reduceTransparency: false)
        #expect(render(squashed) != nil)
    }

    // MARK: - They are balls, not discs

    /// The light source is fixed in the *view*: every bubble is lit from the
    /// same upper-left, which is what makes a screen of them read as a tray of
    /// spheres rather than as a hundred objects each with its own sun.
    ///
    /// Which corner of the returned bitmap is "upper left" is not assumed. A
    /// reference gradient with a known direction is rendered through the same
    /// path and the ball is compared against it.
    @Test("A bubble is lit from the upper left, in both appearances")
    func litFromTheUpperLeft() throws {
        let centre = CGPoint(x: Self.width / 2, y: Self.height / 2)
        let step = Self.height * 0.45 * 0.4
        let near = CGPoint(x: centre.x - step, y: centre.y - step)
        let far = CGPoint(x: centre.x + step, y: centre.y + step)

        let reference = try #require(render(
            LinearGradient(colors: [.white, .black], startPoint: .topLeading,
                           endPoint: .bottomTrailing)))
        let referenceNear = try #require(brightness(reference, at: near))
        let referenceFar = try #require(brightness(reference, at: far))
        let litIsBrighter = referenceNear > referenceFar

        for scheme in [ColorScheme.light, .dark] {
            let image = try #require(render(loneBall(scheme: scheme)))
            let lit = try #require(brightness(image, at: near))
            let shade = try #require(brightness(image, at: far))
            #expect(abs(lit - shade) > 0.02,
                    "flat rather than spherical in \(scheme): \(lit) then \(shade)")
            #expect((lit > shade) == litIsBrighter,
                    "lit from the wrong corner in \(scheme): \(lit) then \(shade)")
        }
    }

    /// Reduce Transparency turns off the specular bloom, which works by being
    /// see-through. What it must not turn off is the ability to tell one ball
    /// from the next, so the rim gets heavier instead.
    @Test("Reduce Transparency drops the bloom and keeps the shape")
    func reduceTransparencyKeepsTheEdges() throws {
        let plain = try #require(render(loneBall()))
        let reduced = try #require(render(loneBall(reduceTransparency: true)))
        let centre = CGPoint(x: Self.width / 2, y: Self.height / 2)
        let step = Self.height * 0.45 * 0.4
        let lit = CGPoint(x: centre.x - step, y: centre.y - step)
        // The glint sits near the light point, so removing it changes that
        // sample and only that sample much.
        let withBloom = try #require(brightness(plain, at: lit))
        let without = try #require(brightness(reduced, at: lit))
        #expect(abs(withBloom - without) > 0.01, "the specular highlight is not there at all")
        // The ball is still a ball: still shaded, still drawn.
        #expect(RenderProbe.inkCoverage(reduced) > 0.2)
    }

    /// A folder that loses its contents the moment you point at it is worse
    /// than no hover state at all: the whole reason to point at a folder is to
    /// ask what is in it.
    @Test("Hovering a folder lifts it and keeps its contents visible")
    func hoverLiftsTheWholeSubtree() throws {
        let hovered = BubblePosition(depth: 0, offset: 1)
        let plain = try #require(render(busyChart()))
        let lifted = try #require(render(busyChart(hovered: hovered)))
        // The lift makes the ball bigger, so there is strictly more ink.
        #expect(RenderProbe.inkCoverage(lifted) > RenderProbe.inkCoverage(plain))

        // And a child of the lifted ball is still drawn: sample where it lands
        // after being scaled about its parent's centre and check it is not the
        // parent's own colour.
        let index = BubbleIndex(BubbleFixture.nested())
        let parentIndex = try #require(index.circleIndex(of: hovered))
        let parent = index.circles[parentIndex]
        let child = index.circles[try #require(index.subtree(from: parentIndex).first)]
        let metrics = BubbleMetrics(size: CGSize(width: Self.width, height: Self.height))
        let factor = 1.05
        let point = metrics.point(x: parent.centerX + (child.centerX - parent.centerX) * factor,
                                  y: parent.centerY + (child.centerY - parent.centerY) * factor)
        let onChild = try #require(brightness(lifted, at: point))
        let onParent = try #require(brightness(lifted, at: metrics.point(
            x: parent.centerX + parent.radius * 0.8, y: parent.centerY)))
        #expect(abs(onChild - onParent) > 0.01,
                "the lifted folder swallowed its own contents: \(onChild) then \(onParent)")
    }

    @Test("A ball too small for a gradient is drawn flat rather than not at all")
    func tinyBallsStillDraw() throws {
        var circles: [BubbleCircle] = []
        for i in 0..<40 {
            let angle = Double(i) * 2 * .pi / 40
            circles.append(BubbleFixture.circle(slot: UInt32(200 + i),
                                                x: 0.5 + cos(angle) * 0.35,
                                                y: 0.5 + sin(angle) * 0.35,
                                                r: 0.006, depth: 0, seed: UInt16(i % 10)))
        }
        let image = try #require(render(chart(BubbleFixture.layout(circles))))
        #expect(RenderProbe.inkCoverage(image) > 0.001, "the smallest bubbles vanished")
    }

    // MARK: - The zoom

    @Test("Mid-zoom draws both layouts, and the ends are the plain layouts")
    func zoomRenders() throws {
        let layout = BubbleFixture.nested()
        let focus = try #require(layout.circles.first { $0.depth == 0 })
        let old = BubbleIndex(layout)
        let new = BubbleIndex(BubbleFixture.zoomed(layout, into: focus))

        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let image = try #require(render(chart(BubbleFixture.zoomed(layout, into: focus),
                                                  departing: old, progress: progress)))
            #expect(RenderProbe.inkCoverage(image) > 0.02,
                    "the chart went blank at progress \(progress)")
        }

        // At the very start the new layout is still folded into the circle that
        // was clicked, so the picture is the old chart — which is the whole
        // point of the transition and the thing a cross-fade cannot do.
        let atStart = try #require(render(chart(BubbleFixture.zoomed(layout, into: focus),
                                                departing: old, progress: 0)))
        let oldOnly = try #require(render(chart(layout)))
        #expect(abs(RenderProbe.inkCoverage(atStart) - RenderProbe.inkCoverage(oldOnly)) < 0.03)
        #expect(new.circles.count > 0)
    }
}
