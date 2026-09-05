import CoreGraphics
import Foundation
import Testing
@testable import LoupeUI

@Suite("Label boxes and the placement pass")
struct LabelPlacementTests {

    // MARK: - Boxes

    @Test("Two unrotated boxes overlap exactly when their rectangles do")
    func axisAligned() {
        let a = LabelBox(center: CGPoint(x: 0, y: 0), size: CGSize(width: 40, height: 12))
        #expect(a.intersects(LabelBox(center: CGPoint(x: 30, y: 0), size: CGSize(width: 40, height: 12))))
        #expect(!a.intersects(LabelBox(center: CGPoint(x: 41, y: 0), size: CGSize(width: 40, height: 12))))
        #expect(!a.intersects(LabelBox(center: CGPoint(x: 0, y: 13), size: CGSize(width: 40, height: 12))))
        // Exactly touching is not overlapping: labels are padded before they
        // are tested, so a shared edge already has clear space in it.
        #expect(!a.intersects(LabelBox(center: CGPoint(x: 40, y: 0), size: CGSize(width: 40, height: 12))))
    }

    @Test("A rotated box is tested on its own axes, not on its bounding rectangle")
    func rotatedSeparation() {
        // Two long thin labels at right angles, offset along the diagonal. Their
        // axis-aligned bounds overlap heavily; the boxes themselves do not.
        let a = LabelBox(center: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 10),
                         rotation: .pi / 4)
        let b = LabelBox(center: CGPoint(x: 30, y: -30), size: CGSize(width: 100, height: 10),
                         rotation: .pi / 4)
        #expect(a.boundingRect.intersects(b.boundingRect), "the premise of this test")
        #expect(!a.intersects(b), "bounding boxes overlap but the labels do not")

        let c = LabelBox(center: CGPoint(x: 6, y: 6), size: CGSize(width: 100, height: 10),
                         rotation: .pi / 4)
        #expect(a.intersects(c), "two labels on the same baseline six points apart do overlap")
    }

    @Test("Intersection is symmetric for rotated boxes")
    func symmetry() {
        var generator = SplitMix64(seed: 9_1_2026)
        for _ in 0..<400 {
            let a = LabelBox(center: CGPoint(x: Double.random(in: -50...50, using: &generator),
                                             y: Double.random(in: -50...50, using: &generator)),
                             size: CGSize(width: Double.random(in: 5...80, using: &generator),
                                          height: Double.random(in: 5...20, using: &generator)),
                             rotation: Double.random(in: -3...3, using: &generator))
            let b = LabelBox(center: CGPoint(x: Double.random(in: -50...50, using: &generator),
                                             y: Double.random(in: -50...50, using: &generator)),
                             size: CGSize(width: Double.random(in: 5...80, using: &generator),
                                          height: Double.random(in: 5...20, using: &generator)),
                             rotation: Double.random(in: -3...3, using: &generator))
            #expect(a.intersects(b) == b.intersects(a))
        }
    }

    // MARK: - Truncation

    @Test("Truncation elides the middle, because that is where these names differ")
    func middleTruncation() {
        let uuid = "C2296EE4-908B-4BDA-8176-CA8439D5016A"
        let short = LabelPlacement.middleTruncated(uuid, keeping: 10)
        #expect(short.hasPrefix("C2296"))
        #expect(short.hasSuffix("5016A"))
        #expect(short.contains(LabelPlacement.ellipsis))
        #expect(short.count == 11, "ten characters plus the elision, got \(short)")
    }

    @Test("A string shorter than the floor is dropped rather than shortened")
    func belowTheFloor() {
        let fitted = LabelPlacement.truncate("abcd", toWidth: 4,
                                             minimumVisibleCharacters: 4,
                                             measure: FakeText.intrinsic)
        #expect(fitted == nil)
    }

    @Test("Truncation returns the longest fragment that fits")
    func longestFragment() throws {
        let name = "com.apple.MobileSoftwareUpdate.UpdateBrainService"
        let fitted = try #require(LabelPlacement.truncate(name, toWidth: 60,
                                                          minimumVisibleCharacters: 4,
                                                          measure: FakeText.intrinsic))
        #expect(fitted.size.width <= 60)
        // One more character would not have fitted.
        let visible = fitted.text.count - 1
        let longer = LabelPlacement.middleTruncated(name, keeping: visible + 1)
        #expect(FakeText.intrinsic(longer).width > 60)
    }

    // MARK: - The pass

    private func slot(_ id: UInt32, _ text: String, x: Double, y: Double,
                      width: Double = 200, priority: Double,
                      forced: Bool = false, plate: Bool = false) -> LabelSlot {
        LabelSlot(id: id, text: text, anchor: CGPoint(x: x, y: y), rotation: 0,
                  widthBudget: width, heightBudget: 20, priority: priority,
                  isForced: forced, wantsPlate: plate)
    }

    @Test("When two labels want the same pixels, the bigger shape keeps its name")
    func biggestWins() throws {
        let placed = LabelPlacement.place(slots: [
            slot(1, "Library", x: 100, y: 100, priority: 1),
            slot(2, "Caches", x: 104, y: 100, priority: 9),
        ], measure: FakeText.intrinsic)
        #expect(placed.count == 1)
        #expect(placed.first?.id == 2)
    }

    @Test("Accepted labels never overlap, whatever order they arrive in")
    func noOverlaps() {
        var generator = SplitMix64(seed: 4242)
        var slots: [LabelSlot] = []
        for i in 0..<300 {
            slots.append(LabelSlot(id: UInt32(i),
                                   text: FixtureNames.name(i),
                                   anchor: CGPoint(x: Double.random(in: 0...400, using: &generator),
                                                   y: Double.random(in: 0...400, using: &generator)),
                                   rotation: Double.random(in: -1.5...1.5, using: &generator),
                                   widthBudget: 120, heightBudget: 20,
                                   priority: Double.random(in: 0...1, using: &generator)))
        }
        let placed = LabelPlacement.place(slots: slots, measure: FakeText.intrinsic)
        #expect(placed.count > 5, "the pass rejected everything")
        #expect(overlappingPairs(placed.map(\.box)) == 0)
    }

    @Test("The wedge under the pointer keeps its name even with no room for it")
    func forcedWins() throws {
        let tiny = LabelSlot(id: 7, text: "C2296EE4-908B-4BDA-8176-CA8439D5016A",
                             anchor: CGPoint(x: 100, y: 100), rotation: 0,
                             widthBudget: 3, heightBudget: 3, priority: 0, isForced: true)
        let big = slot(8, "Library", x: 102, y: 100, priority: 100)
        let placed = LabelPlacement.place(slots: [big, tiny], measure: FakeText.intrinsic)
        let forced = try #require(placed.first { $0.id == 7 })
        #expect(forced.needsPlate, "a label with no room has to be drawn as a readout")
        #expect(!placed.contains { $0.id == 8 }, "the big neighbour yields to what is being pointed at")
    }

    @Test("A group header keeps its plate even when it fits")
    func plateRequested() throws {
        let placed = LabelPlacement.place(slots: [
            slot(1, "Library", x: 100, y: 20, priority: 1, plate: true),
        ], measure: FakeText.intrinsic)
        #expect(try #require(placed.first).needsPlate)
    }

    @Test("Distinct sizes decide the outcome, whatever order the slots arrive in")
    func orderIndependentWhenSizesDiffer() {
        var slots: [LabelSlot] = []
        for i in 0..<40 {
            let x = Double(i % 8) * 30
            let y = Double(i / 8) * 8
            slots.append(slot(UInt32(i), FixtureNames.name(i), x: x, y: y, priority: Double(i)))
        }
        let forwards = LabelPlacement.place(slots: slots, measure: FakeText.intrinsic)
        let backwards = LabelPlacement.place(slots: slots.reversed(), measure: FakeText.intrinsic)
        let forwardIDs = Set(forwards.map { $0.id })
        let backwardIDs = Set(backwards.map { $0.id })
        #expect(forwardIDs == backwardIDs)
    }

    @Test("Ties break on input order, so the same chart labels the same shapes every run")
    func deterministicOnTies() {
        // Identical sizes and overlapping anchors: only the tiebreak can decide.
        var slots: [LabelSlot] = []
        for i in 0..<12 {
            slots.append(slot(UInt32(i), "Library", x: 100 + Double(i), y: 100, priority: 1))
        }
        let first = LabelPlacement.place(slots: slots, measure: FakeText.intrinsic)
        let second = LabelPlacement.place(slots: slots, measure: FakeText.intrinsic)
        #expect(first.map { $0.id } == second.map { $0.id })
        #expect(first.first?.id == 0, "the earliest slot won the tie")
    }

    @Test("The pass never returns more labels than a chart can carry")
    func capped() {
        var slots: [LabelSlot] = []
        for i in 0..<400 {
            slots.append(slot(UInt32(i), "Library", x: Double(i) * 60, y: 0, priority: Double(400 - i)))
        }
        let configuration = LabelPlacement.Configuration(maximumLabels: 12, candidateLimit: 400)
        let placed = LabelPlacement.place(slots: slots, configuration: configuration,
                                          measure: FakeText.intrinsic)
        #expect(placed.count == 12)
    }
}

/// Every pair of boxes that share pixels. The number the label pass exists to
/// drive to zero.
func overlappingPairs(_ boxes: [LabelBox]) -> Int {
    var count = 0
    for i in boxes.indices {
        for j in boxes.indices where j > i && boxes[i].intersects(boxes[j]) { count += 1 }
    }
    return count
}
