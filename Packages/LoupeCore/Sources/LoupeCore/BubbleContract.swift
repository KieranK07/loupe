import Foundation

/// A packed circle, in **normalised coordinates**: a unit square, `0...1` on
/// both axes, origin top-left, y growing down — the same convention as
/// `TreemapRect`, so a renderer scales all three charts identically.
///
/// The focus's own circle is centred at `(0.5, 0.5)` with radius `0.5`, and it
/// is **not emitted** — same rule as the sunburst's centre disc and the
/// treemap's focus. What you get back are its descendants, packed inside it.
///
/// Radius is a fraction of the container's *smaller* side, so a non-square view
/// scales circles by `min(width, height)` and centres the result. Scaling x and
/// y independently would turn every circle into an ellipse.
public struct BubbleCircle: Sendable, Identifiable, Hashable {
    public let node: NodeRef
    public let centerX: Double
    public let centerY: Double
    public let radius: Double
    /// Mirrors `Wedge.ring` and `TreemapTile.depth` exactly: **0 is the focus's
    /// direct children.** All three views must agree about what level a thing is
    /// on, or toggling between them silently changes what the user is looking at.
    public let depth: UInt8
    public let physicalBytes: UInt64
    public let logicalBytes: UInt64
    public let itemCount: UInt32
    public let name: String
    public let kind: WedgeKind
    /// Same stable hue key as `Wedge.colorSeed` and `TreemapTile.colorSeed`.
    public let colorSeed: UInt16
    /// True when this circle has children in the layout, so a renderer can style
    /// leaves differently without a second pass to find out.
    public let hasChildren: Bool

    public var id: UInt32 { node.rawValue }
    public var area: Double { .pi * radius * radius }

    public func contains(x: Double, y: Double) -> Bool {
        let dx = x - centerX, dy = y - centerY
        return dx * dx + dy * dy <= radius * radius
    }

    public init(node: NodeRef, centerX: Double, centerY: Double, radius: Double,
                depth: UInt8, physicalBytes: UInt64, logicalBytes: UInt64,
                itemCount: UInt32, name: String, kind: WedgeKind,
                colorSeed: UInt16, hasChildren: Bool) {
        self.node = node; self.centerX = centerX; self.centerY = centerY
        self.radius = radius; self.depth = depth
        self.physicalBytes = physicalBytes; self.logicalBytes = logicalBytes
        self.itemCount = itemCount; self.name = name; self.kind = kind
        self.colorSeed = colorSeed; self.hasChildren = hasChildren
    }
}

/// The circle-packing counterpart of `SunburstLayout` and `TreemapLayout`.
///
/// Circles do not tile, so this encoding trades density for legibility of
/// *structure*. It is the right view for seeing how a tree nests and the wrong
/// one for judging which of two similar things is larger — the UI should say so
/// rather than letting a pretty chart imply a precision it does not have.
public struct BubbleLayout: Sendable, Equatable {
    public let generation: UInt64
    public let focus: NodeRef
    public let focusPath: String
    public let breadcrumb: [Breadcrumb]
    /// Ordered shallowest-first (depth 0 before depth 1), so painting in array
    /// order draws parents beneath children with no sorting.
    ///
    /// Invariants the packer guarantees and its tests pin:
    /// 1. **Nesting** — a circle at depth `d+1` lies wholly within its parent.
    /// 2. **No sibling overlap** — circles at the same depth under one parent are
    ///    tangent at worst, never intersecting.
    ///
    /// Both are load-bearing: hit-testing takes the deepest circle containing a
    /// point, and parent recovery is geometric.
    public let circles: [BubbleCircle]
    public let totalPhysicalBytes: UInt64
    public let totalLogicalBytes: UInt64
    public let scannedAt: Date
    public let isComplete: Bool

    public static let empty = BubbleLayout(
        generation: 0, focus: .invalid, focusPath: "", breadcrumb: [], circles: [],
        totalPhysicalBytes: 0, totalLogicalBytes: 0, scannedAt: .distantPast,
        isComplete: false)

    public init(generation: UInt64, focus: NodeRef, focusPath: String,
                breadcrumb: [Breadcrumb], circles: [BubbleCircle],
                totalPhysicalBytes: UInt64, totalLogicalBytes: UInt64,
                scannedAt: Date, isComplete: Bool) {
        self.generation = generation; self.focus = focus; self.focusPath = focusPath
        self.breadcrumb = breadcrumb; self.circles = circles
        self.totalPhysicalBytes = totalPhysicalBytes
        self.totalLogicalBytes = totalLogicalBytes
        self.scannedAt = scannedAt; self.isComplete = isComplete
    }
}

public enum BubbleGeometry {
    /// A circle below this fraction of the container is merged into an
    /// `.aggregated` bubble. Larger than the treemap's threshold because packing
    /// wastes space: the same byte share buys a smaller shape here.
    ///
    /// **Why this exact number.** It is the smaller of two constraints, and the
    /// binding one is arithmetic rather than taste.
    ///
    /// The cull is an *area* budget: a parent of inner radius `r` can hold at
    /// most `(r / minimumRadiusFraction)²` circles that each clear the
    /// threshold. At the original 0.006 that admitted **6834** per parent and
    /// **6944** across a level — both far above `maximumCircles`, so a wide
    /// directory would build a level the backstop then threw away and the user
    /// would get an *empty chart for a full disk*. That precise inconsistency
    /// shipped once in `TreemapGeometry`; it is not a hypothetical.
    ///
    /// `0.496 / √3000 = 0.00906` is where the cull stops being able to exceed
    /// the backstop. Rounded up to 0.0092 for margin, which admits 2907 per
    /// parent and 2954 per level — so `maximumCircles` is now a true cap that
    /// nothing reaches rather than a trap.
    ///
    /// It also happens to fix a usability problem: radius is a fraction of the
    /// container's smaller side, so in an 800 pt view 0.006 drew a 9.6 pt
    /// circle and 0.0092 draws a 14.7 pt one. The first is not a pointer target.
    /// That is a happy side effect, not the reason — the budget is the reason.
    public static let minimumRadiusFraction: Double = 0.0092

    /// Levels emitted, **not** a maximum index — a value of 4 means depths 0...3.
    /// Shallower than the sunburst's 8 rings for the same reason as the treemap:
    /// each level nests inside the last, so depth 5 is confetti.
    public static let maximumDepth: UInt8 = 4

    /// Cross-level backstop. Must exceed what the radius cull can admit in one
    /// level, or a wide directory builds a level the backstop then discards —
    /// the inconsistency that shipped once in `TreemapGeometry`.
    public static let maximumCircles: Int = 3000

    /// Gap between tangent siblings, as a fraction of the container, so touching
    /// circles read as two things rather than one blob.
    public static let siblingPadding: Double = 0.004
}
