import Foundation

/// Angle arithmetic for the sunburst, kept in one place because every subtle bug
/// this view can have lives at the 0 / 2π seam.
///
/// The contract's convention (`SunburstContract.swift`): angles are radians,
/// clockwise from 12 o'clock, and a wedge always has `endAngle > startAngle`.
/// A wedge therefore never wraps *itself*, but a ring's last wedge is free to
/// end past 2π, so probe angles have to be lifted rather than compared raw.
public enum SunburstAngle {
    public static let fullTurn: Double = 2 * .pi

    /// How much slack containment tests allow. The projector accumulates a
    /// ring's angles by repeated addition, so a child's edge can miss its
    /// parent's by a few ulps. This is ~7 orders of magnitude below
    /// `SunburstGeometry.minimumSweepRadians`, so it can never merge two real
    /// wedges — it only forgives arithmetic dust.
    public static let containmentTolerance: Double = 1e-9

    /// Fold an arbitrary angle into `[0, 2π)`.
    @inlinable
    public static func normalized(_ angle: Double) -> Double {
        var r = angle.truncatingRemainder(dividingBy: fullTurn)
        if r < 0 { r += fullTurn }
        // For a tiny negative input, `r + fullTurn` rounds to *exactly* fullTurn
        // in double precision. Left alone, a cursor a hair anticlockwise of 12
        // o'clock would normalise to 2π and fall outside every wedge in the
        // ring — the wedge under the pointer at the top of the chart would be
        // wrong. Fold that case onto zero so the range stays half-open.
        if r >= fullTurn { r = 0 }
        return r
    }

    /// `angle` shifted by whole turns so it lands in `[base, base + 2π)`.
    ///
    /// This is how the seam stops mattering: put both angles in the same frame
    /// first, then compare them like ordinary numbers.
    @inlinable
    public static func lifted(_ angle: Double, into base: Double) -> Double {
        base + normalized(angle - base)
    }

    /// True when `angle` lies in the half-open span `[start, end)`, seam included.
    ///
    /// Half-open is deliberate and load-bearing: a point exactly on a shared
    /// edge belongs to the wedge that *starts* there, so adjacent wedges tile
    /// the ring with no point owned twice and none owned by nobody.
    @inlinable
    public static func span(_ start: Double, _ end: Double, contains angle: Double) -> Bool {
        let lifted = lifted(angle, into: start)
        return lifted < end
    }

    /// Signed shortest way round from `a` to `b`, in `(-π, π]`.
    ///
    /// Used when animating: a wedge that moves from 6.2 rad to 0.05 rad has
    /// barely moved on screen, and interpolating the raw numbers would spin it
    /// almost all the way round the wrong way.
    @inlinable
    public static func shortestDelta(from a: Double, to b: Double) -> Double {
        let d = normalized(b - a)
        return d > .pi ? d - fullTurn : d
    }
}
