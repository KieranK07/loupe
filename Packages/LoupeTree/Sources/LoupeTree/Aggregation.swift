import LoupeCore

// MARK: - Children, reduced to what layout needs
//
// Projection never materialises an intermediate tree. It walks a directory's two
// contiguous child runs and reduces each entry to the struct below, which carries
// everything a `Wedge` needs plus the key the sibling ordering is defined on.
// Nothing here allocates: a name stays as an (offset, length) pair into the
// arena's byte buffer until a wedge is actually emitted, so a directory with
// 200k children costs 200k struct initialisations and zero heap traffic.

/// One child of a directory, as layout sees it.
struct SizedChild {
    var ref: NodeRef
    /// Bytes under the active basis. This alone decides how much of the parent's
    /// arc the child is entitled to.
    var size: UInt64
    var physicalBytes: UInt64
    var logicalBytes: UInt64
    var itemCount: UInt32
    var nameOffset: UInt32
    var nameLength: UInt8
    /// Only ever true of a directory; a file is complete the moment it is seen.
    var isIncomplete: Bool
}

/// A hard-link duplicate contributed nothing to its parent's roll-up, so it must
/// claim no arc either. If it did, a directory's children would sum to more than
/// the directory itself and the ring would over-fill. The real size is still in
/// the arena for the inspector, which says "counted once here" rather than
/// silently picking a winner.
@inline(__always)
func contributedBytes(_ node: FileNode) -> (physical: UInt64, logical: UInt64) {
    node.flags.contains(.hardlinkDuplicate) ? (0, 0) : (node.physicalBytes, node.logicalBytes)
}

@inline(__always)
func sizedChild(file slot: UInt32, _ node: FileNode, basis: SizeBasis) -> SizedChild {
    let bytes = contributedBytes(node)
    return SizedChild(ref: .file(slot),
                      size: basis == .physical ? bytes.physical : bytes.logical,
                      physicalBytes: bytes.physical,
                      logicalBytes: bytes.logical,
                      itemCount: 1,
                      nameOffset: node.nameOffset,
                      nameLength: node.nameLength,
                      isIncomplete: false)
}

@inline(__always)
func sizedChild(directory slot: UInt32, _ node: DirNode, basis: SizeBasis) -> SizedChild {
    SizedChild(ref: .directory(slot),
               size: basis == .physical ? node.subtreePhysicalBytes : node.subtreeLogicalBytes,
               physicalBytes: node.subtreePhysicalBytes,
               logicalBytes: node.subtreeLogicalBytes,
               itemCount: node.subtreeItems,
               nameOffset: node.nameOffset,
               nameLength: node.nameLength,
               isIncomplete: node.flags.contains(.incomplete))
}

// MARK: - Sibling ordering

/// Lexicographic comparison straight out of the arena's byte buffer.
///
/// Decoding two `String`s to answer "which of these ties sorts first" would put
/// an allocation on the hot path for a question that is almost always answered by
/// the first byte.
@inline(__always)
func compareNameBytes(_ a: SizedChild, _ b: SizedChild,
                      _ names: UnsafeBufferPointer<UInt8>) -> Int {
    let aStart = Int(a.nameOffset), aCount = Int(a.nameLength)
    let bStart = Int(b.nameOffset), bCount = Int(b.nameLength)
    let shared = min(aCount, bCount)
    var i = 0
    while i < shared {
        let x = names[aStart + i], y = names[bStart + i]
        if x != y { return x < y ? -1 : 1 }
        i += 1
    }
    if aCount == bCount { return 0 }
    return aCount < bCount ? -1 : 1
}

/// Descending by size, ties broken on raw name bytes and then on slot.
///
/// The tie-break is what stops the chart flickering. `sort` is introsort, which is
/// not stable, so a directory of twenty identical 4 KiB files — twenty equal
/// claims on the arc — would otherwise come back in a different order each tick,
/// and with it a different set of colours. Byte order rather than `String` order
/// because determinism is the requirement here, not locale-correct collation.
@inline(__always)
func childSortsBefore(_ a: SizedChild, _ b: SizedChild,
                      _ names: UnsafeBufferPointer<UInt8>) -> Bool {
    if a.size != b.size { return a.size > b.size }
    let byName = compareNameBytes(a, b, names)
    if byName != 0 { return byName < 0 }
    return a.ref.rawValue < b.ref.rawValue
}

// MARK: - Culling

/// Running totals for the siblings of one parent that fell below the minimum
/// sweep, collapsed into the single trailing `.aggregated` wedge.
struct CulledSiblings {
    var count: Int = 0
    /// Combined size under the active basis; this is the aggregate's arc.
    var size: UInt64 = 0
    var physicalBytes: UInt64 = 0
    var logicalBytes: UInt64 = 0
    var itemCount: UInt64 = 0
    /// The largest of them under the sibling ordering. The aggregate borrows its
    /// `NodeRef`: `Wedge.id` is `node.rawValue`, so two aggregates in one layout
    /// carrying the same sentinel ref would collapse into one another in any
    /// `ForEach`. Borrowing is safe because a culled node is by definition not
    /// emitted anywhere else, and it gives a click on the aggregate somewhere
    /// real to land.
    var representative: SizedChild?

    var isEmpty: Bool { count == 0 }

    @inline(__always)
    mutating func absorb(_ child: SizedChild, _ names: UnsafeBufferPointer<UInt8>) {
        count += 1
        size &+= child.size
        physicalBytes &+= child.physicalBytes
        logicalBytes &+= child.logicalBytes
        itemCount &+= UInt64(child.itemCount)
        if let current = representative, !childSortsBefore(child, current, names) { return }
        representative = child
    }
}

/// Label for an aggregate wedge. The view is free to render `kind` its own way;
/// this is here so `Wedge.name` is never an empty string the inspector has to
/// special-case.
func aggregatedLabel(count: Int) -> String {
    count == 1 ? "1 smaller item" : "\(count) smaller items"
}
