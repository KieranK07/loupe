import Foundation
import LoupeCore

/// One hovered thing, whichever chart it came from.
///
/// The sunburst hands back a `Wedge`, the treemap a `TreemapTile` and the
/// bubbles a `BubbleCircle`. The inspector does not care which, so all three
/// funnel through this.
///
/// Three near-identical initialisers rather than a protocol on the three
/// contract types: the shared fields are a coincidence of what an inspector
/// happens to want, not a claim that the three marks are the same kind of
/// thing. A protocol here would put an app concern into `LoupeCore`, which is
/// meant to be a set of frozen contracts with no opinion about who reads them.
struct InspectedItem: Equatable {
    let name: String
    let physicalBytes: UInt64
    let logicalBytes: UInt64
    let itemCount: UInt32
    let kind: WedgeKind

    /// An aggregate borrows the name of the largest sibling it swallowed, so
    /// printing `name` directly would put one real folder's name on a shape that
    /// stands for many. Resolve it here, once, rather than trusting every call
    /// site to remember.
    var displayName: String {
        if case .aggregated(let count) = kind { return "\(count) smaller items" }
        return name
    }

    var isAggregate: Bool { if case .aggregated = kind { true } else { false } }
    var isStillScanning: Bool { if case .stillScanning = kind { true } else { false } }

    init(_ w: Wedge) {
        name = w.name; physicalBytes = w.physicalBytes; logicalBytes = w.logicalBytes
        itemCount = w.itemCount; kind = w.kind
    }

    init(_ t: TreemapTile) {
        name = t.name; physicalBytes = t.physicalBytes; logicalBytes = t.logicalBytes
        itemCount = t.itemCount; kind = t.kind
    }

    init(_ c: BubbleCircle) {
        name = c.name; physicalBytes = c.physicalBytes; logicalBytes = c.logicalBytes
        itemCount = c.itemCount; kind = c.kind
    }
}
