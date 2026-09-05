import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Keyboard navigation from geometry alone")
struct SunburstNavigatorTests {
    private func navigator(_ levels: [[Double]], startAt: Double = 0) -> SunburstNavigator {
        SunburstNavigator(index: SunburstIndex(Fixture.layout(levels: levels, startAt: startAt)))
    }

    // MARK: - Siblings

    @Test("Right and left step between ring neighbours")
    func siblingSteps() {
        let nav = navigator([[1, 2, 3, 4]])
        let second = SunburstPosition(ring: 0, offset: 1)
        #expect(nav.destination(from: second, move: .nextSibling) == SunburstPosition(ring: 0, offset: 2))
        #expect(nav.destination(from: second, move: .previousSibling) == SunburstPosition(ring: 0, offset: 0))
    }

    /// A ring is a circle. Arrowing off the last wedge lands on the first,
    /// because that is literally what is next to it on screen.
    @Test("Siblings wrap at the seam in both directions")
    func siblingWrapAround() {
        let nav = navigator([[1, 1, 1, 1, 1]])
        let last = SunburstPosition(ring: 0, offset: 4)
        let first = SunburstPosition(ring: 0, offset: 0)
        #expect(nav.destination(from: last, move: .nextSibling) == first)
        #expect(nav.destination(from: first, move: .previousSibling) == last)
    }

    @Test("A ring of one wedge steps to itself rather than to nothing")
    func singleSibling() {
        let nav = navigator([[1]])
        let only = SunburstPosition(ring: 0, offset: 0)
        #expect(nav.destination(from: only, move: .nextSibling) == only)
        #expect(nav.destination(from: only, move: .previousSibling) == only)
    }

    @Test("Stepping from a position that no longer exists goes nowhere")
    func siblingFromStalePosition() {
        let nav = navigator([[1, 1]])
        let stale = SunburstPosition(ring: 0, offset: 9)
        #expect(nav.destination(from: stale, move: .nextSibling) == nil)
        #expect(nav.destination(from: stale, move: .parent) == nil)
        #expect(nav.destination(from: stale, move: .largestChild) == nil)
    }

    // MARK: - Parent and child

    @Test("Every wedge's parent contains it, and every ring-0 wedge has none")
    func parentContainment() {
        let index = SunburstIndex(Fixture.layout(levels: [[3, 1, 2], [1, 4, 2], [2, 1]]))
        let nav = SunburstNavigator(index: index)

        for ring in 0..<index.ringCount {
            for offset in 0..<index.count(inRing: ring) {
                let position = SunburstPosition(ring: ring, offset: offset)
                let parent = nav.parent(of: position)
                if ring == 0 {
                    #expect(parent == nil, "ring 0 should have no parent inside the layout")
                    continue
                }
                guard let parent, let parentWedge = index[parent], let child = index[position] else {
                    Issue.record("ring \(ring) offset \(offset) lost its parent")
                    continue
                }
                #expect(parent.ring == ring - 1)
                #expect(nav.isContained(child, in: parentWedge))
            }
        }
    }

    @Test("Down arrow takes the largest child, up arrow comes straight back")
    func largestChildAndBack() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1], [1, 5, 2]]))
        let nav = SunburstNavigator(index: index)
        let parent = SunburstPosition(ring: 0, offset: 0)

        let children = nav.children(of: parent)
        #expect(children.count == 3)

        guard let child = nav.destination(from: parent, move: .largestChild) else {
            Issue.record("no child found")
            return
        }
        // Weights 1, 5, 2 — the middle one is the largest.
        #expect(child == SunburstPosition(ring: 1, offset: 1))
        #expect(nav.destination(from: child, move: .parent) == parent)
    }

    @Test("Children belong to their own parent and to no other")
    func childrenArePartitioned() {
        let index = SunburstIndex(Fixture.layout(levels: [[2, 3, 1, 4], [1, 2, 3]]))
        let nav = SunburstNavigator(index: index)
        var seen: Set<SunburstPosition> = []
        for offset in 0..<index.count(inRing: 0) {
            let children = nav.children(of: SunburstPosition(ring: 0, offset: offset))
            #expect(children.count == 3, "parent \(offset) claimed \(children.count) children")
            for child in children {
                #expect(seen.insert(child).inserted, "\(child) was claimed twice")
            }
        }
        #expect(seen.count == index.count(inRing: 1))
    }

    @Test("The outermost ring has no children and ring 0 has no parent")
    func edgesOfTheChart() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1], [1, 1]]))
        let nav = SunburstNavigator(index: index)
        let outer = SunburstPosition(ring: 1, offset: 0)
        #expect(nav.destination(from: outer, move: .largestChild) == nil)
        #expect(nav.destination(from: SunburstPosition(ring: 0, offset: 0), move: .parent) == nil)
        // But siblings still work at both extremes.
        #expect(nav.destination(from: outer, move: .nextSibling) != nil)
    }

    // MARK: - The seam

    /// A ring 0 that starts at 6.0 rad puts one wedge across 12 o'clock and
    /// pushes the rest of the ring past 2π. Containment, parents and children
    /// all have to keep working there, or arrowing around the top of the chart
    /// walks to the wrong node.
    @Test("Parent and child relations survive the seam", arguments: [0.0, 5.9, 6.28])
    func seamCrossing(startAt: Double) {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1, 1], [3, 1]], startAt: startAt))
        let nav = SunburstNavigator(index: index)
        var claimed: Set<SunburstPosition> = []
        for offset in 0..<index.count(inRing: 0) {
            let parent = SunburstPosition(ring: 0, offset: offset)
            let children = nav.children(of: parent)
            #expect(children.count == 2, "parent \(offset) at start \(startAt) got \(children.count)")
            for child in children {
                #expect(claimed.insert(child).inserted)
                #expect(nav.parent(of: child) == parent)
            }
            #expect(nav.destination(from: parent, move: .largestChild) == children.first)
        }
        #expect(claimed.count == index.count(inRing: 1))
    }

    @Test("Ancestors walk inward and stop at ring 0")
    func ancestorChain() {
        let index = SunburstIndex(Fixture.layout(levels: [[1, 1], [1, 1], [1, 1], [1, 1]]))
        let nav = SunburstNavigator(index: index)
        let deep = SunburstPosition(ring: 3, offset: 5)
        let chain = nav.ancestors(of: deep)
        #expect(chain.map(\.ring) == [2, 1, 0])
        #expect(nav.ancestors(of: SunburstPosition(ring: 0, offset: 0)).isEmpty)
    }

    @Test("Initial focus is the largest wedge in the innermost ring")
    func initialFocus() {
        let nav = navigator([[1, 7, 2, 3]])
        #expect(nav.initialFocus() == SunburstPosition(ring: 0, offset: 1))
        #expect(SunburstNavigator(index: SunburstIndex(.empty)).initialFocus() == nil)
    }

    @Test("Walking the whole ring with the right arrow visits every wedge once")
    func fullCircuit() {
        let nav = navigator([[1, 2, 3, 4, 5, 6, 7]])
        var position = SunburstPosition(ring: 0, offset: 0)
        var visited: Set<SunburstPosition> = [position]
        for _ in 0..<6 {
            guard let next = nav.destination(from: position, move: .nextSibling) else {
                Issue.record("ran out of siblings early")
                return
            }
            #expect(visited.insert(next).inserted)
            position = next
        }
        #expect(visited.count == 7)
        #expect(nav.destination(from: position, move: .nextSibling) == SunburstPosition(ring: 0, offset: 0))
    }
}
