import CoreGraphics
import Foundation
import LoupeCore

/// Turning wedge geometry into label slots.
///
/// Pure: given an index and metrics it returns where every label *could* go and
/// how much room it has, and `LabelPlacement` decides which of them survive.
/// Nothing here measures text, so the whole of the geometry is testable without
/// a `Canvas`.
public enum SunburstLabels {
    public static let font = LabelFont(size: 10, weight: .medium)

    /// The line box of the 10pt system font, near enough. Budgets have to be
    /// computed before anything is measured, so the width available at a given
    /// rotation is worked out for a nominal line and the real measured height
    /// is checked against the exact geometric limit afterwards.
    /// Deliberately a point taller than the 10pt system font's real line box,
    /// which measures 13pt in a `Canvas`. Budgets have to be worked out before
    /// anything is measured, so they are worked out for a line slightly taller
    /// than the one that will actually be drawn — being wrong in that direction
    /// costs a point of width, being wrong in the other lets a descender out
    /// through the side of a wedge.
    public static let nominalLineHeight: Double = 14

    /// The legibility floor, in points of arc at the wedge's mid radius.
    ///
    /// At 10pt the system font's lowercase advance averages about 5.2pt and the
    /// ellipsis about 3.5pt, so the shortest fragment that still identifies
    /// anything — four characters and an elision — is about 24pt wide. Add a
    /// point of clearance at each end and a wedge narrower than 28pt of arc
    /// cannot hold a readable label in any orientation. Below it we draw
    /// nothing rather than a smear.
    public static let minimumArcLength: Double = 28

    /// The same floor along the baseline, applied after the orientation is
    /// chosen: a radial label in a thin ring can clear the arc floor and still
    /// have nowhere to run.
    public static let minimumLabelWidth: Double = 24

    /// A nominal line plus the clearance kept from each of a ring's two arcs.
    /// Thinner than this and no ring can hold a label at all, so the pass does
    /// not even start.
    public static let minimumRingThickness: Double = nominalLineHeight + edgeInset * 2

    /// The innermost rings read horizontally.
    ///
    /// Their wedges are the widest and the shortest in radius, so a rotated
    /// label there is both unnecessary and hardest to read — the eye tracks a
    /// steeply sloped baseline worst when the text is near the middle of the
    /// chart. Further out, wedges are long and thin and a label that does not
    /// follow the ring simply does not fit.
    public static let horizontalRings: Int = 2

    /// Cosmetic clearance from a wedge's own edges.
    static let edgeInset: Double = 2

    /// How near horizontal a rotated baseline has to be before it is snapped
    /// flat. Roughly 7°, below which the slope reads as a rendering error
    /// rather than as following the ring.
    static let horizontalSnap: Double = 0.12

    /// How many wedges are worth offering to the placement pass. They arrive
    /// largest-first, so everything past this has already lost.
    public static let slotLimit: Int = 120

    // MARK: - Slots

    public static func slots(for index: SunburstIndex, metrics: SunburstMetrics,
                             hovered: SunburstPosition? = nil,
                             keyboardFocus: SunburstPosition? = nil,
                             limit: Int = slotLimit) -> [LabelSlot] {
        var slots: [LabelSlot] = []
        var forced = Set<UInt32>()

        // Hover first, then the keyboard: if the two are on wedges close enough
        // to collide, the one under the pointer is the one being asked about.
        for position in [hovered, keyboardFocus] {
            guard let position, let wedge = index[position] else { continue }
            guard forced.insert(wedge.id).inserted else { continue }
            if let slot = slot(for: wedge, metrics: metrics, isForced: true) { slots.append(slot) }
        }

        guard metrics.ringThickness >= minimumRingThickness, limit > 0 else { return slots }

        var candidates: [Wedge] = []
        candidates.reserveCapacity(min(limit * 2, index.wedges.count))
        for wedge in index.wedges {
            guard !forced.contains(wedge.id) else { continue }
            guard metrics.arcLength(sweep: wedge.sweep, ring: Int(wedge.ring)) >= minimumArcLength
            else { continue }
            candidates.append(wedge)
        }
        // Sweep is proportional to bytes, so "biggest wedge" and "biggest thing
        // on this volume" are the same ordering. Ties break inward, then by id,
        // so the chart labels the same wedges on every run.
        candidates.sort { a, b in
            if a.sweep != b.sweep { return a.sweep > b.sweep }
            if a.ring != b.ring { return a.ring < b.ring }
            return a.id < b.id
        }
        for wedge in candidates.prefix(limit) {
            if let slot = slot(for: wedge, metrics: metrics, isForced: false) { slots.append(slot) }
        }
        return slots
    }

    // MARK: - One wedge

    /// Does a line of `width` × `height` at baseline rotation `delta` (measured
    /// from the wedge's mid ray) lie wholly inside the wedge?
    ///
    /// Three conditions, and all three are exact rather than approximate:
    ///
    /// * the outer corners stay inside the ring's outer arc,
    /// * the inner edge stays outside the ring's inner arc,
    /// * the inner corners stay inside the wedge's two radial edges — the inner
    ///   corners because that is where a straight box strays furthest in angle:
    ///   the same sideways offset subtends a wider angle the closer to the
    ///   centre it sits.
    ///
    /// The last one is what a naive "arc length at the mid radius" budget gets
    /// wrong, and it is why long names in the screenshot ran out through the
    /// ends of their own wedges.
    static func fits(width: Double, height: Double, cosDelta: Double, sinDelta: Double,
                     midRadius: Double, innerLimit: Double, outerLimit: Double,
                     tangentOfHalfSweep: Double) -> Bool {
        guard width >= 0, height >= 0 else { return false }
        // Half-extents of the box in the wedge's own frame.
        let radial = width / 2 * cosDelta + height / 2 * sinDelta
        let across = width / 2 * sinDelta + height / 2 * cosDelta

        let innerRadius = midRadius - radial
        guard innerRadius >= innerLimit else { return false }

        let far = midRadius + radial
        guard far * far + across * across <= outerLimit * outerLimit else { return false }

        // A negative tangent stands for "no angular limit": a wedge sweeping a
        // half turn or more is bounded by the arcs alone.
        guard tangentOfHalfSweep < 0 || across <= innerRadius * tangentOfHalfSweep else { return false }
        return true
    }

    /// The longest line of `height` at rotation `delta` that `fits`.
    ///
    /// Bisection, because the outer corner's radius is a square root of the
    /// width rather than a linear function of it. A linear budget — the
    /// straightened box that "arc length × ring thickness" assumes — is exactly
    /// the approximation that lets a label escape its wedge, so it is not used.
    /// Sixteen halvings resolve the answer to a hundredth of a point, and the
    /// early-out means most wedges cost one evaluation.
    static func fittedWidth(rotation delta: Double, height: Double,
                            midRadius: Double, innerLimit: Double, outerLimit: Double,
                            tangentOfHalfSweep: Double,
                            floor: Double = minimumLabelWidth) -> Double {
        let cosDelta = abs(cos(delta)), sinDelta = abs(sin(delta))
        func fits(_ width: Double) -> Bool {
            Self.fits(width: width, height: height, cosDelta: cosDelta, sinDelta: sinDelta,
                      midRadius: midRadius, innerLimit: innerLimit, outerLimit: outerLimit,
                      tangentOfHalfSweep: tangentOfHalfSweep)
        }
        guard fits(floor) else { return 0 }
        var low = floor
        var high = outerLimit * 2
        guard !fits(high) else { return high }
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
    }

    /// The tallest line that fits at `delta` with no width at all. This is the
    /// bound truncation cannot recover, so it is what a measured line's height
    /// is checked against.
    static func fittedHeight(rotation delta: Double,
                             midRadius: Double, innerLimit: Double, outerLimit: Double,
                             tangentOfHalfSweep: Double) -> Double {
        let cosDelta = abs(cos(delta)), sinDelta = abs(sin(delta))
        func fits(_ height: Double) -> Bool {
            Self.fits(width: 0, height: height, cosDelta: cosDelta, sinDelta: sinDelta,
                      midRadius: midRadius, innerLimit: innerLimit, outerLimit: outerLimit,
                      tangentOfHalfSweep: tangentOfHalfSweep)
        }
        guard fits(0) else { return 0 }
        var low = 0.0
        var high = outerLimit * 2
        guard !fits(high) else { return high }
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
    }

    /// Turn a baseline the right way up. A box rotated by ψ and by ψ+π occupies
    /// the same space, so this changes nothing about collisions — it only stops
    /// the left half of the chart being written upside down.
    static func upright(_ rotation: Double) -> Double {
        var result = rotation.truncatingRemainder(dividingBy: SunburstAngle.fullTurn)
        if result <= -.pi { result += SunburstAngle.fullTurn }
        if result > .pi { result -= SunburstAngle.fullTurn }
        if result > .pi / 2 { result -= .pi }
        if result < -.pi / 2 { result += .pi }
        return abs(result) < horizontalSnap ? 0 : result
    }

    /// Where a flat label may be anchored, in order of preference.
    ///
    /// A ring's tangent is horizontal at 12 and 6 o'clock. A wide wedge whose
    /// mid ray happens to point at 3 o'clock has plenty of room for a
    /// horizontal name — just not at its own midpoint, where a flat label runs
    /// radially and is squeezed into the ring's thickness. Anchoring it where
    /// the ring is already horizontal is what lets the innermost rings read
    /// flat without giving up most of their width to do it.
    static func flatAnchors(for wedge: Wedge) -> [Double] {
        let mid = wedge.startAngle + wedge.sweep / 2
        var angles = [mid]
        for candidate in [0.0, Double.pi] {
            let lifted = SunburstAngle.lifted(candidate, into: wedge.startAngle)
            // Strictly interior, and far enough in that there is room on both
            // sides — an anchor on a wedge's own edge has no half-angle at all.
            let margin = wedge.sweep * 0.15
            if lifted > wedge.startAngle + margin, lifted < wedge.endAngle - margin {
                angles.append(lifted)
            }
        }
        return angles
    }

    static func slot(for wedge: Wedge, metrics: SunburstMetrics, isForced: Bool) -> LabelSlot? {
        let ring = Int(wedge.ring)
        let text = SunburstDescription.chartLabel(for: wedge)
        guard !text.isEmpty else { return nil }

        let radii = metrics.radii(forRing: ring)
        let midRadius = metrics.midRadius(forRing: ring)
        let innerLimit = radii.inner + edgeInset
        let outerLimit = max(0, radii.outer - edgeInset)
        let mid = wedge.startAngle + wedge.sweep / 2
        let floor = isForced ? 1.0 : minimumLabelWidth

        /// The angular room either side of an anchor. Symmetric only when the
        /// anchor is the wedge's own midpoint.
        func halfAngle(at anchorAngle: Double) -> Double {
            min(anchorAngle - wedge.startAngle, wedge.endAngle - anchorAngle)
        }

        func tangent(at anchorAngle: Double) -> Double {
            let half = halfAngle(at: anchorAngle)
            // Negative stands for "no angular limit"; see `fits`.
            return half >= .pi / 2 - 1e-6 ? -1 : tan(max(0, half))
        }

        func width(anchorAngle: Double, rotation: Double) -> Double {
            fittedWidth(rotation: rotation - (anchorAngle - .pi / 2), height: nominalLineHeight,
                        midRadius: midRadius, innerLimit: innerLimit, outerLimit: outerLimit,
                        tangentOfHalfSweep: tangent(at: anchorAngle), floor: floor)
        }

        // Two orientations are ever worth considering at a wedge's midpoint:
        // along the ring, and across it. Everything else is a worse fit for an
        // annular sector.
        let radialAxis = mid - .pi / 2
        let along = upright(radialAxis + .pi / 2)
        let across = upright(radialAxis)
        let alongWidth = width(anchorAngle: mid, rotation: along)
        let acrossWidth = width(anchorAngle: mid, rotation: across)

        var anchorAngle = mid
        var rotation = alongWidth >= acrossWidth ? along : across
        var widthBudget = max(alongWidth, acrossWidth)

        if ring < horizontalRings {
            // The innermost rings read flat. Their wedges are the widest and the
            // shortest in radius, and the eye tracks a steeply sloped baseline
            // worst near the middle of the chart.
            var bestFlat = 0.0
            var bestAnchor = mid
            for candidate in flatAnchors(for: wedge) {
                let flat = width(anchorAngle: candidate, rotation: 0)
                if flat > bestFlat {
                    bestFlat = flat
                    bestAnchor = candidate
                }
            }
            if bestFlat >= minimumLabelWidth {
                anchorAngle = bestAnchor
                rotation = 0
                widthBudget = bestFlat
            }
        }

        let heightBudget = fittedHeight(rotation: rotation - (anchorAngle - .pi / 2),
                                        midRadius: midRadius, innerLimit: innerLimit,
                                        outerLimit: outerLimit,
                                        tangentOfHalfSweep: tangent(at: anchorAngle))

        if !isForced {
            guard widthBudget >= minimumLabelWidth, heightBudget >= nominalLineHeight else { return nil }
        }
        return LabelSlot(id: wedge.id, text: text,
                         anchor: metrics.point(radius: midRadius, angle: anchorAngle),
                         rotation: rotation,
                         widthBudget: widthBudget, heightBudget: heightBudget,
                         priority: wedge.sweep, isForced: isForced)
    }
}
