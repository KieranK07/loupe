import CoreGraphics
import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Bubble index and hit testing")
struct BubbleIndexTests {

    /// A fixture that quietly broke the contract would make every test that
    /// uses it meaningless, so it is checked first — the same two invariants
    /// `BubblePackTests` pins on the real packer.
    @Test("The fixture itself nests and does not overlap")
    func fixtureIsWellFormed() {
        let circles = BubbleFixture.nested().circles
        for a in circles {
            let reach = ((a.centerX - 0.5) * (a.centerX - 0.5)
                + (a.centerY - 0.5) * (a.centerY - 0.5)).squareRoot() + a.radius
            #expect(reach <= 0.5 + 1e-9, "\(a.name) escapes the focus disc")
        }
        for a in circles {
            for b in circles where b.id > a.id && b.depth == a.depth {
                let dx = b.centerX - a.centerX, dy = b.centerY - a.centerY
                #expect((dx * dx + dy * dy).squareRoot() >= a.radius + b.radius - 1e-12)
            }
        }
    }

    @Test("Depth ranges slice the array and survive a skipped depth")
    func depthRanges() {
        let index = BubbleIndex(BubbleFixture.nested())
        #expect(index.depthCount == 3)
        #expect(index.count(atDepth: 0) == 4)
        #expect(index.count(atDepth: 1) == 12)
        #expect(index.count(atDepth: 2) == 12)
        for depth in 0..<index.depthCount {
            for circle in index.circles(atDepth: depth) {
                #expect(Int(circle.depth) == depth)
            }
        }
        #expect(index.count(atDepth: 9) == 0)
    }

    @Test("An out-of-order layout is sorted rather than trusted")
    func reordersWhenItHasTo() {
        let scrambled = BubbleFixture.nested().circles.reversed()
        let index = BubbleIndex(BubbleFixture.layout(Array(scrambled)))
        var previous: UInt8 = 0
        for circle in index.circles {
            #expect(circle.depth >= previous)
            previous = circle.depth
        }
        #expect(index.count(atDepth: 0) == 4)
    }

    @Test("Positions round-trip and a node can be found again after a re-layout")
    func positionsRoundTrip() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        for i in index.circles.indices {
            let position = try #require(index.position(at: i))
            #expect(index.circleIndex(of: position) == i)
            #expect(index[position]?.id == index.circles[i].id)
            #expect(index.position(ofNode: index.circles[i].node) == position)
        }
        #expect(index.position(ofNode: .directory(9999)) == nil)
        #expect(index[BubblePosition(depth: 0, offset: 99)] == nil)
        #expect(index[BubblePosition(depth: 99, offset: 0)] == nil)
    }

    @Test("Every circle's parent is recovered geometrically")
    func parentsAreRecovered() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        for i in index.circles.indices {
            let circle = index.circles[i]
            guard circle.depth > 0 else {
                #expect(index.parentIndex(of: i) == nil, "\(circle.name) invented a parent")
                continue
            }
            let parent = index.circles[try #require(index.parentIndex(of: i))]
            #expect(parent.depth == circle.depth - 1)
            // The recovered parent must actually contain it — that is the whole
            // claim, and share-of-parent, hover ancestry and search ancestry all
            // ride on it.
            let dx = circle.centerX - parent.centerX, dy = circle.centerY - parent.centerY
            #expect((dx * dx + dy * dy).squareRoot() + circle.radius <= parent.radius + 1e-9)
        }
    }

    @Test("Children are the inverse of parents")
    func childrenAreTheInverse() {
        let index = BubbleIndex(BubbleFixture.nested())
        var counted = 0
        for i in index.circles.indices {
            for child in index.children(of: i) {
                #expect(index.parentIndex(of: child) == i)
                counted += 1
            }
        }
        #expect(counted == 24, "every circle below depth 0 should be somebody's child")
    }

    @Test("A subtree is everything nested inside, shallowest-first and not itself")
    func subtrees() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let top = try #require(index.circles.indices.first { index.circles[$0].depth == 0 })
        let subtree = index.subtree(from: top)
        // Three children, each with one of its own.
        #expect(subtree.count == 6)
        #expect(!subtree.contains(top))
        for (a, b) in zip(subtree, subtree.dropFirst()) {
            #expect(index.circles[a].depth <= index.circles[b].depth)
        }
        // Every one of them really is inside, geometrically — which is what the
        // hover lift relies on when it scales them about the parent's centre.
        let parent = index.circles[top]
        for i in subtree {
            let circle = index.circles[i]
            let dx = circle.centerX - parent.centerX, dy = circle.centerY - parent.centerY
            #expect((dx * dx + dy * dy).squareRoot() + circle.radius <= parent.radius + 1e-9)
        }
        // A leaf holds nothing, and an index that does not have that circle
        // answers with nothing rather than trapping.
        #expect(index.subtree(from: index.circles.count - 1).isEmpty)
        #expect(index.subtree(from: -1).isEmpty)
        #expect(index.subtree(from: index.circles.count).isEmpty)
    }

    // MARK: - Metrics

    @Test("A wide view draws the pack into a centred square, not a squashed one")
    func metricsCentreTheSquare() {
        let metrics = BubbleMetrics(bounds: CGRect(x: 0, y: 0, width: 900, height: 600))
        #expect(metrics.side == 600)
        #expect(metrics.square.midX == 450)
        #expect(metrics.square.midY == 300)
        // Radius is a fraction of the *smaller* side, so a circle of radius 0.5
        // is 600 points across in a 900×600 view and not 900.
        let circle = BubbleFixture.circle(slot: 1, x: 0.5, y: 0.5, r: 0.5, depth: 0, seed: 0)
        #expect(metrics.radius(of: circle) == 300)
        let centre = metrics.center(of: circle)
        #expect(centre.x == 450)
        #expect(centre.y == 300)
    }

    @Test("A degenerate view is degenerate rather than dividing by zero")
    func degenerateMetrics() {
        let metrics = BubbleMetrics(bounds: CGRect(x: 0, y: 0, width: 0, height: 400))
        #expect(metrics.isDegenerate)
        #expect(metrics.normalised(CGPoint(x: 0, y: 0)) == nil)
        #expect(BubbleMetrics(size: CGSize(width: 10, height: 10), inset: 12).isDegenerate)
    }

    @Test("Normalising is the inverse of projecting")
    func normalisationRoundTrips() throws {
        let metrics = BubbleFixture.metrics()
        for (x, y) in [(0.0, 0.0), (0.5, 0.5), (0.25, 0.9), (0.999, 0.999)] {
            let point = metrics.point(x: x, y: y)
            let back = try #require(metrics.normalised(point))
            #expect(abs(back.x - x) < 1e-9)
            #expect(abs(back.y - y) < 1e-9)
        }
        // `bounds` is half-open, exactly as `CGRect.contains` is, so the very
        // bottom-right point of the view is outside it. Worth stating: it is the
        // reason a hit test never has to special-case a click on the last pixel.
        #expect(metrics.normalised(CGPoint(x: 900, y: 600)) == nil)
        // Beside the square but still in the view: a legitimate point that maps
        // outside the unit box, which is the answer and not an error.
        let beside = try #require(metrics.normalised(CGPoint(x: 20, y: 300)))
        #expect(beside.x < 0)
        #expect(metrics.normalised(CGPoint(x: -5, y: 300)) == nil)
    }

    // MARK: - Hit testing

    @Test("A click takes the deepest circle under it")
    func hitTakesTheDeepest() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let metrics = BubbleFixture.metrics()

        for i in index.circles.indices {
            let circle = index.circles[i]
            // The centre of a depth-2 circle is inside its parent and its
            // grandparent too; the deepest is the one painted on top and the one
            // the user is pointing at.
            guard index.children(of: i).isEmpty else { continue }
            let hit = index.hit(at: metrics.center(of: circle), metrics: metrics)
            guard case .circle(let position) = hit else {
                Issue.record("centre of \(circle.name) hit nothing")
                continue
            }
            #expect(index[position]?.id == circle.id)
        }
    }

    @Test("A click on the parent's ring hits the parent, not a child")
    func hitFindsTheRing() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let metrics = BubbleFixture.metrics()
        let parent = try #require(index.circles(atDepth: 0).first)
        // Just inside the rim, which the packing keeps clear of children.
        let point = metrics.point(x: parent.centerX + parent.radius * 0.94, y: parent.centerY)
        guard case .circle(let position) = index.hit(at: point, metrics: metrics) else {
            Issue.record("the parent's own ring hit nothing")
            return
        }
        #expect(index[position]?.id == parent.id)
    }

    @Test("Empty space is the way back out, and outside the view is nothing")
    func backgroundAndNone() {
        let index = BubbleIndex(BubbleFixture.nested())
        let metrics = BubbleFixture.metrics()
        // Dead centre of the four quadrants: inside the focus disc and on no
        // circle at all.
        #expect(index.hit(at: metrics.point(x: 0.5, y: 0.5), metrics: metrics) == .background)
        // Beside the square, inside the view: still a way out.
        #expect(index.hit(at: CGPoint(x: 20, y: 300), metrics: metrics) == .background)
        #expect(index.hit(at: CGPoint(x: -50, y: 300), metrics: metrics) == .none)
    }

    @Test("A circle far smaller than a grid cell is still hittable")
    func subCellCirclesAreHittable() throws {
        // A hundredth of the container across, which is below the grid's cell
        // size — the case that would silently become unclickable if the coverage
        // pass only claimed cells whose centre it covered.
        let tiny = BubbleFixture.circle(slot: 7, x: 0.31234, y: 0.6789, r: 0.004,
                                        depth: 0, seed: 3)
        let index = BubbleIndex(BubbleFixture.layout([tiny]))
        let metrics = BubbleFixture.metrics()
        guard case .circle(let position) = index.hit(at: metrics.center(of: tiny),
                                                     metrics: metrics) else {
            Issue.record("a sub-cell circle could not be clicked")
            return
        }
        #expect(index[position]?.id == tiny.id)
        // And a point just outside it is not it.
        let near = metrics.point(x: tiny.centerX + 0.02, y: tiny.centerY)
        #expect(index.hit(at: near, metrics: metrics) == .background)
    }

    @Test("An empty layout is empty rather than crashing")
    func emptyLayout() {
        let index = BubbleIndex(.empty)
        #expect(index.isEmpty)
        #expect(index.depthCount == 0)
        #expect(index.hit(at: CGPoint(x: 10, y: 10), metrics: BubbleFixture.metrics()) == .background)
        #expect(index.position(at: 0) == nil)
        #expect(BubbleNavigator(index: index).initialFocus() == nil)
    }

    @Test("The focus name falls back to the path when there is no breadcrumb")
    func focusName() {
        let named = BubbleIndex(BubbleFixture.nested())
        #expect(named.focusName == "Users")
        let bare = BubbleIndex(BubbleFixture.layout(BubbleFixture.nested().circles, breadcrumb: []))
        #expect(bare.focusName == "Users")
    }
}
