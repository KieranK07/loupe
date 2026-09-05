import CoreGraphics
import Foundation
import LoupeCore

/// Where the rings actually sit on screen.
///
/// Deliberately a plain value with no view attached, so hit testing, navigation
/// and the tests can all reason about the same geometry the renderer draws.
public struct SunburstMetrics: Sendable, Equatable {
    public let center: CGPoint
    /// Radius of the centre disc. Ring 0 begins here.
    public let centreRadius: Double
    public let ringThickness: Double
    public let ringCount: Int

    /// Beyond this there is nothing to hit.
    public var outerRadius: Double { centreRadius + ringThickness * Double(ringCount) }

    public init(center: CGPoint, centreRadius: Double, ringThickness: Double, ringCount: Int) {
        self.center = center
        self.centreRadius = max(0, centreRadius)
        self.ringThickness = max(0, ringThickness)
        self.ringCount = max(0, ringCount)
    }

    /// Fit `ringCount` rings into `size`.
    ///
    /// Ring thickness is capped rather than allowed to expand to fill: a layout
    /// with two rings should read as a chart with a large label in the middle,
    /// not as one enormous doughnut. Whatever the cap leaves over goes to the
    /// centre disc, which is where the focus node's name and total live anyway.
    public init(size: CGSize, ringCount: Int, inset: Double = 16,
                minimumCentreFraction: Double = 0.26, maximumRingThickness: Double = 68) {
        let outer = max(0, min(size.width, size.height) / 2 - inset)
        let rings = max(0, ringCount)
        let budget = outer * (1 - minimumCentreFraction)
        let thickness = rings == 0 ? 0 : min(budget / Double(rings), maximumRingThickness)
        self.init(center: CGPoint(x: size.width / 2, y: size.height / 2),
                  centreRadius: outer - thickness * Double(rings),
                  ringThickness: thickness,
                  ringCount: rings)
    }

    /// Inner and outer radius of one ring's *hit* annulus.
    ///
    /// The renderer insets these slightly to draw a hairline between rings; hit
    /// testing deliberately does not, because a cosmetic gap you can fall into
    /// is a chart that ignores your clicks.
    public func radii(forRing ring: Int) -> (inner: Double, outer: Double) {
        let inner = centreRadius + ringThickness * Double(ring)
        return (inner, inner + ringThickness)
    }

    public func midRadius(forRing ring: Int) -> Double {
        centreRadius + ringThickness * (Double(ring) + 0.5)
    }

    /// Fractional rings exist so a wedge can migrate between rings mid-zoom.
    public func radii(forRingPosition ring: Double) -> (inner: Double, outer: Double) {
        let inner = centreRadius + ringThickness * ring
        return (inner, inner + ringThickness)
    }

    /// Which ring a radius falls in, or nil for the centre disc and for
    /// anything past the outermost ring.
    public func ring(atRadius radius: Double) -> Int? {
        guard ringThickness > 0, radius >= centreRadius, radius < outerRadius else { return nil }
        let ring = Int((radius - centreRadius) / ringThickness)
        // Guard against the ulp that lets `radius < outerRadius` and
        // `ring == ringCount` be true at the same time.
        return min(ring, ringCount - 1)
    }

    public func radius(at point: CGPoint) -> Double {
        let dx = point.x - center.x, dy = point.y - center.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Screen point to contract angle: radians clockwise from 12 o'clock.
    ///
    /// `atan2` measures anticlockwise from 3 o'clock in maths convention, but
    /// Canvas's y axis points *down*, which mirrors it into a clockwise sweep
    /// for free. All that is left is to move the origin from 3 to 12 o'clock.
    public func angle(at point: CGPoint) -> Double {
        let dx = point.x - center.x, dy = point.y - center.y
        return SunburstAngle.normalized(atan2(dy, dx) + .pi / 2)
    }

    public func point(radius: Double, angle: Double) -> CGPoint {
        let screen = angle - .pi / 2
        return CGPoint(x: center.x + radius * cos(screen), y: center.y + radius * sin(screen))
    }

    /// The largest camera scale — anchored at the centre disc's edge, the way
    /// `SunburstChart` applies it — that still keeps the outermost ring inside
    /// the view.
    ///
    /// A camera above 1 pushes the rim outward, and the only room it has is the
    /// `inset` the metrics left. That is a fixed number of points, so the *ratio*
    /// it buys shrinks as the chart grows: the same 1.10 that costs 4 pt of
    /// clipping on a shallow 800 pt chart costs 38 pt on a 2000 pt one. A fixed
    /// start scale therefore cannot be safe on its own, and this is the bound
    /// that makes it safe.
    ///
    /// Never less than 1: a camera that pulls the rings *in* is unbounded — it
    /// has the whole hole to shrink into — so this only ever caps the push out.
    public var maximumCameraScale: Double {
        // The metrics are built from the view's own size, so the half-extent is
        // the smaller of the centre's two coordinates.
        let room = min(center.x, center.y)
        let span = outerRadius - centreRadius
        guard span > 0 else { return 1 }
        return max(1, (room - centreRadius) / span)
    }

    /// Arc length a wedge occupies at its mid radius — the honest measure of
    /// "is this big enough to be worth drawing a label in".
    public func arcLength(sweep: Double, ring: Int) -> Double {
        sweep * midRadius(forRing: ring)
    }
}
