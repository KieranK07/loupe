import Foundation

/// A tile's rectangle in **normalised coordinates**: every value is a fraction
/// of the container, in `0...1`.
///
/// Deliberately unit-free. The layout engine has no idea how large the view is,
/// and the view has no idea how the rectangles were computed — a renderer scales
/// by its own bounds and nothing has to agree about points, pixels or insets.
///
/// Origin is **top-left**, x grows right, y grows down, matching SwiftUI's own
/// coordinate space so a renderer never has to flip anything.
///
/// A treemap tiles its container exactly, so a child's rect is contained in its
/// parent's (`⊆`) and siblings share edges — it is not strictly interior. Visual
/// padding between tiles is the renderer's business: an inset expressed in
/// normalised units would scale with the view and look wrong at every size but one.
public struct TreemapRect: Sendable, Hashable {
    public let x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { width * height }

    /// Scales into a concrete pixel/point rect.
    public func scaled(toWidth w: Double, height h: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        (x * w, y * h, width * w, height * h)
    }

    /// Half-open on both axes, so tiles sharing an edge never both claim a point.
    /// A consequence worth knowing: a point at exactly `x == 1` or `y == 1` lands
    /// in no tile at all, so a renderer should clamp incoming coordinates.
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }
}

/// One rectangle in a squarified treemap.
///
/// `depth` mirrors `Wedge.ring` exactly: **0 is the focus's direct children**,
/// each further level is one deeper, and the focus itself is never a tile. Kept
/// identical on purpose so the two views cannot disagree about what level
/// something is on.
public struct TreemapTile: Sendable, Identifiable, Hashable {
    public let node: NodeRef
    public let frame: TreemapRect
    public let depth: UInt8
    public let physicalBytes: UInt64
    public let logicalBytes: UInt64
    public let itemCount: UInt32
    public let name: String
    public let kind: WedgeKind
    /// Same stable hue key as `Wedge.colorSeed`, so switching between the
    /// sunburst and the treemap does not recolour the machine.
    public let colorSeed: UInt16

    public var id: UInt32 { node.rawValue }

    public init(node: NodeRef, frame: TreemapRect, depth: UInt8,
                physicalBytes: UInt64, logicalBytes: UInt64, itemCount: UInt32,
                name: String, kind: WedgeKind, colorSeed: UInt16) {
        self.node = node; self.frame = frame; self.depth = depth
        self.physicalBytes = physicalBytes; self.logicalBytes = logicalBytes
        self.itemCount = itemCount; self.name = name; self.kind = kind
        self.colorSeed = colorSeed
    }
}

/// The treemap counterpart of `SunburstLayout`, and bounded the same way: a few
/// thousand tiles at most, whatever the size of the tree underneath.
public struct TreemapLayout: Sendable, Equatable {
    public let generation: UInt64
    public let focus: NodeRef
    public let focusPath: String
    public let breadcrumb: [Breadcrumb]
    /// Ordered shallowest-first (depth 0 before depth 1), so a renderer painting
    /// in array order draws parents beneath their children with no sorting.
    ///
    /// Two invariants the layouter guarantees and its tests pin — the treemap's
    /// equivalent of the sunburst's containment and gapless-fill promises:
    ///
    /// 1. **Nesting** — a tile at depth `d+1` lies within (`⊆`) the tile at depth
    ///    `d` that is its parent. Siblings do not overlap.
    /// 2. **Exact tiling** — a parent's children cover it completely; siblings
    ///    share edges rather than leaving gaps.
    ///
    /// These are load-bearing, not incidental. A renderer recovers the parent of
    /// a tile geometrically — whatever contains its centre at the previous depth —
    /// and that is also how share-of-parent percentages, hover ancestry and search
    /// ancestry are derived. Break nesting and all four go wrong silently.
    ///
    /// Within a level, tiles are grouped by parent and ordered descending by size
    /// with the same tie-break `SunburstProjector` uses, so the two views agree
    /// about sibling order.
    public let tiles: [TreemapTile]
    public let totalPhysicalBytes: UInt64
    public let totalLogicalBytes: UInt64
    public let scannedAt: Date
    public let isComplete: Bool

    public static let empty = TreemapLayout(
        generation: 0, focus: .invalid, focusPath: "", breadcrumb: [], tiles: [],
        totalPhysicalBytes: 0, totalLogicalBytes: 0, scannedAt: .distantPast,
        isComplete: false)

    public init(generation: UInt64, focus: NodeRef, focusPath: String,
                breadcrumb: [Breadcrumb], tiles: [TreemapTile],
                totalPhysicalBytes: UInt64, totalLogicalBytes: UInt64,
                scannedAt: Date, isComplete: Bool) {
        self.generation = generation; self.focus = focus; self.focusPath = focusPath
        self.breadcrumb = breadcrumb; self.tiles = tiles
        self.totalPhysicalBytes = totalPhysicalBytes
        self.totalLogicalBytes = totalLogicalBytes
        self.scannedAt = scannedAt; self.isComplete = isComplete
    }
}

public enum TreemapGeometry {
    /// A tile smaller than this fraction of the container is merged into an
    /// `.aggregated` tile. Unit-free, unlike the sunburst's angular threshold,
    /// so it needs no assumption about the view's size.
    ///
    /// At a 1200x800 view this is about 10x10 points — small, but still large
    /// enough to see and to click.
    ///
    /// Caveat worth knowing: this bounds *area*, and clickability depends on the
    /// shorter edge. A tile at exactly this threshold could in principle be 45pt
    /// by 1.4pt. What actually prevents that is the layouter being squarified —
    /// measured worst aspect ratio 2.03 on a realistic heavy-tailed distribution,
    /// against 397 for naive slice-and-dice. The aspect bound is a property of
    /// the algorithm rather than a number enforced here, so a future layouter
    /// must preserve it or this threshold stops meaning what it says.
    public static let minimumAreaFraction: Double = 0.00012

    /// Number of levels emitted, **not** a maximum index. Mirrors
    /// `SunburstGeometry.maximumRings`: a value of 4 means depths 0...3, where
    /// depth 0 is the focus's direct children. Stated explicitly because reading
    /// this as a max index is exactly the off-by-one that shipped once already.
    ///
    /// Deliberately shallower than the sunburst's 8 rings. A ring keeps its full
    /// angular share at any depth, but a treemap tile is divided by area at every
    /// level, so depth 5 is a scattering of unhittable slivers where ring 5 is
    /// still a legible band. A user toggling views will see the treemap show less
    /// of the tree, and that is the intended trade rather than an oversight.
    public static let maximumDepth: UInt8 = 4

    /// Cross-level backstop on total tiles.
    ///
    /// This must stay consistent with `minimumAreaFraction`: the area cull alone
    /// admits up to `1 / minimumAreaFraction` tiles in a single level (~8,333
    /// here), so a ceiling below that could reject a level the cull was willing
    /// to build — and "drop whole levels" would then discard depth 0 and render
    /// an empty treemap for a full disk. Keep this above `1 / minimumAreaFraction`.
    public static let maximumTiles: Int = 9000

    /// Largest number of tiles the area cull can admit in one level, given
    /// `minimumAreaFraction`. `maximumTiles` must exceed this.
    public static var maximumTilesPerLevel: Int { Int(1 / minimumAreaFraction) }
}
