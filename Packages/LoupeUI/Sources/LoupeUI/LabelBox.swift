import CoreGraphics
import Foundation

/// An oriented rectangle: where a label will land on screen, and how it is turned.
///
/// Sunburst labels are rotated to follow their ring, so an axis-aligned box is
/// not good enough to answer "do these two collide". The axis-aligned bounds of
/// a 90pt name rotated 45° are nearly square and cover roughly twice the area
/// the text actually occupies; rejecting on that would throw away most of the
/// labels that genuinely fit, which is how a collision pass degenerates into
/// "no labels at all". So the test is a proper separating-axis test on the
/// rotated rectangles.
public struct LabelBox: Sendable, Hashable {
    public let center: CGPoint
    public let size: CGSize
    /// Radians in screen space. Canvas' y axis points down, so a positive
    /// rotation turns clockwise — the same sense as the contract's angles.
    public let rotation: Double

    public init(center: CGPoint, size: CGSize, rotation: Double = 0) {
        self.center = center
        self.size = CGSize(width: max(0, size.width), height: max(0, size.height))
        self.rotation = rotation
    }

    /// The box grown by `amount` on every side. Used to keep a hair of clear
    /// space between accepted labels: two names that merely touch are as hard
    /// to read as two that overlap by a pixel.
    public func inflated(by amount: Double) -> LabelBox {
        LabelBox(center: center,
                 size: CGSize(width: size.width + amount * 2, height: size.height + amount * 2),
                 rotation: rotation)
    }

    /// Unit vector along the text's baseline.
    @inline(__always)
    var alongText: CGPoint { CGPoint(x: cos(rotation), y: sin(rotation)) }
    /// Unit vector across it.
    @inline(__always)
    var acrossText: CGPoint { CGPoint(x: -sin(rotation), y: cos(rotation)) }

    public var corners: [CGPoint] {
        let a = alongText, b = acrossText
        let hw = size.width / 2, hh = size.height / 2
        return [
            CGPoint(x: center.x + a.x * hw + b.x * hh, y: center.y + a.y * hw + b.y * hh),
            CGPoint(x: center.x + a.x * hw - b.x * hh, y: center.y + a.y * hw - b.y * hh),
            CGPoint(x: center.x - a.x * hw - b.x * hh, y: center.y - a.y * hw - b.y * hh),
            CGPoint(x: center.x - a.x * hw + b.x * hh, y: center.y - a.y * hw + b.y * hh),
        ]
    }

    /// Axis-aligned bounds. Only for coarse culling and for tests — never for
    /// the collision decision itself, for the reason in the type's doc comment.
    public var boundingRect: CGRect {
        let points = corners
        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Half the box's shadow on `axis`, which must be a unit vector.
    @inline(__always)
    func halfExtent(along axis: CGPoint) -> Double {
        let a = alongText, b = acrossText
        return abs(a.x * axis.x + a.y * axis.y) * size.width / 2
            + abs(b.x * axis.x + b.y * axis.y) * size.height / 2
    }

    /// Separating-axis test. Two convex rectangles are disjoint if and only if
    /// one of their four edge normals separates them, so four probes decide it
    /// exactly — no sampling, no bounding-box slop.
    ///
    /// Touching counts as disjoint: labels are inflated by a padding before
    /// they are tested, so an exact edge share already has clear space in it.
    public func intersects(_ other: LabelBox) -> Bool {
        if size.width <= 0 || size.height <= 0 || other.size.width <= 0 || other.size.height <= 0 {
            return false
        }
        // Axis-aligned fast path. Treemap labels and the innermost sunburst ring
        // are both unrotated, and this is the inner loop of the collision pass.
        if abs(rotation) < 1e-9, abs(other.rotation) < 1e-9 {
            return abs(center.x - other.center.x) * 2 < size.width + other.size.width
                && abs(center.y - other.center.y) * 2 < size.height + other.size.height
        }
        let dx = other.center.x - center.x
        let dy = other.center.y - center.y
        for axis in [alongText, acrossText, other.alongText, other.acrossText] {
            let distance = abs(dx * axis.x + dy * axis.y)
            if distance >= halfExtent(along: axis) + other.halfExtent(along: axis) { return false }
        }
        return true
    }
}
