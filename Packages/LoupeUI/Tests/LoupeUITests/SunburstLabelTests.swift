import CoreGraphics
import Foundation
import LoupeCore
import Testing
@testable import LoupeUI

@Suite("Wedge labels stay inside their wedges and off each other")
struct SunburstLabelTests {

    // MARK: - Fixtures

    /// A layout of the density that broke the old pass: three rings, a few
    /// hundred wedges wide enough to want a name, and names that are long,
    /// similar, and differ in the middle.
    private func denseIndex(seed: UInt64 = 3_350_000, rings: [Int] = [9, 11, 13]) -> SunburstIndex {
        var generator = SplitMix64(seed: seed)
        var levels: [[Double]] = []
        for count in rings {
            var weights: [Double] = []
            for _ in 0..<count { weights.append(Double.random(in: 0.15...4, using: &generator)) }
            levels.append(weights)
        }
        return SunburstIndex(Fixture.layout(levels: levels,
                                            nameForRing: { _, _, slot in FixtureNames.name(Int(slot)) }))
    }

    private func metrics(_ side: Double, rings: Int) -> SunburstMetrics {
        SunburstMetrics(size: CGSize(width: side, height: side), ringCount: rings)
    }

    /// The pass as it was before this work: top two dozen wedges by sweep, a
    /// budget projected onto the screen axes, and text measured against that
    /// budget as a *proposal* — so a name that does not fit is reported as
    /// fitting on four wrapped lines. No collision test of any kind.
    private func legacyBoxes(_ index: SunburstIndex, _ metrics: SunburstMetrics) -> [(LabelBox, Wedge)] {
        guard metrics.ringThickness >= 16 else { return [] }
        var candidates: [Wedge] = []
        for wedge in index.wedges
        where !wedge.isAggregated
            && metrics.arcLength(sweep: wedge.sweep, ring: Int(wedge.ring)) >= 44 {
            candidates.append(wedge)
        }
        candidates.sort { $0.sweep > $1.sweep }

        var boxes: [(LabelBox, Wedge)] = []
        for wedge in candidates.prefix(24) {
            let ring = Int(wedge.ring)
            let mid = wedge.startAngle + wedge.sweep / 2
            let radius = metrics.midRadius(forRing: ring)
            let screen = mid - .pi / 2
            let radialX = abs(cos(screen)), radialY = abs(sin(screen))
            let arc = metrics.arcLength(sweep: wedge.sweep, ring: ring)
            let widthBudget = (metrics.ringThickness * radialX + arc * radialY) * 0.78
            let heightBudget = (metrics.ringThickness * radialY + arc * radialX) * 0.78
            guard widthBudget >= 24, heightBudget >= 11 else { continue }
            let proposal = CGSize(width: widthBudget, height: heightBudget)
            let size = FakeText.wrapped(wedge.name, in: proposal)
            guard size.width <= widthBudget, size.height <= heightBudget else { continue }
            boxes.append((LabelBox(center: metrics.point(radius: radius, angle: mid), size: size), wedge))
        }
        return boxes
    }

    private func placed(_ index: SunburstIndex, _ metrics: SunburstMetrics,
                        hovered: SunburstPosition? = nil,
                        keyboardFocus: SunburstPosition? = nil) -> [PlacedLabel] {
        let slots = SunburstLabels.slots(for: index, metrics: metrics,
                                         hovered: hovered, keyboardFocus: keyboardFocus)
        return LabelPlacement.place(slots: slots, measure: FakeText.intrinsic)
    }

    private func wedge(for label: PlacedLabel, in index: SunburstIndex) -> Wedge? {
        index.position(ofNode: NodeRef(rawValue: label.id)).flatMap { index[$0] }
    }

    /// Every corner of the box inside the wedge's own annular sector.
    private func staysInside(_ box: LabelBox, _ wedge: Wedge, _ metrics: SunburstMetrics) -> Bool {
        let radii = metrics.radii(forRing: Int(wedge.ring))
        for corner in box.corners {
            let radius = metrics.radius(at: corner)
            guard radius >= radii.inner - 1e-6, radius <= radii.outer + 1e-6 else { return false }
            guard wedge.sweep < SunburstAngle.fullTurn - 1e-9 else { continue }
            let lifted = SunburstAngle.lifted(metrics.angle(at: corner), into: wedge.startAngle - 1e-9)
            guard lifted <= wedge.endAngle + 1e-9 else { return false }
        }
        return true
    }

    // MARK: - The bug

    @Test("The old pass overlapped and overflowed; this one does neither")
    func collisionsGone() {
        let index = denseIndex()
        let geometry = metrics(900, rings: index.ringCount)

        let legacy = legacyBoxes(index, geometry)
        let legacyOverlaps = overlappingPairs(legacy.map(\.0))
        let legacyEscapes = legacy.filter { !staysInside($0.0, $0.1, geometry) }.count

        let now = placed(index, geometry)
        let overlaps = overlappingPairs(now.map(\.box))
        var escapes = 0
        for label in now {
            guard let wedge = wedge(for: label, in: index) else { continue }
            if !staysInside(label.box, wedge, geometry) { escapes += 1 }
        }

        // The premise: the old pass really did put names on top of each other
        // and outside their own wedges on this layout.
        #expect(legacyOverlaps > 0, "the fixture is not dense enough to reproduce the bug")
        #expect(legacyEscapes > 0, "the fixture does not reproduce the overflow")

        #expect(overlaps == 0,
                "\(overlaps) overlapping pairs among \(now.count) labels (was \(legacyOverlaps) among \(legacy.count))")
        #expect(escapes == 0,
                "\(escapes) labels outside their own wedge (was \(legacyEscapes))")
        #expect(now.count >= 8, "only \(now.count) labels survived; the pass is too strict")
    }

    @Test("No overlaps at any window size", arguments: [420.0, 560.0, 720.0, 900.0, 1400.0])
    func noOverlapsAtAnySize(side: Double) {
        let index = denseIndex()
        let geometry = metrics(side, rings: index.ringCount)
        let labels = placed(index, geometry)
        #expect(overlappingPairs(labels.map(\.box)) == 0, "at \(side)pt")
        for label in labels {
            guard let wedge = wedge(for: label, in: index) else { continue }
            #expect(staysInside(label.box, wedge, geometry),
                    "\(label.text) escaped its wedge at \(side)pt")
        }
    }

    @Test("Deep, thin rings label nothing rather than smearing")
    func thinRings() {
        var generator = SplitMix64(seed: 77)
        var levels: [[Double]] = []
        for _ in 0..<7 {
            var weights: [Double] = []
            for _ in 0..<6 { weights.append(Double.random(in: 0.5...3, using: &generator)) }
            levels.append(weights)
        }
        let index = SunburstIndex(Fixture.layout(levels: levels))
        // Seven rings in a 320pt square leaves each ring about 17pt thick.
        let geometry = metrics(320, rings: index.ringCount)
        let labels = placed(index, geometry)
        #expect(overlappingPairs(labels.map(\.box)) == 0)
        for label in labels {
            guard let wedge = wedge(for: label, in: index) else { continue }
            #expect(staysInside(label.box, wedge, geometry))
        }
    }

    // MARK: - The floor

    @Test("Nothing below the legibility floor is labelled")
    func legibilityFloor() {
        let index = denseIndex()
        let geometry = metrics(900, rings: index.ringCount)
        for label in placed(index, geometry) {
            guard let wedge = wedge(for: label, in: index) else { continue }
            let arc = geometry.arcLength(sweep: wedge.sweep, ring: Int(wedge.ring))
            #expect(arc >= SunburstLabels.minimumArcLength,
                    "\(label.text) was drawn in \(arc)pt of arc")
        }
    }

    @Test("A ring too thin for a line of text is not labelled at all")
    func ringTooThin() {
        let index = denseIndex()
        let thin = SunburstMetrics(center: CGPoint(x: 200, y: 200), centreRadius: 60,
                                   ringThickness: SunburstLabels.minimumRingThickness - 1,
                                   ringCount: index.ringCount)
        #expect(SunburstLabels.slots(for: index, metrics: thin).isEmpty)
    }

    @Test("Long names are elided in the middle, never at the head")
    func truncationIsMiddle() {
        let index = denseIndex()
        let geometry = metrics(900, rings: index.ringCount)
        let truncated = placed(index, geometry).filter(\.isTruncated)
        #expect(!truncated.isEmpty, "nothing needed truncating; the fixture is too easy")
        for label in truncated {
            #expect(label.text.contains(LabelPlacement.ellipsis))
            #expect(!label.text.hasPrefix(LabelPlacement.ellipsis),
                    "\(label.text) was cut at the head, which identifies nothing")
        }
    }

    // MARK: - Hover and focus

    @Test("The wedge under the pointer is labelled however small it is")
    func hoverAlwaysLabelled() throws {
        let index = denseIndex()
        let geometry = metrics(900, rings: index.ringCount)
        // The narrowest wedge in the outermost ring: far below the floor.
        let ring = index.ringCount - 1
        let range = index.ringRanges[ring]
        var smallest = range.lowerBound
        for i in range where index.wedges[i].sweep < index.wedges[smallest].sweep { smallest = i }
        let position = SunburstPosition(ring: ring, offset: smallest - range.lowerBound)
        let target = try #require(index[position])

        let ambient = placed(index, geometry)
        #expect(!ambient.contains { $0.id == target.id }, "the premise: too small to label normally")

        let hovered = placed(index, geometry, hovered: position)
        let label = try #require(hovered.first { $0.id == target.id })
        #expect(label.needsPlate, "a label with no room has to be drawn as a readout")
        #expect(overlappingPairs(hovered.map(\.box)) == 0)
    }

    @Test("Keyboard focus is labelled too, and does not fight the pointer")
    func focusAlsoLabelled() throws {
        let index = denseIndex()
        let geometry = metrics(900, rings: index.ringCount)
        let hovered = SunburstPosition(ring: 2, offset: 3)
        let focused = SunburstPosition(ring: 2, offset: 4)
        let labels = placed(index, geometry, hovered: hovered, keyboardFocus: focused)
        let hoveredWedge = try #require(index[hovered])
        #expect(labels.contains { $0.id == hoveredWedge.id })
        #expect(overlappingPairs(labels.map(\.box)) == 0)
    }

    // MARK: - Honesty

    @Test("An aggregate is never labelled with the name it borrowed")
    func aggregatesSayWhatTheyAre() throws {
        let index = SunburstIndex(Fixture.layout(
            levels: [[6, 3, 1]],
            kindForRing: { _, child in child == 0 ? .aggregated(count: 412) : .real },
            nameForRing: { _, _, slot in FixtureNames.name(Int(slot)) }))
        let geometry = metrics(700, rings: index.ringCount)
        let aggregate = try #require(index[SunburstPosition(ring: 0, offset: 0)])
        let labels = placed(index, geometry)
        let label = try #require(labels.first { $0.id == aggregate.id })
        #expect(label.text.hasPrefix("412"))
        #expect(!label.text.contains(aggregate.name),
                "an aggregate must never wear the name it borrowed")
    }

    @Test("The innermost rings read horizontally, the outer ones follow the ring")
    func orientation() {
        let index = denseIndex(rings: [4, 4, 4])
        let geometry = metrics(1000, rings: index.ringCount)
        let slots = SunburstLabels.slots(for: index, metrics: geometry)
        let inner = slots.filter { slot in
            guard let position = index.position(ofNode: NodeRef(rawValue: slot.id)) else { return false }
            return position.ring == 0
        }
        #expect(!inner.isEmpty)
        #expect(inner.allSatisfy { $0.rotation == 0 }, "ring 0 should read flat")

        let outer = slots.filter { slot in
            guard let position = index.position(ofNode: NodeRef(rawValue: slot.id)) else { return false }
            return position.ring == 2
        }
        #expect(outer.contains { $0.rotation != 0 }, "the outer ring should follow the ring")
        // Nothing is ever written upside down.
        #expect(slots.allSatisfy { abs($0.rotation) <= .pi / 2 + 1e-9 })
    }
}
