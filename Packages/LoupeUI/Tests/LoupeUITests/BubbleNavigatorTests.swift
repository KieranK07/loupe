import CoreGraphics
import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Bubble navigation")
struct BubbleNavigatorTests {
    private func navigator(columns: Int, rows: Int) -> BubbleNavigator {
        BubbleNavigator(index: BubbleIndex(BubbleFixture.grid(columns: columns, rows: rows)))
    }

    private func name(_ navigator: BubbleNavigator, _ position: BubblePosition?) -> String? {
        position.flatMap { navigator.index[$0]?.name }
    }

    @Test("The arrows move one step across a lattice")
    func arrowsStepAcrossTheGrid() {
        let navigator = navigator(columns: 4, rows: 3)
        let start = navigator.index.position(ofNode: .directory(100 + 5))!  // r1c1
        #expect(name(navigator, start) == "r1c1")
        #expect(name(navigator, navigator.destination(from: start, move: .right)) == "r1c2")
        #expect(name(navigator, navigator.destination(from: start, move: .left)) == "r1c0")
        #expect(name(navigator, navigator.destination(from: start, move: .up)) == "r0c1")
        #expect(name(navigator, navigator.destination(from: start, move: .down)) == "r2c1")
    }

    @Test("The edge of the pack is the edge")
    func edgesStop() {
        let navigator = navigator(columns: 3, rows: 3)
        let corner = navigator.index.position(ofNode: .directory(100))!  // r0c0
        #expect(navigator.destination(from: corner, move: .left) == nil)
        #expect(navigator.destination(from: corner, move: .up) == nil)
        #expect(navigator.destination(from: corner, move: .right) != nil)
    }

    @Test("Option-down falls in, Option-up climbs back out")
    func depthMoves() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let navigator = BubbleNavigator(index: index)
        let top = try #require(navigator.largest(atDepth: 0))
        let inside = try #require(navigator.destination(from: top, move: .deeper))
        #expect(inside.depth == 1)
        #expect(index.parent(of: inside) == top)
        #expect(navigator.destination(from: inside, move: .shallower) == top)
        // The deepest level has nothing further in.
        let deepest = try #require(navigator.destination(from: inside, move: .deeper))
        #expect(navigator.destination(from: deepest, move: .deeper) == nil)
    }

    @Test("Falling in lands on the largest thing inside, not the first")
    func deeperTakesTheLargest() throws {
        let parent = BubbleFixture.circle(slot: 1, x: 0.5, y: 0.5, r: 0.4, depth: 0,
                                          seed: 0, hasChildren: true)
        let small = BubbleFixture.circle(slot: 2, x: 0.35, y: 0.5, r: 0.06, depth: 1, seed: 0)
        let large = BubbleFixture.circle(slot: 3, x: 0.62, y: 0.5, r: 0.14, depth: 1, seed: 0)
        let index = BubbleIndex(BubbleFixture.layout([parent, small, large]))
        let navigator = BubbleNavigator(index: index)
        let top = try #require(index.position(ofNode: parent.node))
        let inside = try #require(navigator.destination(from: top, move: .deeper))
        #expect(index[inside]?.node == large.node)
    }

    @Test("The keyboard starts on the biggest thing at the outermost level")
    func initialFocus() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let start = try #require(BubbleNavigator(index: index).initialFocus())
        #expect(start.depth == 0)
        let radius = try #require(index[start]?.radius)
        for circle in index.circles(atDepth: 0) { #expect(circle.radius <= radius + 1e-12) }
    }

    @Test("Ancestry is the chain outwards and it terminates")
    func ancestors() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let navigator = BubbleNavigator(index: index)
        let deepest = try #require(index.position(at: index.circles.count - 1))
        let chain = navigator.ancestors(of: deepest)
        #expect(chain.count == 2)
        #expect(chain.map(\.depth) == [1, 0])
        #expect(navigator.ancestors(of: try #require(navigator.largest(atDepth: 0))).isEmpty)
    }

    /// A neighbour whose span still overlaps yours is straight ahead however
    /// far its middle is from yours — otherwise "right" out of a small circle
    /// beside a tall one walks diagonally past it.
    @Test("A big neighbour beside a small one still counts as straight ahead")
    func strayIsAGapNotACentreOffset() throws {
        let small = BubbleFixture.circle(slot: 1, x: 0.2, y: 0.5, r: 0.03, depth: 0, seed: 0)
        let tall = BubbleFixture.circle(slot: 2, x: 0.45, y: 0.62, r: 0.16, depth: 0, seed: 1)
        let level = BubbleFixture.circle(slot: 3, x: 0.75, y: 0.5, r: 0.04, depth: 0, seed: 2)
        let index = BubbleIndex(BubbleFixture.layout([small, tall, level]))
        let navigator = BubbleNavigator(index: index)
        let start = try #require(index.position(ofNode: small.node))
        // `tall` is nearer and its span covers the row `small` is on, so it wins
        // even though its centre is well below.
        #expect(index[try #require(navigator.destination(from: start, move: .right))]?.node
                == tall.node)
    }
}

@Suite("Bubble zoom transition")
struct BubbleAnimationTests {
    private func nested() -> (BubbleIndex, BubbleIndex, BubbleCircle) {
        let layout = BubbleFixture.nested()
        let focus = layout.circles.first { $0.depth == 0 }!
        return (BubbleIndex(layout), BubbleIndex(BubbleFixture.zoomed(layout, into: focus)), focus)
    }

    @Test("With nothing to come from, every circle is at rest")
    func restingIsExact() {
        let index = BubbleIndex(BubbleFixture.nested())
        let frames = BubbleAnimation.frames(from: nil, to: index, progress: 0.3)
        #expect(frames.count == index.circles.count)
        for (frame, circle) in zip(frames, index.circles) {
            #expect(frame.centerX == circle.centerX)
            #expect(frame.centerY == circle.centerY)
            #expect(frame.radius == circle.radius)
            #expect(frame.opacity == 1)
        }
    }

    @Test("Zooming in and zooming out are the same relation read two ways")
    func relationIsSymmetric() throws {
        let (old, new, focus) = nested()
        let forward = try #require(BubbleAnimation.relation(from: old, to: new))
        // Old ↦ new must carry the clicked circle onto the whole container.
        #expect(abs(forward.x(focus.centerX) - 0.5) < 1e-12)
        #expect(abs(forward.y(focus.centerY) - 0.5) < 1e-12)
        #expect(abs(forward.length(focus.radius) - 0.5) < 1e-12)

        let back = try #require(BubbleAnimation.relation(from: new, to: old))
        let composed = forward.then(back)
        #expect(abs(composed.scale - 1) < 1e-12)
        #expect(abs(composed.offsetX) < 1e-12)
        #expect(abs(composed.offsetY) < 1e-12)
    }

    @Test("Two unrelated layouts have no relation and simply cross-fade")
    func unrelatedLayouts() {
        let a = BubbleIndex(BubbleFixture.grid(columns: 3, rows: 3))
        #expect(BubbleAnimation.relation(from: a, to: a) == nil)
        let frames = BubbleAnimation.frames(from: a, to: a, progress: 0.5)
        // Everything survives, so nothing departs and nothing moves.
        #expect(frames.count == a.circles.count)
        for frame in frames { #expect(frame.opacity == 1) }
    }

    @Test("At the start the new layout sits inside the circle you clicked")
    func startsInsideTheClickedCircle() throws {
        let (old, new, focus) = nested()
        let relation = try #require(BubbleAnimation.relation(from: old, to: new))
        let start = BubbleAnimation.viewTransform(relation: relation, progress: 0)
        // The whole new container maps onto the clicked circle exactly.
        #expect(abs(start.x(0.5) - focus.centerX) < 1e-12)
        #expect(abs(start.y(0.5) - focus.centerY) < 1e-12)
        #expect(abs(start.length(0.5) - focus.radius) < 1e-12)

        let end = BubbleAnimation.viewTransform(relation: relation, progress: 1)
        #expect(abs(end.scale - 1) < 1e-12)
        #expect(abs(end.offsetX) < 1e-12)
        #expect(abs(end.offsetY) < 1e-12)
    }

    /// The whole reason this is a camera move and not a per-circle interpolation:
    /// a circle in both layouts is in the same place under both transforms at
    /// every instant, so nothing slides relative to anything else.
    @Test("A survivor is in the same screen place under both transforms throughout")
    func survivorsStayPut() throws {
        let (old, new, _) = nested()
        let relation = try #require(BubbleAnimation.relation(from: old, to: new))

        var checked = 0
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            let newTransform = BubbleAnimation.viewTransform(relation: relation, progress: t)
            let oldTransform = relation.then(newTransform)
            for circle in new.circles {
                guard let position = old.position(ofNode: circle.node),
                      let before = old[position] else { continue }
                checked += 1
                #expect(abs(newTransform.x(circle.centerX) - oldTransform.x(before.centerX)) < 1e-9)
                #expect(abs(newTransform.y(circle.centerY) - oldTransform.y(before.centerY)) < 1e-9)
                #expect(abs(newTransform.length(circle.radius)
                            - oldTransform.length(before.radius)) < 1e-9)
            }
        }
        #expect(checked > 0, "the fixture produced no survivors, so this proved nothing")
    }

    @Test("The camera moves at a steady relative speed, not a steady absolute one")
    func scaleIsGeometric() throws {
        let (old, new, focus) = nested()
        let relation = try #require(BubbleAnimation.relation(from: old, to: new))
        let start = 2 * focus.radius
        let half = BubbleAnimation.viewTransform(relation: relation, progress: 0.5).scale
        // Geometric: halfway through is the geometric mean of the endpoints, not
        // the arithmetic one. On a fivefold zoom the two differ by a third of the
        // scale, which is the difference between a move and a snap.
        #expect(abs(half - (start * 1).squareRoot()) < 1e-9)
        #expect(half < (start + 1) / 2)
    }

    @Test("Survivors stay opaque, arrivals fade in, departures fade out")
    func opacityRamps() throws {
        let (old, new, _) = nested()
        let survivor = try #require(new.circles.first { old.position(ofNode: $0.node) != nil })
        let departed = try #require(old.circles.first { new.position(ofNode: $0.node) == nil })

        let early = BubbleAnimation.frames(from: old, to: new, progress: 0.2)
        let survivingFrame = try #require(early.first { $0.circle.id == survivor.id })
        #expect(survivingFrame.opacity == 1)
        let departingFrame = try #require(early.first { $0.circle.id == departed.id })
        #expect(departingFrame.opacity > 0 && departingFrame.opacity < 1)

        // Past the exit fraction the departing layout is gone entirely rather
        // than lingering at zero opacity and costing a composite each.
        let late = BubbleAnimation.frames(from: old, to: new, progress: 0.9)
        #expect(!late.contains { $0.circle.id == departed.id })
    }

    @Test("Departing circles are painted first so arrivals land on top")
    func painterOrder() throws {
        let (old, new, _) = nested()
        let frames = BubbleAnimation.frames(from: old, to: new, progress: 0.3)
        let newIDs = Set(new.circles.map(\.id))
        let firstArrival = try #require(frames.firstIndex { newIDs.contains($0.circle.id) })
        let lastDeparture = frames.lastIndex { !newIDs.contains($0.circle.id) }
        if let lastDeparture { #expect(lastDeparture < firstArrival) }
        // And within the arriving layout, shallowest first.
        var previous: UInt8 = 0
        for frame in frames[firstArrival...] {
            #expect(frame.circle.depth >= previous)
            previous = frame.circle.depth
        }
    }

    @Test("Reduce Motion means no animation at all")
    func reduceMotion() {
        #expect(BubbleAnimation.animation(reduceMotion: true) == nil)
        #expect(BubbleAnimation.animation(reduceMotion: false) != nil)
    }

    @Test("Progress is clamped, so a rogue value cannot invert the camera")
    func progressIsClamped() throws {
        let (old, new, _) = nested()
        let relation = try #require(BubbleAnimation.relation(from: old, to: new))
        #expect(BubbleAnimation.viewTransform(relation: relation, progress: -3).scale
                == BubbleAnimation.viewTransform(relation: relation, progress: 0).scale)
        #expect(BubbleAnimation.viewTransform(relation: relation, progress: 9).scale == 1)
        #expect(BubbleAnimation.frames(from: old, to: new, progress: 2).count == new.circles.count)
    }

    @Test("A degenerate transform inverts to nothing rather than to infinity")
    func degenerateTransform() {
        #expect(BubbleTransform(scale: 0, offsetX: 1, offsetY: 2).inverted == nil)
        let identity = BubbleTransform.identity
        #expect(identity.then(identity) == identity)
        let t = BubbleTransform(scale: 3, offsetX: -1, offsetY: 2)
        let round = t.then(t.inverted!)
        #expect(abs(round.scale - 1) < 1e-12)
        #expect(abs(round.offsetX) < 1e-12)
        #expect(abs(round.offsetY) < 1e-12)
    }
}
