import CoreGraphics
import Foundation
import LoupeCore

/// A circle's address: which depth, and how far along that depth.
///
/// The bubble chart's counterpart of `SunburstPosition` and `TreemapPosition`,
/// and for the same reason — hover and keyboard focus are tracked by position
/// rather than by id, because "the circle to the left of this one" is an offset,
/// not an identity.
public struct BubblePosition: Sendable, Hashable {
    public let depth: Int
    public let offset: Int

    public init(depth: Int, offset: Int) {
        self.depth = depth
        self.offset = offset
    }
}

public enum BubbleHit: Sendable, Hashable {
    case circle(BubblePosition)
    /// Inside the chart but on no circle. The zoom-out target, so a
    /// pointer-only user has the same way back out that the sunburst's centre
    /// disc and the treemap's margin give them.
    case background
    /// Outside the chart entirely.
    case none
}

/// Where the pack sits on screen.
///
/// `BubbleCircle` is normalised and, unlike a treemap rect, it is normalised
/// against the container's **smaller side** — a circle scaled by width on one
/// axis and height on the other is an ellipse. So this is the only place that
/// knows how large the view is, and the only place that knows the pack is drawn
/// into a centred square rather than into the whole of it.
public struct BubbleMetrics: Sendable, Equatable {
    /// Everything the chart may draw in, and everything a click counts as being
    /// "in the chart" for.
    public let bounds: CGRect
    /// The centred square the unit box maps onto.
    public let square: CGRect

    public init(bounds: CGRect) {
        let rect = CGRect(x: bounds.minX, y: bounds.minY,
                          width: max(0, bounds.width), height: max(0, bounds.height))
        self.bounds = rect
        let side = min(rect.width, rect.height)
        square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                        width: side, height: side)
    }

    public init(size: CGSize, inset: Double = 12) {
        let width = max(0, size.width - inset * 2)
        let height = max(0, size.height - inset * 2)
        self.init(bounds: CGRect(x: inset, y: inset, width: width, height: height))
    }

    public var side: Double { square.width }
    public var isDegenerate: Bool { side <= 0 }

    public func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: square.minX + x * side, y: square.minY + y * side)
    }

    public func length(_ value: Double) -> Double { value * side }

    public func center(of circle: BubbleCircle) -> CGPoint {
        point(x: circle.centerX, y: circle.centerY)
    }

    public func radius(of circle: BubbleCircle) -> Double { length(circle.radius) }

    public func rect(of circle: BubbleCircle) -> CGRect {
        let centre = center(of: circle)
        let r = radius(of: circle)
        return CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
    }

    /// Screen point to normalised point, or nil outside the chart.
    ///
    /// Deliberately not clamped to `0...1`: the square is inscribed in a
    /// possibly-wider `bounds`, so a legitimate click beside the pack maps to a
    /// normalised x outside the unit box, and that is the answer — it is on no
    /// circle, which is what `.background` means.
    public func normalised(_ point: CGPoint) -> CGPoint? {
        guard !isDegenerate, bounds.contains(point) else { return nil }
        return CGPoint(x: (point.x - square.minX) / side, y: (point.y - square.minY) / side)
    }
}

/// A `BubbleLayout` arranged for drawing, hit testing and navigation.
///
/// Built once per layout, never per frame — same contract as `SunburstIndex`
/// and `TreemapIndex`, and for the same reason: the renderer, the hit test, the
/// navigator and the accessibility roster all read one ordering, so they cannot
/// disagree.
public struct BubbleIndex: Sendable {
    public let generation: UInt64
    public let focus: NodeRef
    public let focusName: String
    public let focusPath: String
    public let breadcrumb: [Breadcrumb]
    public let totalPhysicalBytes: UInt64
    public let totalLogicalBytes: UInt64
    public let scannedAt: Date
    public let isComplete: Bool

    /// Shallowest-first, exactly as the contract delivers them, so painting in
    /// array order draws parents beneath children with no sorting.
    public let circles: [BubbleCircle]
    /// `depthRanges[d]` slices `circles` down to depth `d`.
    public let depthRanges: [Range<Int>]

    private let parents: [Int32]
    private let positionByNode: [UInt32: BubblePosition]
    /// Deepest circle covering each cell of a coarse grid, or −1. Doubles as a
    /// hit-test accelerator and as the way parents are recovered without an
    /// O(n²) containment sweep.
    private let owners: [Int32]

    /// 96 × 96 cells, matching `TreemapIndex`. A cell is 1/96 of the container
    /// on a side and the smallest circle the packer will emit has a radius of
    /// 0.006 — a little over a cell across — so the grid resolves nearly every
    /// circle that exists, and the exact fallbacks below cover the rest.
    static let gridResolution = 96

    public var depthCount: Int { depthRanges.count }
    public var isEmpty: Bool { circles.isEmpty }

    public init(_ layout: BubbleLayout) {
        generation = layout.generation
        focus = layout.focus
        focusPath = layout.focusPath
        breadcrumb = layout.breadcrumb
        totalPhysicalBytes = layout.totalPhysicalBytes
        totalLogicalBytes = layout.totalLogicalBytes
        scannedAt = layout.scannedAt
        isComplete = layout.isComplete
        focusName = layout.breadcrumb.last?.name
            ?? layout.focusPath.split(separator: "/").last.map(String.init)
            ?? "All items"

        // The contract promises shallowest-first, and a layout arrives up to ten
        // times a second during a scan — so check before paying for a sort.
        let source = layout.circles
        var ordered = source
        if !Self.isOrdered(source) {
            ordered.sort { $0.depth < $1.depth }
        }
        circles = ordered

        var ranges: [Range<Int>] = []
        var positions: [UInt32: BubblePosition] = [:]
        positions.reserveCapacity(ordered.count)
        var i = 0
        while i < ordered.count {
            let depth = Int(ordered[i].depth)
            // A depth the packer skipped still needs a slot, or `depthRanges[d]`
            // stops meaning "depth d".
            while ranges.count < depth { ranges.append(i..<i) }
            var j = i
            while j < ordered.count, Int(ordered[j].depth) == depth {
                // First writer wins, as in the other two indexes: a duplicate
                // ref must degrade into "not findable" rather than retargeting
                // the first.
                if positions[ordered[j].id] == nil {
                    positions[ordered[j].id] = BubblePosition(depth: depth, offset: j - i)
                }
                j += 1
            }
            ranges.append(i..<j)
            i = j
        }
        depthRanges = ranges
        positionByNode = positions

        let built = Self.buildCoverage(circles: ordered, depthRanges: ranges)
        owners = built.owners
        parents = built.parents
    }

    private static func isOrdered(_ circles: [BubbleCircle]) -> Bool {
        var previous: UInt8 = 0
        for circle in circles {
            if circle.depth < previous { return false }
            previous = circle.depth
        }
        return true
    }

    // MARK: - Coverage

    /// One pass that answers two questions at once: who owns each cell (hit
    /// testing), and which circle is each circle's parent (share-of-parent,
    /// hover ancestry, navigation).
    ///
    /// Painting depth by depth is what makes the parent lookup fall out for
    /// free: when a depth-`d` circle is about to be painted, whatever owns its
    /// centre cell is the deepest thing painted so far, which is its parent.
    /// That is the geometric recovery `BubbleLayout`'s nesting invariant exists
    /// to make sound, and `BubblePackTests` pins the invariant.
    private static func buildCoverage(circles: [BubbleCircle], depthRanges: [Range<Int>])
        -> (owners: [Int32], parents: [Int32]) {
        let resolution = gridResolution
        var owners = [Int32](repeating: -1, count: resolution * resolution)
        var parents = [Int32](repeating: -1, count: circles.count)
        guard !circles.isEmpty else { return (owners, parents) }

        // A budget on the exact fallback below, so a pathological layout of
        // thousands of sub-cell circles cannot turn this into a quadratic sweep.
        var exactLookups = 256

        for depth in depthRanges.indices {
            let range = depthRanges[depth]
            guard !range.isEmpty else { continue }

            if depth > 0 {
                let parentRange = depthRanges[depth - 1]
                for i in range {
                    let cx = circles[i].centerX, cy = circles[i].centerY
                    let cell = index(ofX: cx, y: cy, resolution: resolution)
                    let candidate = owners[cell]
                    if candidate >= 0, Int(circles[Int(candidate)].depth) == depth - 1,
                       circles[Int(candidate)].contains(x: cx, y: cy) {
                        parents[i] = candidate
                    } else if exactLookups > 0 {
                        // The parent was too small to claim a cell of its own.
                        // Rare, and worth an exact scan of one level rather than
                        // a wrong percentage in the inspector.
                        exactLookups -= 1
                        for p in parentRange where circles[p].contains(x: cx, y: cy) {
                            parents[i] = Int32(p)
                            break
                        }
                    }
                }
            }

            for i in range { paint(circles[i], as: Int32(i), into: &owners, resolution: resolution) }
        }
        return (owners, parents)
    }

    @inline(__always)
    private static func index(ofX x: Double, y: Double, resolution: Int) -> Int {
        let column = min(resolution - 1, max(0, Int(x * Double(resolution))))
        let row = min(resolution - 1, max(0, Int(y * Double(resolution))))
        return row * resolution + column
    }

    /// Claims the cells whose centres fall inside the circle.
    ///
    /// Cell *centres* rather than the bounding box, because a circle's box is
    /// four-fifths bigger than the circle and the corners of it belong to
    /// whatever is behind. Claiming them would let a click on the parent land on
    /// a child that is visibly nowhere near the pointer.
    private static func paint(_ circle: BubbleCircle, as owner: Int32,
                              into owners: inout [Int32], resolution: Int) {
        let step = 1.0 / Double(resolution)
        let x0 = min(resolution - 1, max(0, Int((circle.centerX - circle.radius) * Double(resolution))))
        let x1 = min(resolution - 1, max(0, Int((circle.centerX + circle.radius) * Double(resolution))))
        let y0 = min(resolution - 1, max(0, Int((circle.centerY - circle.radius) * Double(resolution))))
        let y1 = min(resolution - 1, max(0, Int((circle.centerY + circle.radius) * Double(resolution))))
        let r2 = circle.radius * circle.radius
        var claimed = false
        var row = y0
        while row <= y1 {
            let cy = (Double(row) + 0.5) * step - circle.centerY
            let base = row * resolution
            var column = x0
            while column <= x1 {
                let cx = (Double(column) + 0.5) * step - circle.centerX
                if cx * cx + cy * cy <= r2 {
                    owners[base + column] = owner
                    claimed = true
                }
                column += 1
            }
            row += 1
        }
        // A circle smaller than a cell contains no cell centre and would
        // otherwise be invisible to both the hit test and the parent lookup.
        // Every grid answer is verified with `contains` before it is believed,
        // so over-claiming here is safe and under-claiming is not.
        if !claimed {
            owners[index(ofX: circle.centerX, y: circle.centerY, resolution: resolution)] = owner
        }
    }

    // MARK: - Lookup

    public subscript(position: BubblePosition) -> BubbleCircle? {
        guard let i = circleIndex(of: position) else { return nil }
        return circles[i]
    }

    public func circleIndex(of position: BubblePosition) -> Int? {
        guard depthRanges.indices.contains(position.depth), position.offset >= 0 else { return nil }
        let range = depthRanges[position.depth]
        let i = range.lowerBound + position.offset
        guard i < range.upperBound else { return nil }
        return i
    }

    public func position(at index: Int) -> BubblePosition? {
        guard circles.indices.contains(index) else { return nil }
        let depth = Int(circles[index].depth)
        guard depthRanges.indices.contains(depth) else { return nil }
        return BubblePosition(depth: depth, offset: index - depthRanges[depth].lowerBound)
    }

    public func count(atDepth depth: Int) -> Int {
        depthRanges.indices.contains(depth) ? depthRanges[depth].count : 0
    }

    public func circles(atDepth depth: Int) -> ArraySlice<BubbleCircle> {
        guard depthRanges.indices.contains(depth) else { return circles[0..<0] }
        return circles[depthRanges[depth]]
    }

    /// Where a node sits now, so keyboard focus survives the next layout
    /// arriving mid-scan and the circles shuffling under it.
    public func position(ofNode node: NodeRef) -> BubblePosition? {
        positionByNode[node.rawValue]
    }

    // MARK: - Parents

    public func parentIndex(of index: Int) -> Int? {
        guard circles.indices.contains(index) else { return nil }
        let parent = parents[index]
        return parent >= 0 ? Int(parent) : nil
    }

    public func parent(of position: BubblePosition) -> BubblePosition? {
        guard let i = circleIndex(of: position), let p = parentIndex(of: i) else { return nil }
        return self.position(at: p)
    }

    public func children(of index: Int) -> [Int] {
        let depth = Int(circles[index].depth) + 1
        guard depthRanges.indices.contains(depth) else { return [] }
        return depthRanges[depth].filter { parentIndex(of: $0) == index }
    }

    /// Everything nested inside `index`, shallowest-first, excluding itself.
    ///
    /// One linear pass rather than a walk down `children(of:)`, which is O(level)
    /// per call and would be quadratic over a subtree. It works because the
    /// contract's shallowest-first ordering guarantees a parent is always earlier
    /// in the array than its children, so a single forward sweep can answer
    /// "is my parent in the subtree" from what it has already decided.
    public func subtree(from index: Int) -> [Int] {
        guard circles.indices.contains(index) else { return [] }
        var inside = [Bool](repeating: false, count: circles.count)
        inside[index] = true
        var out: [Int] = []
        var i = index + 1
        while i < circles.count {
            if let parent = parentIndex(of: i), inside[parent] {
                inside[i] = true
                out.append(i)
            }
            i += 1
        }
        return out
    }

    // MARK: - Hit testing

    /// Point to circle: the **deepest** circle containing it, which is the one
    /// painted on top.
    ///
    /// The grid answers in constant time almost always; the reverse walk behind
    /// it is the exact answer and relies on nothing but the contract's
    /// shallowest-first ordering — the last circle containing the point is the
    /// deepest one, because nesting means a deeper circle is always painted
    /// later.
    public func hit(at point: CGPoint, metrics: BubbleMetrics) -> BubbleHit {
        guard let normalised = metrics.normalised(point) else { return .none }
        let x = normalised.x, y = normalised.y
        if x >= 0, x < 1, y >= 0, y < 1 {
            let cell = owners[Self.index(ofX: x, y: y, resolution: Self.gridResolution)]
            if cell >= 0, circles[Int(cell)].contains(x: x, y: y),
               let position = position(at: Int(cell)) {
                return .circle(position)
            }
        }
        var i = circles.count - 1
        while i >= 0 {
            if circles[i].contains(x: x, y: y), let position = position(at: i) {
                return .circle(position)
            }
            i -= 1
        }
        return .background
    }
}
