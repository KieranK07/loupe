import Foundation

/// What a wedge represents. Aggregated and stillScanning exist so the view can
/// be honest about incompleteness instead of drawing a confident lie.
public enum WedgeKind: Sendable, Hashable {
    /// A single real filesystem node.
    case real
    /// Sub-pixel siblings merged into one wedge. Drawing them individually
    /// would cost thousands of arcs nobody can see or click.
    ///
    /// An aggregate has no natural node of its own, so by contract it carries
    /// the `NodeRef` **and the `name`** of the largest sibling it swallowed. The
    /// ref is unique — a culled node is emitted nowhere else — so every wedge in
    /// a layout still has a distinct `id`.
    ///
    /// The borrowed name is a trap: rendering `wedge.name` directly puts one real
    /// folder's name on a shape that stands for many, which is precisely the kind
    /// of quiet inaccuracy this app exists not to commit. Anything user-facing
    /// must go through a description layer that checks `kind` first and says
    /// "N smaller items" instead.
    case aggregated(count: Int)
    /// A directory whose subtree is still being walked; its total will grow.
    case stillScanning
}

/// One arc. Purely geometric plus the few facts the inspector needs, so the
/// renderer never has to reach back into the arena to draw a frame.
public struct Wedge: Sendable, Identifiable, Hashable {
    public let node: NodeRef
    /// Radians, clockwise from 12 o'clock. `endAngle > startAngle` always.
    public let startAngle: Double
    public let endAngle: Double
    /// Annulus index, NOT a depth-from-root. Ring 0 is the first band of arcs
    /// outside the centre disc and holds the focus's direct children; each
    /// further ring is one level deeper.
    ///
    /// The focus itself is the centre disc, has no angular extent, and is never
    /// emitted as a wedge — so no wedge ever describes the focus. A renderer maps
    /// this straight onto its ring radii with no offset. Getting this off by one
    /// leaves the innermost band empty and pushes every wedge outward.
    public let ring: UInt8
    public let physicalBytes: UInt64
    public let logicalBytes: UInt64
    public let itemCount: UInt32
    public let name: String
    public let kind: WedgeKind
    /// Stable hue key: the index of this wedge's top-level ancestor under the
    /// focus. Keeping it stable across zooms is what stops the chart flickering
    /// into a different colour scheme every time you drill in.
    public let colorSeed: UInt16

    public var id: UInt32 { node.rawValue }
    public var sweep: Double { endAngle - startAngle }

    public init(node: NodeRef, startAngle: Double, endAngle: Double, ring: UInt8,
                physicalBytes: UInt64, logicalBytes: UInt64, itemCount: UInt32,
                name: String, kind: WedgeKind, colorSeed: UInt16) {
        self.node = node; self.startAngle = startAngle; self.endAngle = endAngle
        self.ring = ring; self.physicalBytes = physicalBytes
        self.logicalBytes = logicalBytes; self.itemCount = itemCount
        self.name = name; self.kind = kind; self.colorSeed = colorSeed
    }
}

public struct Breadcrumb: Sendable, Identifiable, Hashable {
    public let node: NodeRef
    public let name: String
    public var id: UInt32 { node.rawValue }
    public init(node: NodeRef, name: String) { self.node = node; self.name = name }
}

/// An immutable projection of part of the tree, sized for the screen.
///
/// This is the ONLY tree-shaped thing that ever crosses onto the main actor.
/// It is bounded to a few thousand wedges regardless of whether the underlying
/// volume holds forty thousand files or four million, which is what keeps the
/// UI responsive during a scan without copying anything large.
public struct SunburstLayout: Sendable, Equatable {
    /// Monotonic. The view drops any layout older than the one it is showing,
    /// so a slow frame can never resurrect stale geometry.
    public let generation: UInt64
    public let focus: NodeRef
    public let focusPath: String
    public let breadcrumb: [Breadcrumb]

    /// Angle-sorted within each ring, and subject to two invariants the
    /// projector guarantees and its tests pin:
    ///
    /// 1. **Strict containment** — a wedge's angular span lies wholly inside its
    ///    parent's span in ring−1.
    /// 2. **Gapless fill** — a ring's wedges tile their parent's span exactly.
    ///
    /// This is a declared contract, not an accident: it is what lets the
    /// renderer recover parent/child purely geometrically (containment against
    /// ring−1, binary search within a ring) and so navigate and hit-test without
    /// ever reaching back into the arena. Break either invariant and keyboard
    /// navigation silently walks to the wrong node.
    public let wedges: [Wedge]
    public let totalPhysicalBytes: UInt64
    public let totalLogicalBytes: UInt64
    /// The UI always renders this as "as of HH:MM" — a live filesystem is never
    /// a consistent snapshot, and pretending otherwise would be dishonest.
    public let scannedAt: Date
    /// False while a walk is still running underneath this projection.
    public let isComplete: Bool

    public static let empty = SunburstLayout(
        generation: 0, focus: .invalid, focusPath: "", breadcrumb: [], wedges: [],
        totalPhysicalBytes: 0, totalLogicalBytes: 0, scannedAt: .distantPast,
        isComplete: false)

    public init(generation: UInt64, focus: NodeRef, focusPath: String,
                breadcrumb: [Breadcrumb], wedges: [Wedge],
                totalPhysicalBytes: UInt64, totalLogicalBytes: UInt64,
                scannedAt: Date, isComplete: Bool) {
        self.generation = generation; self.focus = focus; self.focusPath = focusPath
        self.breadcrumb = breadcrumb; self.wedges = wedges
        self.totalPhysicalBytes = totalPhysicalBytes
        self.totalLogicalBytes = totalLogicalBytes
        self.scannedAt = scannedAt; self.isComplete = isComplete
    }
}

/// Layout tuning constants, in one place so the renderer and the projector
/// cannot disagree about them.
public enum SunburstGeometry {
    /// Wedges narrower than this are merged into an `.aggregated` wedge.
    /// At a 400pt radius this is roughly one pixel of arc.
    public static let minimumSweepRadians: Double = 0.35 * .pi / 180
    /// Rings beyond this are not laid out until the user zooms in. A sunburst
    /// stops being legible well before this depth.
    public static let maximumRings: UInt8 = 8
    /// Hard ceiling on wedges per layout, as a backstop against pathological trees.
    public static let maximumWedges: Int = 6000
}
