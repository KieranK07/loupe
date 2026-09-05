import CoreGraphics
import Foundation
import LoupeCore

/// A tile's address: which depth, and how far along that depth.
///
/// The treemap's counterpart of `SunburstPosition`, and for the same reason —
/// hover and keyboard focus are tracked by position rather than by id, because
/// "the tile to the left of this one" is an offset, not an identity.
public struct TreemapPosition: Sendable, Hashable {
    public let depth: Int
    public let offset: Int

    public init(depth: Int, offset: Int) {
        self.depth = depth
        self.offset = offset
    }
}

public enum TreemapHit: Sendable, Hashable {
    case tile(TreemapPosition)
    /// Inside the map but on no tile. The zoom-out target, so that a
    /// pointer-only user has the same way back out that the sunburst's centre
    /// disc gives them.
    case background
    /// Outside the map entirely.
    case none
}

/// Where the treemap sits on screen.
///
/// `TreemapRect` is normalised, deliberately, so this is the only place that
/// knows how large the view is.
public struct TreemapMetrics: Sendable, Equatable {
    public let bounds: CGRect

    public init(bounds: CGRect) {
        self.bounds = CGRect(x: bounds.minX, y: bounds.minY,
                             width: max(0, bounds.width), height: max(0, bounds.height))
    }

    /// Square-ish inset so the map does not run into the window's edges.
    public init(size: CGSize, inset: Double = 12) {
        let width = max(0, size.width - inset * 2)
        let height = max(0, size.height - inset * 2)
        self.init(bounds: CGRect(x: inset, y: inset, width: width, height: height))
    }

    public var isDegenerate: Bool { bounds.width <= 0 || bounds.height <= 0 }

    public func rect(for frame: TreemapRect) -> CGRect {
        let scaled = frame.scaled(toWidth: bounds.width, height: bounds.height)
        return CGRect(x: bounds.minX + scaled.x, y: bounds.minY + scaled.y,
                      width: scaled.width, height: scaled.height)
    }

    public func rect(for tile: TreemapTile) -> CGRect { rect(for: tile.frame) }

    /// Screen point to normalised point, or nil outside the map.
    public func normalised(_ point: CGPoint) -> CGPoint? {
        guard !isDegenerate else { return nil }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        guard x >= 0, x < 1, y >= 0, y < 1 else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// How much of a tile is still visible once the tiles nested inside it have
/// been painted on top.
public struct TreemapExposure: Sendable, Hashable {
    /// `0...1`. A tile whose children tile it completely is at zero, and a name
    /// drawn in the middle of it would sit on a child's colour and appear to
    /// belong to the child.
    public let visibleFraction: Double
    /// Bounds of what is left, normalised. Degenerate when nothing is left.
    public let visibleBounds: TreemapRect

    public static let none = TreemapExposure(visibleFraction: 0,
                                             visibleBounds: TreemapRect(x: 0, y: 0, width: 0, height: 0))
}

/// A `TreemapLayout` arranged for drawing, hit testing and navigation.
///
/// Built once per layout, never per frame — same contract as `SunburstIndex`,
/// and for the same reason: the renderer, the hit test, the navigator and the
/// accessibility roster all read one ordering, so they cannot disagree.
public struct TreemapIndex: Sendable {
    public let generation: UInt64
    public let focus: NodeRef
    public let focusName: String
    public let focusPath: String
    public let breadcrumb: [Breadcrumb]
    public let totalPhysicalBytes: UInt64
    public let totalLogicalBytes: UInt64
    public let scannedAt: Date
    public let isComplete: Bool

    /// Outermost-first, exactly as the contract delivers them, so painting in
    /// array order draws parents beneath children with no sorting.
    public let tiles: [TreemapTile]
    /// `depthRanges[d]` slices `tiles` down to depth `d`.
    public let depthRanges: [Range<Int>]
    /// Per tile, how much of it survives its children. Index-parallel to `tiles`.
    public let exposure: [TreemapExposure]

    private let parents: [Int32]
    private let positionByNode: [UInt32: TreemapPosition]
    /// Deepest tile covering each cell of a coarse grid, or −1. Doubles as a
    /// hit-test accelerator and as the way parents are recovered without an
    /// O(n²) containment sweep.
    private let owners: [Int32]

    /// 96 × 96 cells. `TreemapGeometry.minimumAreaFraction` is 1.2e−4 and a cell
    /// is 1.09e−4 of the container, so the smallest tile the layouter will emit
    /// is about one cell — fine enough to resolve every tile that exists, and
    /// coarse enough that building the grid is a few tens of thousands of
    /// writes rather than a raster of the whole view.
    static let gridResolution = 96

    public var depthCount: Int { depthRanges.count }
    public var isEmpty: Bool { tiles.isEmpty }

    public init(_ layout: TreemapLayout) {
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

        // The contract promises outermost-first, and a layout arrives up to ten
        // times a second during a scan — so check before paying for a sort.
        let source = layout.tiles
        var ordered = source
        if !Self.isOrdered(source) {
            ordered.sort { $0.depth < $1.depth }
        }
        tiles = ordered

        var ranges: [Range<Int>] = []
        var positions: [UInt32: TreemapPosition] = [:]
        positions.reserveCapacity(ordered.count)
        var i = 0
        while i < ordered.count {
            let depth = Int(ordered[i].depth)
            // A depth the layouter skipped still needs a slot, or `depthRanges[d]`
            // stops meaning "depth d".
            while ranges.count < depth { ranges.append(i..<i) }
            var j = i
            while j < ordered.count, Int(ordered[j].depth) == depth {
                // First writer wins, as in `SunburstIndex`: a duplicate ref must
                // degrade into "not findable" rather than retargeting the first.
                if positions[ordered[j].id] == nil {
                    positions[ordered[j].id] = TreemapPosition(depth: depth, offset: j - i)
                }
                j += 1
            }
            ranges.append(i..<j)
            i = j
        }
        depthRanges = ranges
        positionByNode = positions

        let built = Self.buildCoverage(tiles: ordered, depthRanges: ranges)
        owners = built.owners
        parents = built.parents
        exposure = built.exposure
    }

    private static func isOrdered(_ tiles: [TreemapTile]) -> Bool {
        var previous: UInt8 = 0
        for tile in tiles {
            if tile.depth < previous { return false }
            previous = tile.depth
        }
        return true
    }

    // MARK: - Coverage

    /// One pass that answers three questions at once: who owns each cell (hit
    /// testing), which tile is each tile's parent (share-of-parent, search
    /// ancestry, navigation), and how much of each tile survives its children
    /// (where a label may go).
    ///
    /// Painting depth by depth is what makes the parent lookup fall out for
    /// free: when a depth-`d` tile is about to be painted, whatever owns its
    /// centre cell is the deepest thing painted so far, which is its parent.
    private static func buildCoverage(tiles: [TreemapTile], depthRanges: [Range<Int>])
        -> (owners: [Int32], parents: [Int32], exposure: [TreemapExposure]) {
        let resolution = gridResolution
        var owners = [Int32](repeating: -1, count: resolution * resolution)
        var parents = [Int32](repeating: -1, count: tiles.count)
        guard !tiles.isEmpty else { return (owners, parents, []) }

        // A budget on the exact fallback below, so a pathological layout of
        // thousands of sub-cell tiles cannot turn this into a quadratic sweep.
        var exactLookups = 256

        for depth in depthRanges.indices {
            let range = depthRanges[depth]
            guard !range.isEmpty else { continue }

            if depth > 0 {
                let parentRange = depthRanges[depth - 1]
                for i in range {
                    let frame = tiles[i].frame
                    let cx = frame.x + frame.width / 2
                    let cy = frame.y + frame.height / 2
                    let cell = index(ofX: cx, y: cy, resolution: resolution)
                    let candidate = owners[cell]
                    if candidate >= 0, Int(tiles[Int(candidate)].depth) == depth - 1,
                       tiles[Int(candidate)].frame.contains(x: cx, y: cy) {
                        parents[i] = candidate
                    } else if exactLookups > 0 {
                        // The parent was too small to claim a cell. Rare, and
                        // worth an exact scan of one level rather than a wrong
                        // percentage in the inspector.
                        exactLookups -= 1
                        for p in parentRange where tiles[p].frame.contains(x: cx, y: cy) {
                            parents[i] = Int32(p)
                            break
                        }
                    }
                }
            }

            for i in range { paint(tiles[i].frame, as: Int32(i), into: &owners, resolution: resolution) }
        }

        var cellCounts = [Int32](repeating: 0, count: tiles.count)
        var minX = [Int32](repeating: Int32(resolution), count: tiles.count)
        var minY = [Int32](repeating: Int32(resolution), count: tiles.count)
        var maxX = [Int32](repeating: -1, count: tiles.count)
        var maxY = [Int32](repeating: -1, count: tiles.count)
        for cell in owners.indices {
            let owner = owners[cell]
            guard owner >= 0 else { continue }
            let o = Int(owner)
            let column = Int32(cell % resolution), row = Int32(cell / resolution)
            cellCounts[o] += 1
            if column < minX[o] { minX[o] = column }
            if column > maxX[o] { maxX[o] = column }
            if row < minY[o] { minY[o] = row }
            if row > maxY[o] { maxY[o] = row }
        }

        let step = 1.0 / Double(resolution)
        var exposure: [TreemapExposure] = []
        exposure.reserveCapacity(tiles.count)
        for i in tiles.indices {
            guard maxX[i] >= 0 else { exposure.append(.none); continue }
            // The denominator is the tile's own area in cells. Sub-cell tiles
            // claim exactly one cell, so this can exceed one; clamp it.
            let expected = max(1.0, tiles[i].frame.area * Double(resolution * resolution))
            let fraction = min(1.0, Double(cellCounts[i]) / expected)
            let bounds = TreemapRect(x: Double(minX[i]) * step, y: Double(minY[i]) * step,
                                     width: Double(maxX[i] - minX[i] + 1) * step,
                                     height: Double(maxY[i] - minY[i] + 1) * step)
            exposure.append(TreemapExposure(visibleFraction: fraction, visibleBounds: bounds))
        }
        return (owners, parents, exposure)
    }

    @inline(__always)
    private static func index(ofX x: Double, y: Double, resolution: Int) -> Int {
        let column = min(resolution - 1, max(0, Int(x * Double(resolution))))
        let row = min(resolution - 1, max(0, Int(y * Double(resolution))))
        return row * resolution + column
    }

    private static func paint(_ frame: TreemapRect, as owner: Int32,
                              into owners: inout [Int32], resolution: Int) {
        let x0 = min(resolution - 1, max(0, Int(frame.x * Double(resolution))))
        let y0 = min(resolution - 1, max(0, Int(frame.y * Double(resolution))))
        // At least the cell the origin falls in, so a tile thinner than a cell
        // still claims its place. That errs towards "the parent is covered",
        // which is the safe direction: better an unlabelled folder than a name
        // floating over the children that hid it.
        let x1 = max(x0, min(resolution - 1, Int((frame.maxX * Double(resolution)).rounded(.up)) - 1))
        let y1 = max(y0, min(resolution - 1, Int((frame.maxY * Double(resolution)).rounded(.up)) - 1))
        var row = y0
        while row <= y1 {
            let base = row * resolution
            var column = x0
            while column <= x1 {
                owners[base + column] = owner
                column += 1
            }
            row += 1
        }
    }

    // MARK: - Lookup

    public subscript(position: TreemapPosition) -> TreemapTile? {
        guard let i = tileIndex(of: position) else { return nil }
        return tiles[i]
    }

    public func tileIndex(of position: TreemapPosition) -> Int? {
        guard depthRanges.indices.contains(position.depth), position.offset >= 0 else { return nil }
        let range = depthRanges[position.depth]
        let i = range.lowerBound + position.offset
        guard i < range.upperBound else { return nil }
        return i
    }

    public func position(at index: Int) -> TreemapPosition? {
        guard tiles.indices.contains(index) else { return nil }
        let depth = Int(tiles[index].depth)
        guard depthRanges.indices.contains(depth) else { return nil }
        return TreemapPosition(depth: depth, offset: index - depthRanges[depth].lowerBound)
    }

    public func count(atDepth depth: Int) -> Int {
        depthRanges.indices.contains(depth) ? depthRanges[depth].count : 0
    }

    public func tiles(atDepth depth: Int) -> ArraySlice<TreemapTile> {
        guard depthRanges.indices.contains(depth) else { return tiles[0..<0] }
        return tiles[depthRanges[depth]]
    }

    /// Where a node sits now, so keyboard focus survives the next layout
    /// arriving mid-scan and the tiles shuffling under it.
    public func position(ofNode node: NodeRef) -> TreemapPosition? {
        positionByNode[node.rawValue]
    }

    public func exposure(of position: TreemapPosition) -> TreemapExposure {
        guard let i = tileIndex(of: position) else { return .none }
        return exposure[i]
    }

    // MARK: - Parents

    public func parentIndex(of index: Int) -> Int? {
        guard tiles.indices.contains(index) else { return nil }
        let parent = parents[index]
        return parent >= 0 ? Int(parent) : nil
    }

    public func parent(of position: TreemapPosition) -> TreemapPosition? {
        guard let i = tileIndex(of: position), let p = parentIndex(of: i) else { return nil }
        return self.position(at: p)
    }

    // MARK: - Hit testing

    /// Point to tile. The grid answers in constant time almost always; the
    /// reverse walk behind it is the exact answer and relies on nothing but the
    /// contract's outermost-first ordering — the last tile containing the point
    /// is the deepest, which is the one painted on top.
    public func hit(at point: CGPoint, metrics: TreemapMetrics) -> TreemapHit {
        guard let normalised = metrics.normalised(point) else { return .none }
        let x = normalised.x, y = normalised.y
        let cell = Self.index(ofX: x, y: y, resolution: Self.gridResolution)
        let candidate = owners[cell]
        if candidate >= 0, tiles[Int(candidate)].frame.contains(x: x, y: y),
           let position = position(at: Int(candidate)) {
            return .tile(position)
        }
        var i = tiles.count - 1
        while i >= 0 {
            if tiles[i].frame.contains(x: x, y: y), let position = position(at: i) {
                return .tile(position)
            }
            i -= 1
        }
        return .background
    }
}
