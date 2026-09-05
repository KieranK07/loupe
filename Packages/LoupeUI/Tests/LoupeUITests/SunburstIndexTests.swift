import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

@Suite("Index, metrics and the drawing convention")
struct SunburstIndexTests {
    @Test("Wedges arriving out of order are put in ring-then-angle order")
    func sortsUnorderedInput() {
        let ordered = Fixture.layout(levels: [[1, 2, 3], [1, 1]])
        let shuffled = SunburstLayout(
            generation: ordered.generation, focus: ordered.focus, focusPath: ordered.focusPath,
            breadcrumb: ordered.breadcrumb, wedges: ordered.wedges.reversed(),
            totalPhysicalBytes: ordered.totalPhysicalBytes,
            totalLogicalBytes: ordered.totalLogicalBytes,
            scannedAt: ordered.scannedAt, isComplete: ordered.isComplete)

        let a = SunburstIndex(ordered)
        let b = SunburstIndex(shuffled)
        #expect(a.wedges == b.wedges)
        #expect(a.ringRanges == b.ringRanges)
    }

    @Test("Ring ranges cover every wedge exactly once")
    func ringRangesPartition() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 2], [3, 1], [1, 1]]))
        #expect(index.ringCount == 3)
        var covered = 0
        for ring in 0..<index.ringCount {
            let slice = index.wedges(inRing: ring)
            #expect(slice.allSatisfy { Int($0.ring) == ring })
            covered += slice.count
        }
        #expect(covered == index.wedges.count)
        #expect(index.wedges(inRing: 99).isEmpty)
    }

    @Test("A ring the projector skipped still keeps the later rings at their own index")
    func skippedRingKeepsIndexing() {
        // Ring 1 is absent entirely; ring 2 must not slide into its slot, or
        // every parent lookup from ring 2 would target the wrong ring.
        let wedges = [
            Wedge(node: .directory(1), startAngle: 0, endAngle: 3, ring: 0,
                  physicalBytes: 1, logicalBytes: 1, itemCount: 1, name: "a",
                  kind: .real, colorSeed: 0),
            Wedge(node: .directory(2), startAngle: 0, endAngle: 3, ring: 2,
                  physicalBytes: 1, logicalBytes: 1, itemCount: 1, name: "b",
                  kind: .real, colorSeed: 0),
        ]
        let index = SunburstIndex(SunburstLayout(
            generation: 1, focus: .directory(0), focusPath: "", breadcrumb: [],
            wedges: wedges, totalPhysicalBytes: 2, totalLogicalBytes: 2,
            scannedAt: Date(), isComplete: true))
        #expect(index.ringCount == 3)
        #expect(index.count(inRing: 1) == 0)
        #expect(index[SunburstPosition(ring: 2, offset: 0)]?.name == "b")
    }

    @Test("A node can be found again after the layout regenerates")
    func nodeLookupSurvivesRegeneration() {
        let first = SunburstIndex(Fixture.layout(levels: [[1, 2, 3]], generation: 1))
        let second = SunburstIndex(Fixture.layout(levels: [[3, 2, 1]], generation: 2))
        guard let wedge = first.wedges.last else { Issue.record("no wedges"); return }
        let moved = second.position(ofNode: wedge.node)
        #expect(moved != nil)
        #expect(second[moved!]?.node == wedge.node)
        #expect(second.position(ofNode: .directory(99_999)) == nil)
    }

    @Test("The focus name comes from the breadcrumb, then the path, then a fallback")
    func focusNaming() {
        let named = SunburstIndex(Fixture.layout(levels: [[1]]))
        #expect(named.focusName == "Users")

        let fromPath = SunburstIndex(Fixture.layout(levels: [[1]], breadcrumb: []))
        #expect(fromPath.focusName == "Users")

        #expect(SunburstIndex(.empty).focusName == "All items")
        #expect(SunburstDescription.focusTitle(SunburstIndex(.empty)) == "All items")
    }

    // MARK: - Metrics

    @Test("Rings are capped in thickness, and the remainder goes to the centre disc")
    func metricsFitting() {
        let wide = SunburstMetrics(size: CGSize(width: 900, height: 900), ringCount: 1)
        #expect(wide.ringThickness <= 68.001)
        #expect(wide.centreRadius > wide.ringThickness)

        let deep = SunburstMetrics(size: CGSize(width: 600, height: 600), ringCount: 8)
        #expect(deep.outerRadius <= 300 - 16 + 0.001)
        #expect(deep.centreRadius >= (300 - 16) * 0.259)
        #expect(deep.ringThickness > 0)

        // A view too small to draw in must not produce negative geometry.
        let tiny = SunburstMetrics(size: CGSize(width: 10, height: 4), ringCount: 4)
        #expect(tiny.centreRadius >= 0)
        #expect(tiny.ringThickness >= 0)
        #expect(SunburstMetrics(size: .zero, ringCount: 0).ring(atRadius: 0) == nil)
    }

    /// The one piece of drawing that is worth pinning in a test: which way round
    /// the arcs go. Contract angles are clockwise from 12 o'clock, and Canvas's
    /// y axis points down. Get the sign wrong and the whole chart mirrors —
    /// which looks plausible until hit testing disagrees with every pixel.
    @Test("A quarter-turn sector from 12 o'clock lands in the top-right quadrant")
    func sectorPathOrientation() {
        let path = sunburstSectorPath(center: .zero, innerRadius: 0, outerRadius: 100,
                                      start: 0, end: .pi / 2)
        let box = path.boundingRect
        #expect(abs(box.minX - 0) < 0.5)
        #expect(abs(box.maxX - 100) < 0.5)
        #expect(abs(box.minY + 100) < 0.5)
        #expect(abs(box.maxY - 0) < 0.5)
    }

    @Test("A sector owning the whole turn is drawn as an annulus")
    func fullTurnSector() {
        let path = sunburstSectorPath(center: .zero, innerRadius: 40, outerRadius: 100,
                                      start: 0, end: SunburstAngle.fullTurn)
        let box = path.boundingRect
        #expect(abs(box.width - 200) < 0.5)
        #expect(abs(box.height - 200) < 0.5)
        #expect(!path.isEmpty)
    }

    @Test("Degenerate sectors produce no path rather than a stray mark")
    func degenerateSectors() {
        #expect(sunburstSectorPath(center: .zero, innerRadius: 50, outerRadius: 50,
                                   start: 0, end: 1).isEmpty)
        #expect(sunburstSectorPath(center: .zero, innerRadius: 10, outerRadius: 50,
                                   start: 1, end: 1).isEmpty)
    }

    @Test("A wedge reports the size basis it is currently drawn against")
    func wedgeBasisAccessor() {
        let wedge = Wedge(node: .file(3), startAngle: 0, endAngle: 1, ring: 0,
                          physicalBytes: 100, logicalBytes: 900, itemCount: 1,
                          name: "sparse.dmg", kind: .real, colorSeed: 0)
        #expect(wedge.bytes(.physical) == 100)
        #expect(wedge.bytes(.logical) == 900)
        #expect(!wedge.isAggregated)
        #expect(wedge.aggregatedCount == nil)
        #expect(!wedge.isStillScanning)

        let merged = Wedge(node: .file(4), startAngle: 0, endAngle: 1, ring: 0,
                           physicalBytes: 1, logicalBytes: 1, itemCount: 9,
                           name: "9 smaller items", kind: .aggregated(count: 9), colorSeed: 0)
        #expect(merged.isAggregated)
        #expect(merged.aggregatedCount == 9)
    }
}
