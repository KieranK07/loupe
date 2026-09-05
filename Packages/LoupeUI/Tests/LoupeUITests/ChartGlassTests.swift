import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

@Suite("Floating chrome")
struct ChartGlassTests {

    // MARK: - The fallback

    /// The whole point of pulling the decision out of the view body: this is a
    /// question with an answer, not a thing to go and look at.
    @Test("Reduce Transparency turns glass into an opaque surface")
    func surfaceFallback() {
        #expect(ChartSurface.resolved(reduceTransparency: false) == .liquidGlass)
        #expect(ChartSurface.resolved(reduceTransparency: true) == .solid)
        #expect(ChartSurface.liquidGlass.usesGlass)
        #expect(!ChartSurface.solid.usesGlass)
    }

    // MARK: - Where the readout goes

    private let readout = CGSize(width: 180, height: 44)
    private let chart = CGSize(width: 800, height: 600)

    @Test("With room to spare the readout sits below and right of the pointer")
    func readoutPrefersBelowRight() {
        let point = CGPoint(x: 300, y: 200)
        let centre = ChartReadoutPlacement.centre(near: point, size: readout, in: chart)
        #expect(centre.x > point.x)
        #expect(centre.y > point.y)
        #expect(centre.x - readout.width / 2 >= point.x)
        #expect(centre.y - readout.height / 2 >= point.y)
    }

    @Test("Near an edge it flips to the other side rather than sliding along it")
    func readoutFlips() {
        let nearRight = ChartReadoutPlacement.centre(near: CGPoint(x: 780, y: 200),
                                                     size: readout, in: chart)
        #expect(nearRight.x < 780, "should have flipped to the left of the pointer")
        let nearBottom = ChartReadoutPlacement.centre(near: CGPoint(x: 300, y: 590),
                                                      size: readout, in: chart)
        #expect(nearBottom.y < 590, "should have flipped above the pointer")
    }

    /// The rule the placement exists to keep. Swept rather than sampled,
    /// because the interesting cases are all in the corners.
    @Test("The readout never leaves the chart, wherever the pointer is",
          arguments: [CGSize(width: 800, height: 600), CGSize(width: 420, height: 320),
                      CGSize(width: 260, height: 240)])
    func readoutStaysInside(bounds: CGSize) {
        var escapes = 0
        for x in stride(from: -20.0, through: bounds.width + 20, by: 7) {
            for y in stride(from: -20.0, through: bounds.height + 20, by: 7) {
                let centre = ChartReadoutPlacement.centre(near: CGPoint(x: x, y: y),
                                                          size: readout, in: bounds)
                let box = CGRect(x: centre.x - readout.width / 2,
                                 y: centre.y - readout.height / 2,
                                 width: readout.width, height: readout.height)
                if box.minX < -0.001 || box.minY < -0.001
                    || box.maxX > bounds.width + 0.001 || box.maxY > bounds.height + 0.001 {
                    escapes += 1
                }
            }
        }
        #expect(escapes == 0, "\(escapes) placements left a \(bounds) chart")
    }

    @Test("A readout wider than the chart is centred rather than jammed against a side")
    func readoutWiderThanChart() {
        let centre = ChartReadoutPlacement.centre(near: CGPoint(x: 10, y: 10),
                                                  size: CGSize(width: 400, height: 40),
                                                  in: CGSize(width: 200, height: 300))
        #expect(centre.x == 100)
    }

    // MARK: - The breadcrumb rail

    private func crumbs(_ count: Int) -> [Breadcrumb] {
        (0..<count).map { Breadcrumb(node: .directory(UInt32($0)), name: "f\($0)") }
    }

    @Test("A short trail is shown whole")
    func trailShort() {
        let entries = ChartBreadcrumbTrail.condensed(crumbs(4), limit: 5)
        #expect(entries.count == 4)
        #expect(!entries.contains { if case .elision = $0 { true } else { false } })
    }

    /// The two ends are what anyone reads: where you started and where you are.
    @Test("A long trail keeps both ends and says how many it dropped")
    func trailCondensed() throws {
        let entries = ChartBreadcrumbTrail.condensed(crumbs(12), limit: 5)
        #expect(entries.count == 6, "five folders plus one elision")
        guard case .crumb(let first) = entries[0] else { Issue.record("no root"); return }
        #expect(first.name == "f0")
        guard case .elision(let dropped) = entries[1] else { Issue.record("no elision"); return }
        #expect(dropped == 7)
        guard case .crumb(let last) = try #require(entries.last) else {
            Issue.record("no leaf"); return
        }
        #expect(last.name == "f11")
        // Nothing is invented and nothing is reordered.
        let shown = entries.compactMap { if case .crumb(let c) = $0 { c.name } else { nil } }
        #expect(shown == ["f0", "f8", "f9", "f10", "f11"])
        #expect(shown.count + dropped == 12)
    }

    @Test("A trail of one has nothing to elide and nothing to navigate")
    func trailSingle() {
        #expect(ChartBreadcrumbTrail.condensed(crumbs(1), limit: 5).count == 1)
        #expect(ChartBreadcrumbTrail.condensed([], limit: 5).isEmpty)
    }

    // MARK: - The legend

    /// A legend that disagrees with the chart is worse than no legend, so the
    /// swatch it draws has to be the swatch the renderer would use.
    @Test("Legend swatches are the colours the chart actually paints")
    func legendMatchesChart() {
        let index = SunburstIndex(Fixture.layout(levels: [[5, 3, 2, 1], [2, 1]]))
        for scheme in [ColorScheme.light, .dark] {
            let palette = SunburstPalette()
            let table = SunburstColorTable(palette: palette, scheme: scheme)
            let entries = ChartLegendEntry.entries(for: index, palette: palette,
                                                   scheme: scheme, basis: .physical)
            #expect(entries.count == 4)
            for entry in entries {
                let wedge = index.wedges.first { $0.id == entry.id }
                #expect(wedge != nil)
                if let wedge {
                    #expect(entry.swatch == table.swatch(for: wedge))
                }
            }
        }
    }

    @Test("The legend lists the innermost ring largest first")
    func legendOrder() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 4, 2, 3]]))
        let entries = ChartLegendEntry.entries(for: index, palette: SunburstPalette(),
                                               scheme: .light, basis: .physical)
        let sweeps = entries.compactMap { entry in
            index.wedges.first { $0.id == entry.id }?.sweep
        }
        #expect(sweeps == sweeps.sorted(by: >))
    }

    /// An aggregate carries the name of the largest sibling it swallowed, so a
    /// legend that printed `name` would attribute a colour to a folder that is
    /// mostly other folders.
    @Test("An aggregated entry is named for what it is")
    func legendNamesAggregates() {
        let index = SunburstIndex(Fixture.layout(
            levels: [[4, 3, 2]],
            kindForRing: { _, child in child == 2 ? .aggregated(count: 91) : .real }))
        let entries = ChartLegendEntry.entries(for: index, palette: SunburstPalette(),
                                               scheme: .light, basis: .physical)
        #expect(entries.contains { $0.name == "91 smaller items" })
    }

    @Test("The treemap builds the same legend from the same colours")
    func legendFromTreemap() {
        let index = TreemapIndex(TreemapFixture.layout(levels: [4, 2]))
        let palette = SunburstPalette()
        let table = SunburstColorTable(palette: palette, scheme: .dark)
        let entries = ChartLegendEntry.entries(for: index, palette: palette,
                                               scheme: .dark, basis: .physical)
        #expect(entries.count == 4)
        for entry in entries {
            if let tile = index.tiles.first(where: { $0.id == entry.id }) {
                #expect(entry.swatch == table.swatch(for: tile))
            }
        }
    }

    @Test("The legend caps itself rather than growing to the height of the window")
    func legendCapped() {
        let index = SunburstIndex(Fixture.layout(levels: [Array(repeating: 1.0, count: 40)]))
        let entries = ChartLegendEntry.entries(for: index, palette: SunburstPalette(),
                                               scheme: .light, basis: .physical, limit: 12)
        #expect(entries.count == 12)
    }

    // MARK: - Readout wording

    @Test("Both charts describe the same item the same way")
    func readoutWordingIsShared() {
        let real = SunburstDescription.readoutText(name: "Library", kind: .real, size: "4 GB",
                                                   share: "22 percent", container: "kieran")
        #expect(real.title == "Library")
        #expect(real.detail.contains("4 GB"))
        #expect(real.detail.contains("22 percent of kieran"))
        #expect(real.footnote == nil)

        let merged = SunburstDescription.readoutText(name: "Caches", kind: .aggregated(count: 318),
                                                     size: "12 MB", share: "1 percent",
                                                     container: "Library")
        #expect(merged.title == "318 smaller items")
        #expect(merged.footnote != nil)

        let scanning = SunburstDescription.readoutText(name: "Photos", kind: .stillScanning,
                                                       size: "9 GB", share: "40 percent",
                                                       container: "Pictures")
        #expect(scanning.title == "Photos")
        #expect(scanning.footnote?.contains("grow") == true)
    }

    /// Wording is checked against the ban list here rather than by reading it.
    @Test("Nothing the floating chrome says uses a word this app does not use")
    func vocabulary() {
        let banned = ["faster", "optimize", "optimise", "clean", "junk", "boost"]
        var strings: [String] = [
            SunburstDescription.readoutText(name: "x", kind: .real, size: "1 KB",
                                            share: "1 percent", container: "y").detail,
            SunburstDescription.readoutText(name: "x", kind: .aggregated(count: 2), size: "1 KB",
                                            share: "1 percent", container: "y").footnote ?? "",
            SunburstDescription.readoutText(name: "x", kind: .stillScanning, size: "1 KB",
                                            share: "1 percent", container: "y").footnote ?? "",
        ]
        strings += ChartViewMode.allCases.flatMap { [$0.title, $0.explanation] }
        strings += SunburstRamp.allCases.flatMap { [$0.label, $0.explanation] }
        for string in strings {
            let lowered = string.lowercased()
            for word in banned {
                #expect(!lowered.contains(word), "\"\(string)\" contains \"\(word)\"")
            }
        }
    }
}
