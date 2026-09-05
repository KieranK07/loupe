import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI
import Testing
@testable import LoupeUI

/// The treemap's zoom transition and hover lift, as arithmetic.
///
/// Everything here is a pure function on purpose. A `Canvas` mid-animation is
/// almost impossible to assert anything about, and every interesting claim —
/// which tiles survived, where they are half way through, what leaves early and
/// what arrives late — is a claim about numbers that were computed before a
/// pixel was touched.
@Suite("The treemap moves between layouts")
struct TreemapMotionTests {

    /// Two layouts sharing some nodes, so survivors, arrivals and departures all
    /// exist at once. `shift` moves every shared tile, so a survivor that failed
    /// to interpolate would sit still and be caught.
    private func layout(nodes: [UInt32], shift: Double, generation: UInt64) -> TreemapLayout {
        let width = 1.0 / Double(max(1, nodes.count))
        let tiles = nodes.enumerated().map { offset, node in
            TreemapTile(node: .directory(node),
                        frame: TreemapRect(x: Double(offset) * width,
                                           y: shift, width: width, height: 1 - shift),
                        depth: 0, physicalBytes: 1_000, logicalBytes: 1_000, itemCount: 1,
                        name: "n\(node)", kind: .real, colorSeed: UInt16(node))
        }
        return TreemapLayout(generation: generation, focus: .directory(UInt32(generation)),
                             focusPath: "/", breadcrumb: [],
                             tiles: tiles, totalPhysicalBytes: 1_000, totalLogicalBytes: 1_000,
                             scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             isComplete: true)
    }

    private var old: TreemapIndex { TreemapIndex(layout(nodes: [1, 2, 3], shift: 0, generation: 1)) }
    private var new: TreemapIndex { TreemapIndex(layout(nodes: [2, 3, 4], shift: 0.5, generation: 2)) }

    // MARK: - Interpolation

    @Test("Half way is half way, on all four components")
    func interpolateMidpoint() {
        let a = TreemapRect(x: 0, y: 0, width: 0.4, height: 1)
        let b = TreemapRect(x: 0.6, y: 0.25, width: 0.4, height: 0.5)
        let mid = TreemapAnimation.interpolate(from: a, to: b, progress: 0.5)
        #expect(abs(mid.x - 0.3) < 1e-12)
        #expect(abs(mid.y - 0.125) < 1e-12)
        #expect(abs(mid.width - 0.4) < 1e-12)
        #expect(abs(mid.height - 0.75) < 1e-12)
    }

    @Test("Progress outside 0...1 is clamped rather than extrapolated")
    func interpolateClamps() {
        let a = TreemapRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let b = TreemapRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        #expect(TreemapAnimation.interpolate(from: a, to: b, progress: -4) == a)
        #expect(TreemapAnimation.interpolate(from: a, to: b, progress: 7) == b)
    }

    /// A tile that never leaves the unit square in either layout must not leave
    /// it in between. Swept, because the failure mode of an interpolation is
    /// almost never at the ends.
    @Test("A tile stays inside the map for the whole transition")
    func staysInsideTheMap() {
        var escapes = 0
        for frameCount in stride(from: 0.0, through: 1.0, by: 0.02) {
            for frame in TreemapAnimation.frames(from: old, to: new, progress: frameCount) {
                let r = frame.rect
                if r.x < -1e-9 || r.y < -1e-9 || r.maxX > 1 + 1e-9 || r.maxY > 1 + 1e-9 {
                    escapes += 1
                }
                if r.width < -1e-9 || r.height < -1e-9 { escapes += 1 }
            }
        }
        #expect(escapes == 0, "\(escapes) rectangles left the map mid-transition")
    }

    // MARK: - Who survives

    /// The whole point of matching by `NodeRef`: a folder you can still see
    /// after a zoom slid there, and did not blink out while a stranger blinked
    /// in over the same rectangle.
    @Test("A tile that exists in both layouts slides between them")
    func survivorsMove() throws {
        let frames = TreemapAnimation.frames(from: old, to: new, progress: 0.5)
        let survivor = try #require(frames.first { $0.tile.node == .directory(2) })
        #expect(survivor.opacity == 1, "a survivor must never fade")
        // Half way between y = 0 and y = 0.5.
        #expect(abs(survivor.rect.y - 0.25) < 1e-12,
                "the survivor did not move: \(survivor.rect)")
    }

    @Test("Arrivals hold back and departures leave early")
    func arrivalsAndDepartures() throws {
        // Just after the start: the newcomer is not there yet and the departing
        // tile still is, so the transition begins with only geometry moving.
        let early = TreemapAnimation.frames(from: old, to: new, progress: 0.1)
        let arriving = try #require(early.first { $0.tile.node == .directory(4) })
        let leaving = try #require(early.first { $0.tile.node == .directory(1) })
        #expect(arriving.opacity == 0, "the new tile arrived on top of moving geometry")
        #expect(leaving.opacity > 0)

        // Past the exit fraction the departing tile is gone entirely — not drawn
        // at zero opacity, which would still cost a fill per frame.
        let late = TreemapAnimation.frames(from: old, to: new, progress: 0.9)
        #expect(!late.contains { $0.tile.node == .directory(1) })
        #expect(try #require(late.first { $0.tile.node == .directory(4) }).opacity > 0)
    }

    @Test("Entry and exit opacities are monotonic across the transition")
    func opacitiesAreMonotonic() {
        var lastEntry = -1.0
        var lastExit = 2.0
        for t in stride(from: 0.0, through: 0.99, by: 0.01) {
            let frames = TreemapAnimation.frames(from: old, to: new, progress: t)
            let entry = frames.first { $0.tile.node == .directory(4) }?.opacity ?? 0
            let exit = frames.first { $0.tile.node == .directory(1) }?.opacity ?? 0
            #expect(entry >= lastEntry - 1e-9, "an arriving tile flickered at \(t)")
            #expect(exit <= lastExit + 1e-9, "a departing tile flickered at \(t)")
            lastEntry = entry
            lastExit = exit
        }
    }

    /// The painter's algorithm is the only thing keeping parents underneath
    /// their children — there is no depth buffer — and departing tiles are
    /// appended after the new ones, so the order has to be restored.
    @Test("Frames come out outermost-first, and in a total order")
    func framesAreOrdered() {
        let deepOld = TreemapIndex(TreemapFixture.layout(levels: [3, 3], generation: 1))
        let deepNew = TreemapIndex(TreemapFixture.layout(levels: [4, 2], generation: 2))
        for t in stride(from: 0.0, through: 0.99, by: 0.05) {
            let frames = TreemapAnimation.frames(from: deepOld, to: deepNew, progress: t)
            let depths = frames.map(\.tile.depth)
            #expect(depths == depths.sorted(), "a child was drawn under its parent at \(t)")
            // Same input, same output, every time — a sort that fell back on
            // array order would shuffle two tiles sharing an origin.
            let again = TreemapAnimation.frames(from: deepOld, to: deepNew, progress: t)
            #expect(frames == again)
        }
    }

    @Test("With no previous layout the frames are simply the current ones")
    func noTransition() {
        let frames = TreemapAnimation.frames(from: nil, to: new, progress: 0.3)
        #expect(frames.count == new.tiles.count)
        #expect(frames.allSatisfy { $0.opacity == 1 })
        #expect(frames.map(\.rect) == new.tiles.map(\.frame))

        // A finished transition is the resting state, whatever it came from.
        let done = TreemapAnimation.frames(from: old, to: new, progress: 1)
        #expect(done.map(\.tile.id) == new.tiles.map(\.id))
    }

    /// Aggregates borrow the `NodeRef` of the largest sibling they swallowed, so
    /// two tiles sharing a ref is not hypothetical. The second must fade in
    /// rather than slide out of the same rectangle as the first.
    @Test("Only one tile can claim a shared node reference")
    func duplicateRefsClaimOnce() {
        let duplicated = TreemapLayout(
            generation: 2, focus: .directory(2), focusPath: "/", breadcrumb: [],
            tiles: (0..<2).map { offset in
                TreemapTile(node: .directory(2),
                            frame: TreemapRect(x: Double(offset) / 2, y: 0, width: 0.5, height: 1),
                            depth: 0, physicalBytes: 1, logicalBytes: 1, itemCount: 1,
                            name: "twin", kind: .real, colorSeed: 0)
            },
            totalPhysicalBytes: 1, totalLogicalBytes: 1,
            scannedAt: Date(timeIntervalSince1970: 0), isComplete: true)
        let frames = TreemapAnimation.frames(from: old, to: TreemapIndex(duplicated), progress: 0.5)
        let full = frames.filter { $0.tile.node == .directory(2) && $0.opacity == 1 }
        #expect(full.count == 1, "both twins slid out of the same rectangle")
    }

    @Test("Reduce Motion means no animation at all")
    func reduceMotion() {
        #expect(TreemapAnimation.animation(reduceMotion: true) == nil)
        #expect(TreemapAnimation.lift(reduceMotion: true) == nil)
        #expect(TreemapAnimation.animation(reduceMotion: false) != nil)
        #expect(TreemapAnimation.lift(reduceMotion: false) != nil)
    }

    /// The two views share a clock by construction rather than by agreement —
    /// `TreemapAnimation` reads `SunburstAnimation`'s numbers rather than
    /// repeating them. What is worth asserting is that whatever those numbers
    /// become, the schedule they describe still makes sense: arrivals hold back,
    /// departures leave early, and the two windows overlap so the transition is
    /// never empty in the middle.
    @Test("The schedule stays coherent whatever the shared clock is tuned to")
    func scheduleIsCoherent() {
        #expect(TreemapAnimation.duration > 0)
        #expect(TreemapAnimation.liftDuration > 0)
        #expect(TreemapAnimation.entryDelay > 0 && TreemapAnimation.entryDelay < 1)
        #expect(TreemapAnimation.exitFraction > 0 && TreemapAnimation.exitFraction <= 1)
        #expect(TreemapAnimation.exitFraction > TreemapAnimation.entryDelay,
                "the fade-out ends before the fade-in starts, leaving a gap in the middle")
        // A tile answers the pointer faster than the disk answers a click.
        #expect(TreemapAnimation.liftDuration < TreemapAnimation.duration)
    }

    // MARK: - The hover lift

    /// The cap is the whole reason this is a function. An outset that reads well
    /// on a quarter of the window buries the neighbours of a twelve-point tile,
    /// and a tile that grew is a lie about area in a chart whose only claim is
    /// that area is size.
    @Test("A small tile lifts less than a large one, and never past its own size")
    func liftIsCapped() {
        let large = CGRect(x: 0, y: 0, width: 300, height: 200)
        let small = CGRect(x: 0, y: 0, width: 12, height: 12)
        #expect(TreemapHoverLift.outset(for: large, progress: 1)
            == TreemapHoverLift.maximumOutset)
        let smallLift = TreemapHoverLift.outset(for: small, progress: 1)
        #expect(smallLift < TreemapHoverLift.maximumOutset)
        #expect(smallLift > 0)

        // Whatever the tile, growing by the lift on both sides must not more
        // than double it — past that the lift is the shape rather than an
        // emphasis on it.
        for edge in stride(from: 1.0, through: 400, by: 1) {
            let rect = CGRect(x: 0, y: 0, width: edge, height: edge)
            let lift = TreemapHoverLift.outset(for: rect, progress: 1)
            #expect(lift * 2 <= edge, "a \(edge)pt tile grew by \(lift * 2)pt")
        }
    }

    @Test("The lift is a fraction of itself part-way through, and nothing at rest")
    func liftFollowsProgress() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(TreemapHoverLift.outset(for: rect, progress: 0) == 0)
        #expect(TreemapHoverLift.outset(for: rect, progress: 0.5)
            == TreemapHoverLift.maximumOutset / 2)
        // Clamped, because an interpolation that overshoots — a spring, say —
        // must not inflate the tile past its cap.
        #expect(TreemapHoverLift.outset(for: rect, progress: 1.4)
            == TreemapHoverLift.maximumOutset)
        #expect(TreemapHoverLift.outset(for: rect, progress: -0.4) == 0)
    }

    /// A `CGRect` standardises a negative extent, so the arithmetic never sees
    /// one — but "never" here is a property of `CGRect`, not of this function,
    /// and it is worth pinning that the lift is non-negative either way. A
    /// negative outset would *shrink* the hovered tile, which is the emphasis
    /// backwards.
    @Test("A degenerate rectangle lifts by nothing rather than by a negative")
    func liftOnNothing() {
        #expect(TreemapHoverLift.outset(for: .zero, progress: 1) == 0)
        #expect(TreemapHoverLift.cornerRadius(for: .zero) == 0)
        #expect(TreemapHoverLift.outset(for: CGRect(x: 0, y: 0, width: -5, height: 10),
                                        progress: 1) >= 0)
        #expect(TreemapHoverLift.cornerRadius(for: CGRect(x: 0, y: 0, width: -5, height: 10)) >= 0)
    }
}
