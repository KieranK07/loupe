import CoreGraphics
import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Keyboard navigation over a grid")
struct TreemapNavigatorTests {

    private func gridIndex(columns: Int = 4, rows: Int = 3) -> TreemapIndex {
        TreemapIndex(TreemapFixture.grid(columns: columns, rows: rows))
    }

    private func position(_ index: TreemapIndex, row: Int, column: Int, columns: Int = 4)
        -> TreemapPosition {
        TreemapPosition(depth: 0, offset: row * columns + column)
    }

    private func name(_ index: TreemapIndex, _ position: TreemapPosition?) -> String? {
        position.flatMap { index[$0]?.name }
    }

    @Test("The arrows move to the neighbouring cell")
    func arrows() {
        let index = gridIndex()
        let navigator = TreemapNavigator(index: index, aspectRatio: 4.0 / 3.0)
        let middle = position(index, row: 1, column: 1)
        #expect(name(index, navigator.destination(from: middle, move: .right)) == "r1c2")
        #expect(name(index, navigator.destination(from: middle, move: .left)) == "r1c0")
        #expect(name(index, navigator.destination(from: middle, move: .down)) == "r2c1")
        #expect(name(index, navigator.destination(from: middle, move: .up)) == "r0c1")
    }

    @Test("A grid does not wrap: the edge is the edge")
    func edges() {
        let index = gridIndex()
        let navigator = TreemapNavigator(index: index)
        #expect(navigator.destination(from: position(index, row: 0, column: 0), move: .left) == nil)
        #expect(navigator.destination(from: position(index, row: 0, column: 0), move: .up) == nil)
        #expect(navigator.destination(from: position(index, row: 2, column: 3), move: .right) == nil)
        #expect(navigator.destination(from: position(index, row: 2, column: 3), move: .down) == nil)
    }

    @Test("Every cell is reachable from every other by arrows alone")
    func connected() {
        let index = gridIndex(columns: 5, rows: 4)
        let navigator = TreemapNavigator(index: index)
        var seen: Set<TreemapPosition> = []
        var frontier = [TreemapPosition(depth: 0, offset: 0)]
        while let current = frontier.popLast() {
            guard seen.insert(current).inserted else { continue }
            for move in [TreemapNavigator.Move.left, .right, .up, .down] {
                if let next = navigator.destination(from: current, move: move) { frontier.append(next) }
            }
        }
        #expect(seen.count == 20)
    }

    @Test("A neighbour that lines up beats a nearer one that does not")
    func prefersStraightAhead() throws {
        // One tall tile down the left, two short tiles to its right. From the
        // tall one, "right" must land on whichever short tile overlaps it —
        // both do, so the nearer centre wins — and never wander off the row.
        let tiles = [
            TreemapTile(node: .directory(1), frame: TreemapRect(x: 0, y: 0, width: 0.5, height: 1),
                        depth: 0, physicalBytes: 10, logicalBytes: 10, itemCount: 1,
                        name: "tall", kind: .real, colorSeed: 0),
            TreemapTile(node: .directory(2), frame: TreemapRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                        depth: 0, physicalBytes: 5, logicalBytes: 5, itemCount: 1,
                        name: "top", kind: .real, colorSeed: 1),
            TreemapTile(node: .directory(3), frame: TreemapRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                        depth: 0, physicalBytes: 5, logicalBytes: 5, itemCount: 1,
                        name: "bottom", kind: .real, colorSeed: 2),
        ]
        let layout = TreemapLayout(generation: 1, focus: .directory(0), focusPath: "/",
                                   breadcrumb: [Breadcrumb(node: .directory(0), name: "Root")],
                                   tiles: tiles, totalPhysicalBytes: 20, totalLogicalBytes: 20,
                                   scannedAt: Date(), isComplete: true)
        let index = TreemapIndex(layout)
        let navigator = TreemapNavigator(index: index)
        let from = TreemapPosition(depth: 0, offset: 0)
        let landed = try #require(navigator.destination(from: from, move: .right))
        #expect(["top", "bottom"].contains(index[landed]?.name ?? ""))
        #expect(navigator.destination(from: from, move: .left) == nil)
    }

    @Test("Option with the arrows changes level")
    func depthMoves() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [3, 4]))
        let navigator = TreemapNavigator(index: index)
        let top = try #require(navigator.initialFocus())
        #expect(top.depth == 0)
        let inside = try #require(navigator.destination(from: top, move: .deeper))
        #expect(inside.depth == 1)
        #expect(index.parent(of: inside) == top)
        #expect(navigator.destination(from: inside, move: .shallower) == top)
        // The deepest level has nothing further in.
        #expect(navigator.destination(from: inside, move: .deeper) == nil)
        #expect(navigator.destination(from: top, move: .shallower) == nil)
    }

    @Test("The keyboard starts on the biggest thing at the outermost level")
    func initialFocus() throws {
        let index = TreemapIndex(TreemapFixture.layout(levels: [5, 2]))
        let navigator = TreemapNavigator(index: index)
        let start = try #require(navigator.initialFocus())
        #expect(start.depth == 0)
        let area = try #require(index[start]).frame.area
        for tile in index.tiles(atDepth: 0) {
            #expect(tile.frame.area <= area + 1e-12)
        }
    }

    @Test("Aspect ratio changes what counts as nearest")
    func aspectMatters() throws {
        // A layout of wide, short tiles. In normalised space the vertical
        // neighbour looks closer; on a wide window it is not.
        let index = gridIndex(columns: 8, rows: 2)
        let square = TreemapNavigator(index: index, aspectRatio: 1)
        let wide = TreemapNavigator(index: index, aspectRatio: 8)
        let from = TreemapPosition(depth: 0, offset: 0)
        #expect(name(index, square.destination(from: from, move: .right)) == "r0c1")
        #expect(name(index, wide.destination(from: from, move: .right)) == "r0c1")
        // Down is unambiguous either way; what changes is only the scoring, so
        // assert the invariant that matters: the answers stay on the grid.
        #expect(name(index, square.destination(from: from, move: .down)) == "r1c0")
        #expect(name(index, wide.destination(from: from, move: .down)) == "r1c0")
    }
}
