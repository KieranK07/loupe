import CoreGraphics
import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Bubble labels")
struct BubbleLabelTests {

    /// The whole point of budgeting against the chord rather than the bounding
    /// box: a circle's box is four-fifths bigger than the circle, so a name
    /// measured against the box runs out through the side of the ball.
    @Test("A label is budgeted against the chord it will sit on, not the box")
    func chordArithmetic() {
        // A right triangle: at 3 above the centre of a radius-5 circle, the
        // half-chord is exactly 4.
        #expect(abs(BubbleLabels.halfChord(radius: 5, offsetFromCentre: 3) - 4) < 1e-12)
        #expect(BubbleLabels.halfChord(radius: 5, offsetFromCentre: 5) == 0)
        #expect(BubbleLabels.halfChord(radius: 5, offsetFromCentre: 9) == 0)
        #expect(abs(BubbleLabels.halfChord(radius: 5, offsetFromCentre: 0) - 5) < 1e-12)
    }

    @Test("A leaf is labelled across its middle, where the chord is widest")
    func leafLabelsAtTheCentre() throws {
        let leaf = BubbleFixture.circle(slot: 1, x: 0.5, y: 0.5, r: 0.3, depth: 0,
                                        seed: 0, hasChildren: false, name: "Library")
        let metrics = BubbleFixture.metrics()
        let slot = try #require(BubbleLabels.slot(leaf, metrics: metrics))
        #expect(slot.anchor == metrics.center(of: leaf))
        #expect(!slot.wantsPlate)
        // The budget is the chord at half a line height off centre, less the
        // clearance kept from the rim — never the diameter.
        let radius = metrics.radius(of: leaf)
        #expect(slot.widthBudget < radius * 2)
        #expect(slot.widthBudget > radius * 1.8)
    }

    /// A parent's middle is its children: the packing leaves only a thin ring of
    /// it showing. A name written across the centre would look like a name for
    /// whichever child is under it.
    @Test("A folder is labelled high, on a plate, and only at the outermost level")
    func parentLabelsHighOnAPlate() throws {
        let metrics = BubbleFixture.metrics()
        let outer = BubbleFixture.circle(slot: 1, x: 0.5, y: 0.5, r: 0.3, depth: 0,
                                         seed: 0, hasChildren: true, name: "Library")
        let slot = try #require(BubbleLabels.slot(outer, metrics: metrics))
        #expect(slot.wantsPlate)
        #expect(slot.anchor.y < metrics.center(of: outer).y)
        #expect(slot.anchor.x == metrics.center(of: outer).x)

        // Deeper folders stay unlabelled rather than stacking plate on plate.
        let inner = BubbleFixture.circle(slot: 2, x: 0.5, y: 0.5, r: 0.2, depth: 1,
                                         seed: 0, hasChildren: true, name: "Caches")
        #expect(BubbleLabels.slot(inner, metrics: metrics) == nil)
    }

    @Test("A ball too small to hold a readable fragment gets no label at all")
    func smallCirclesGoUnlabelled() {
        let metrics = BubbleFixture.metrics()
        for radius in [0.001, 0.004, 0.01] {
            let tiny = BubbleFixture.circle(slot: 1, x: 0.5, y: 0.5, r: radius, depth: 0,
                                            seed: 0, name: "node_modules")
            #expect(BubbleLabels.slot(tiny, metrics: metrics) == nil,
                    "a circle of radius \(radius) claimed a label")
        }
    }

    @Test("An aggregate is labelled as a group, never with the name it borrowed")
    func aggregateLabel() throws {
        let metrics = BubbleFixture.metrics()
        let group = BubbleFixture.circle(slot: 1, x: 0.5, y: 0.5, r: 0.3, depth: 0, seed: 0,
                                         hasChildren: false, kind: .aggregated(count: 91),
                                         name: "Photos Library.photoslibrary")
        let slot = try #require(BubbleLabels.slot(group, metrics: metrics))
        #expect(slot.text == "91 smaller items")
    }

    @Test("Hover and keyboard focus always get their name, however small the ball")
    func forcedSlots() throws {
        let index = BubbleIndex(BubbleFixture.nested())
        let metrics = BubbleFixture.metrics()
        let deepest = try #require(index.position(at: index.circles.count - 1))
        let slots = BubbleLabels.slots(for: index, metrics: metrics, hovered: deepest)
        let forced = try #require(slots.first { $0.isForced })
        #expect(forced.id == index[deepest]?.id)
        // A forced slot outranks everything, so it cannot lose its space.
        #expect(forced.priority == .infinity)
        // And it appears exactly once even when it is also the keyboard focus.
        let both = BubbleLabels.slots(for: index, metrics: metrics,
                                      hovered: deepest, keyboardFocus: deepest)
        #expect(both.filter { $0.isForced }.count == 1)
    }

    @Test("Slots come out biggest first and stay inside the limit")
    func slotsAreOrderedAndBounded() {
        let index = BubbleIndex(BubbleFixture.nested())
        let metrics = BubbleFixture.metrics()
        let slots = BubbleLabels.slots(for: index, metrics: metrics)
        #expect(!slots.isEmpty)
        for (a, b) in zip(slots, slots.dropFirst()) { #expect(a.priority >= b.priority) }
        #expect(BubbleLabels.slots(for: index, metrics: metrics, limit: 2).count == 2)
        #expect(BubbleLabels.slots(for: index, metrics: metrics, limit: 0).isEmpty)
        #expect(BubbleLabels.slots(for: index, metrics: BubbleMetrics(size: .zero)).isEmpty)
    }

    @Test("Placed labels stay inside their own ball and never overlap each other")
    func placementIsSound() {
        let index = BubbleIndex(BubbleFixture.nested())
        let metrics = BubbleFixture.metrics()
        let slots = BubbleLabels.slots(for: index, metrics: metrics)
        let placed = LabelPlacement.place(slots: slots) { FakeText.intrinsic($0) }
        #expect(!placed.isEmpty)

        for label in placed {
            guard let position = index.position(ofNode: NodeRef(rawValue: label.id)),
                  let circle = index[position] else { continue }
            let centre = metrics.center(of: circle)
            let radius = metrics.radius(of: circle)
            // Every corner of the text box has to be inside the ball. A label
            // that clears its width budget but not its own rim is exactly the
            // failure the chord arithmetic exists to prevent.
            for corner in label.box.corners {
                let dx = corner.x - centre.x, dy = corner.y - centre.y
                #expect((dx * dx + dy * dy).squareRoot() <= radius + 0.5,
                        "\(label.text) leaks out of its own circle")
            }
        }
        for (i, a) in placed.enumerated() {
            for b in placed[(i + 1)...] {
                #expect(!a.box.intersects(b.box), "\(a.text) collides with \(b.text)")
            }
        }
    }
}
