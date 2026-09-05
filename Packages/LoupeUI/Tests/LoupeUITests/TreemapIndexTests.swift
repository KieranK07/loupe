import CoreGraphics
import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("The treemap index: order, nesting and hit testing")
struct TreemapIndexTests {

    @Test("Depth ranges partition the tiles in the order the contract delivers them")
    func depthRanges() {
        let index = TreemapIndex(TreemapFixture.layout(levels: [4, 3, 2]))
        #expect(index.depthCount == 3)
        var covered = 0
        for depth in 0..<index.depthCount {
            let range = index.depthRanges[depth]
            covered += range.count
            for i in range { #expect(Int(index.tiles[i].depth) == depth) }
        }
        #expect(covered == index.tiles.count)
        #expect(index.count(atDepth: 0) == 4)
        #expect(index.count(atDepth: 1) == 12)
        #expect(index.count(atDepth: 2) == 24)
    }

    @Test("A position round-trips through its node and back")
    func positionRoundTrip() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [3, 3]))
        for i in index.tiles.indices {
            let position = try #require(index.position(at: i))
            #expect(index.tileIndex(of: position) == i)
            #expect(index.position(ofNode: index.tiles[i].node) == position)
        }
    }

    @Test("Every tile's parent is the tile one level out that contains it")
    func parents() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [4, 3, 3]))
        for i in index.tiles.indices {
            let tile = index.tiles[i]
            if tile.depth == 0 {
                #expect(index.parentIndex(of: i) == nil)
                continue
            }
            let parent = try #require(index.parentIndex(of: i), "\(tile.name) lost its parent")
            #expect(index.tiles[parent].depth == tile.depth - 1)
            let cx = tile.frame.x + tile.frame.width / 2
            let cy = tile.frame.y + tile.frame.height / 2
            #expect(index.tiles[parent].frame.contains(x: cx, y: cy))
        }
    }

    @Test("Hit testing agrees with a brute-force reverse scan")
    func hitTesting() {
        let index = TreemapIndex(TreemapFixture.layout(levels: [4, 4, 3]))
        let metrics = TreemapFixture.metrics(width: 800, height: 500)
        var generator = SplitMix64(seed: 8_1_2026)
        var probes = 0
        for _ in 0..<4000 {
            let point = CGPoint(x: Double.random(in: 0...800, using: &generator),
                                y: Double.random(in: 0...500, using: &generator))
            let fast = index.hit(at: point, metrics: metrics)
            let slow = bruteForceHit(index, at: point, metrics: metrics)
            #expect(fast == slow, "at \(point)")
            if case .tile = fast { probes += 1 }
        }
        #expect(probes > 3000, "the fixture barely covered the view")
    }

    @Test("Outside the map is background, and the margin is the way back out")
    func outside() {
        let index = TreemapIndex(TreemapFixture.layout(levels: [2, 2]))
        let metrics = TreemapMetrics(size: CGSize(width: 400, height: 400), inset: 12)
        #expect(index.hit(at: CGPoint(x: 4, y: 4), metrics: metrics) == .none)
        if case .tile = index.hit(at: CGPoint(x: 200, y: 200), metrics: metrics) {} else {
            Issue.record("the middle of the map should be a tile")
        }
    }

    @Test("A tile its children cover completely is not exposed; a leaf is")
    func exposure() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [3, 3]))
        for i in index.tiles.indices {
            let fraction = index.exposure[i].visibleFraction
            if index.tiles[i].depth == 0 {
                #expect(fraction < 0.05,
                        "\(index.tiles[i].name) is covered by its children but reports \(fraction)")
            } else {
                #expect(fraction > 0.9,
                        "\(index.tiles[i].name) is the deepest thing there but reports \(fraction)")
            }
        }
    }

    @Test("A single level is entirely exposed")
    func singleLevelExposure() {
        let index = TreemapIndex(TreemapFixture.grid(columns: 4, rows: 3))
        for i in index.tiles.indices {
            #expect(index.exposure[i].visibleFraction > 0.9)
        }
    }

    @Test("An empty layout is inert rather than a crash")
    func empty() {
        let index = TreemapIndex(.empty)
        #expect(index.isEmpty)
        #expect(index.depthCount == 0)
        // Inside the bounds but on no tile is the zoom-out target; outside is nothing.
        #expect(index.hit(at: CGPoint(x: 10, y: 10), metrics: TreemapFixture.metrics()) == .background)
        #expect(index.hit(at: CGPoint(x: -5, y: -5), metrics: TreemapFixture.metrics()) == .none)
        #expect(TreemapNavigator(index: index).initialFocus() == nil)
    }

    @Test("A view too small for the map answers rather than dividing by zero")
    func degenerate() {
        let index = TreemapIndex(TreemapFixture.layout(levels: [2]))
        let metrics = TreemapMetrics(size: CGSize(width: 8, height: 8), inset: 12)
        #expect(metrics.isDegenerate)
        #expect(metrics.normalised(CGPoint(x: 4, y: 4)) == nil)
        #expect(index.hit(at: CGPoint(x: 4, y: 4), metrics: metrics) == .none)
        #expect(TreemapLabels.slots(for: index, metrics: metrics).isEmpty)
    }

    /// Reference implementation: walk backwards and take the first tile that
    /// contains the point. Deliberately as dumb as possible — its only job is to
    /// disagree with the grid if the grid is wrong.
    private func bruteForceHit(_ index: TreemapIndex, at point: CGPoint,
                               metrics: TreemapMetrics) -> TreemapHit {
        guard let normalised = metrics.normalised(point) else { return .none }
        var i = index.tiles.count - 1
        while i >= 0 {
            if index.tiles[i].frame.contains(x: normalised.x, y: normalised.y),
               let position = index.position(at: i) {
                return .tile(position)
            }
            i -= 1
        }
        return .background
    }
}
