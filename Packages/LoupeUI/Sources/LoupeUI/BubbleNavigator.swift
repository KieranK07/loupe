import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI

/// Keyboard movement over a circle pack, computed from geometry alone.
///
/// The same rules as `TreemapNavigator`, deliberately: the four arrows are
/// spatial and stay on the level you are already on, and the two moves that
/// change level ride on Option. A user learns the arrows once and all three
/// charts obey them.
public struct BubbleNavigator: Sendable {
    public enum Move: Sendable, Hashable, CaseIterable {
        case left, right, up, down
        /// Into the largest circle nested inside this one.
        case deeper
        /// Back out to the circle this one sits inside.
        case shallower
    }

    public let index: BubbleIndex

    /// How much a candidate is penalised for not lining up with the circle you
    /// are leaving. Three is enough that a circle straight across a wide gap
    /// still beats a nearer one in the next row up, which is what the eye does.
    /// The same weight `TreemapNavigator` uses, so the two feel identical.
    static let strayWeight: Double = 3
    static let alignmentWeight: Double = 0.25

    public init(index: BubbleIndex) {
        self.index = index
    }

    /// Where the keyboard lands when the chart is focused with nothing selected:
    /// the biggest thing at the outermost level, which is where the eye already
    /// is.
    public func initialFocus() -> BubblePosition? {
        for depth in 0..<index.depthCount {
            if let position = largest(atDepth: depth) { return position }
        }
        return nil
    }

    public func largest(atDepth depth: Int) -> BubblePosition? {
        guard index.depthRanges.indices.contains(depth) else { return nil }
        let range = index.depthRanges[depth]
        guard !range.isEmpty else { return nil }
        var best = range.lowerBound
        for i in range where index.circles[i].radius > index.circles[best].radius { best = i }
        return BubblePosition(depth: depth, offset: best - range.lowerBound)
    }

    public func destination(from position: BubblePosition, move: Move) -> BubblePosition? {
        switch move {
        case .deeper: largestChild(of: position)
        case .shallower: index.parent(of: position)
        default: nearest(from: position, move: move)
        }
    }

    public func largestChild(of position: BubblePosition) -> BubblePosition? {
        guard let parent = index.circleIndex(of: position) else { return nil }
        let depth = position.depth + 1
        guard index.depthRanges.indices.contains(depth) else { return nil }
        var best: Int?
        for i in index.depthRanges[depth] where index.parentIndex(of: i) == parent {
            if best == nil || index.circles[i].radius > index.circles[best!].radius { best = i }
        }
        return best.flatMap { index.position(at: $0) }
    }

    /// Nearest circle at the same depth in the given direction.
    ///
    /// Scored on two numbers: how far it is along the direction of travel, and
    /// how far it strays across it. The stray term is a *gap* between the two
    /// circles' spans, not a difference of centres — a tall neighbour whose span
    /// still overlaps the circle you are leaving counts as straight ahead,
    /// however far its middle is from yours.
    ///
    /// No aspect ratio, unlike the treemap: a bubble layout is drawn into a
    /// centred square whatever shape the window is, so normalised distance is
    /// already screen distance and correcting for the window would make the
    /// arrows wrong rather than right.
    private func nearest(from position: BubblePosition, move: Move) -> BubblePosition? {
        guard let currentIndex = index.circleIndex(of: position) else { return nil }
        let current = index.circles[currentIndex]
        let range = index.depthRanges[position.depth]
        let horizontal = move == .left || move == .right

        var bestScore = Double.greatestFiniteMagnitude
        var best: Int?
        for i in range where i != currentIndex {
            let circle = index.circles[i]
            let travelled: Double
            let stray: Double
            let drift: Double
            if horizontal {
                travelled = move == .right ? circle.centerX - current.centerX
                                           : current.centerX - circle.centerX
                stray = gap(current.centerY, current.radius, circle.centerY, circle.radius)
                drift = abs(circle.centerY - current.centerY)
            } else {
                travelled = move == .down ? circle.centerY - current.centerY
                                          : current.centerY - circle.centerY
                stray = gap(current.centerX, current.radius, circle.centerX, circle.radius)
                drift = abs(circle.centerX - current.centerX)
            }
            // Strictly in the direction asked for. A circle whose middle is level
            // with yours is not "to the left" of anything.
            guard travelled > 1e-9 else { continue }

            let score = travelled + Self.strayWeight * stray + Self.alignmentWeight * drift
            // Ties break towards the earlier circle so the same keypress always
            // goes the same way.
            if score < bestScore {
                bestScore = score
                best = i
            }
        }
        return best.flatMap { index.position(at: $0) }
    }

    /// Clear distance between two spans on one axis; zero when they overlap.
    @inline(__always)
    private func gap(_ a: Double, _ ar: Double, _ b: Double, _ br: Double) -> Double {
        max(0, abs(a - b) - ar - br)
    }

    /// The chain from this circle outwards. Used to light up the ancestry on
    /// hover, which is what makes a deep pack readable.
    public func ancestors(of position: BubblePosition) -> [BubblePosition] {
        var chain: [BubblePosition] = []
        var current = position
        while let next = index.parent(of: current), chain.count <= index.depthCount {
            chain.append(next)
            current = next
        }
        return chain
    }
}

// MARK: - The zoom

/// A similarity transform: one uniform scale and a translation.
///
/// Uniform because a circle scaled differently on the two axes is an ellipse,
/// and because the whole zoom below only works if the two layouts are related by
/// a transform of exactly this shape.
public struct BubbleTransform: Sendable, Hashable {
    public let scale: Double
    public let offsetX: Double
    public let offsetY: Double

    public static let identity = BubbleTransform(scale: 1, offsetX: 0, offsetY: 0)

    public init(scale: Double, offsetX: Double, offsetY: Double) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    @inline(__always) public func x(_ value: Double) -> Double { scale * value + offsetX }
    @inline(__always) public func y(_ value: Double) -> Double { scale * value + offsetY }
    @inline(__always) public func length(_ value: Double) -> Double { scale * value }

    /// This transform followed by `outer`.
    public func then(_ outer: BubbleTransform) -> BubbleTransform {
        BubbleTransform(scale: outer.scale * scale,
                        offsetX: outer.scale * offsetX + outer.offsetX,
                        offsetY: outer.scale * offsetY + outer.offsetY)
    }

    public var inverted: BubbleTransform? {
        guard scale != 0, scale.isFinite else { return nil }
        return BubbleTransform(scale: 1 / scale, offsetX: -offsetX / scale, offsetY: -offsetY / scale)
    }
}

/// One circle, mid-zoom, already projected into the coordinates the renderer
/// draws in.
///
/// `depth` is carried as a `Double` only so departing circles can be ordered
/// beneath arriving ones; it is not fractional the way `SunburstFrame.ring` is,
/// because a bubble does not migrate between levels — the whole layout moves
/// under one transform instead.
public struct BubbleFrame: Sendable, Hashable {
    public let circle: BubbleCircle
    public let centerX: Double
    public let centerY: Double
    public let radius: Double
    public let opacity: Double

    public init(circle: BubbleCircle, centerX: Double, centerY: Double,
                radius: Double, opacity: Double) {
        self.circle = circle
        self.centerX = centerX
        self.centerY = centerY
        self.radius = radius
        self.opacity = opacity
    }

    /// A circle that is not moving. Building one of these is free, which matters
    /// because the steady state draws thousands of them per frame.
    public init(resting circle: BubbleCircle) {
        self.init(circle: circle, centerX: circle.centerX, centerY: circle.centerY,
                  radius: circle.radius, opacity: 1)
    }

    public func transformed(by transform: BubbleTransform, opacity: Double) -> BubbleFrame {
        BubbleFrame(circle: circle,
                    centerX: transform.x(centerX), centerY: transform.y(centerY),
                    radius: transform.length(radius), opacity: opacity)
    }
}

/// The zoom transition, as pure arithmetic.
///
/// ## Why this is not the sunburst's animation
///
/// `SunburstAnimation` matches wedges by id and interpolates each one's geometry
/// separately, because a wedge that survives a zoom genuinely changes shape —
/// it changes ring and it changes sweep. A circle pack is different, and better:
/// zooming into a circle re-lays its subtree out inside the whole container, and
/// **the packing is scale invariant**, so the new layout is the old subtree
/// under one similarity transform. Every survivor is therefore in the right
/// place already; the whole transition is one transform interpolated from
/// "the new layout drawn inside the circle you clicked" to "the new layout
/// filling the chart", with the old layout carried along under the same
/// transform composed with the relation between them.
///
/// That is what makes it feel like falling in rather than like a cross-fade:
/// nothing slides relative to anything else, the camera moves. Matching
/// circle-by-circle would produce the same picture at both ends and a soup of
/// independently drifting discs in between.
///
/// The transform is exact for the geometry and only approximate for the
/// *contents*: the sibling padding and the radius floor are both absolute
/// fractions of the container, so a subtree drawn ten times bigger admits more
/// children and separates them slightly differently. Those arrive as new circles
/// and fade in; they are the "bloom" from inside.
public enum BubbleAnimation {
    /// A touch longer than the sunburst's 0.34. The camera travels much further
    /// here — often a tenfold change of scale — and the same duration reads as a
    /// jump cut rather than as a move.
    public static let duration: Double = 0.42

    /// Arriving circles hold back until the camera is most of the way there, so
    /// the new level does not appear on top of geometry that is still moving.
    public static let entryDelay: Double = 0.45
    /// Departing circles leave early for the same reason, in reverse.
    public static let exitFraction: Double = 0.55

    public static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }

    /// The similarity that carries **old layout coordinates into new ones**, or
    /// nil when the two layouts are not related by a zoom at all — a different
    /// volume, or a focus that vanished.
    ///
    /// Zooming in, the new focus was a circle in the old layout and that circle
    /// becomes the whole container. Zooming out, the old focus is a circle in
    /// the new one and the whole old container becomes it. Those are the same
    /// relation read in the two directions, which is why one function answers
    /// both and why the transition below needs no idea which way it is going.
    public static func relation(from old: BubbleIndex, to new: BubbleIndex) -> BubbleTransform? {
        if new.focus != old.focus, new.focus.isValid,
           let position = old.position(ofNode: new.focus), let circle = old[position],
           circle.radius > 0 {
            // Old ↦ new is the inverse of "the whole new container sits where
            // this circle was".
            let scale = 1 / (2 * circle.radius)
            return BubbleTransform(scale: scale,
                                   offsetX: 0.5 - circle.centerX * scale,
                                   offsetY: 0.5 - circle.centerY * scale)
        }
        if new.focus != old.focus, old.focus.isValid,
           let position = new.position(ofNode: old.focus), let circle = new[position],
           circle.radius > 0 {
            let scale = 2 * circle.radius
            return BubbleTransform(scale: scale,
                                   offsetX: circle.centerX - circle.radius,
                                   offsetY: circle.centerY - circle.radius)
        }
        return nil
    }

    /// Where the new layout is drawn at `progress`.
    ///
    /// The scale is interpolated **geometrically** and the centre linearly. A
    /// linear scale looks wrong over the tenfold changes this chart makes: it
    /// spends most of the transition crawling through the last few percent of
    /// the zoom and then snaps. Geometric interpolation is constant *relative*
    /// speed, which is what the eye reads as a steady approach.
    public static func viewTransform(relation: BubbleTransform, progress: Double) -> BubbleTransform {
        let t = min(max(progress, 0), 1)
        guard let start = relation.inverted, start.scale > 0, start.scale.isFinite else {
            return .identity
        }
        let scale = pow(start.scale, 1 - t)
        let startX = start.x(0.5), startY = start.y(0.5)
        let centreX = startX + (0.5 - startX) * t
        let centreY = startY + (0.5 - startY) * t
        return BubbleTransform(scale: scale,
                               offsetX: centreX - scale * 0.5,
                               offsetY: centreY - scale * 0.5)
    }

    /// Every circle to draw at `progress`, departing ones first so they stay
    /// underneath, then the arriving layout shallowest-first.
    ///
    /// `progress == 1` with no `from` is the steady state; callers should skip
    /// this entirely there and iterate the index directly, because this
    /// allocates and the steady state is the per-frame path.
    public static func frames(from old: BubbleIndex?, to new: BubbleIndex,
                              progress: Double) -> [BubbleFrame] {
        let t = min(max(progress, 0), 1)
        guard let old, t < 1 else { return new.circles.map(BubbleFrame.init(resting:)) }

        let relation = relation(from: old, to: new)
        let newTransform = relation.map { viewTransform(relation: $0, progress: t) } ?? .identity
        // The old layout rides the same camera, composed with the relation
        // between the two layouts — which is what guarantees a survivor lands in
        // exactly the same place under both transforms and never has to be
        // interpolated by hand.
        let oldTransform = relation.map { $0.then(newTransform) } ?? .identity

        let entryOpacity = t <= entryDelay ? 0 : (t - entryDelay) / (1 - entryDelay)
        let exitOpacity = t >= exitFraction ? 0 : 1 - t / exitFraction

        var survivors = Set<UInt32>()
        survivors.reserveCapacity(new.circles.count)
        var arriving: [BubbleFrame] = []
        arriving.reserveCapacity(new.circles.count)

        for circle in new.circles {
            // Only a valid, not-yet-claimed `NodeRef` identifies a survivor. The
            // contract promises refs are distinct, so this normally matches
            // everything that survived; the claim check is here so that if two
            // circles ever did share a ref they would not both be drawn opaque
            // in the same place — the second fades in instead, which is at worst
            // dull.
            let survived = circle.node.isValid
                && old.position(ofNode: circle.node) != nil
                && survivors.insert(circle.id).inserted
            arriving.append(BubbleFrame(resting: circle)
                .transformed(by: newTransform, opacity: survived ? 1 : entryOpacity))
        }

        guard exitOpacity > 0 else { return arriving }

        var departing: [BubbleFrame] = []
        for circle in old.circles where !(circle.node.isValid && survivors.contains(circle.id)) {
            departing.append(BubbleFrame(resting: circle)
                .transformed(by: oldTransform, opacity: exitOpacity))
        }
        // Departing circles come out of `old.circles`, which is already
        // shallowest-first, so appending the arriving layout after them is the
        // whole of the painter's ordering: what is leaving sits underneath what
        // is arriving.
        departing.append(contentsOf: arriving)
        return departing
    }
}
