import Foundation
import LoupeCore

public extension TreemapTile {
    /// The number this tile is currently drawn against.
    func bytes(_ basis: SizeBasis) -> UInt64 {
        basis == .physical ? physicalBytes : logicalBytes
    }

    var isAggregated: Bool {
        if case .aggregated = kind { return true }
        return false
    }

    var aggregatedCount: Int? {
        if case .aggregated(let count) = kind { return count }
        return nil
    }

    var isStillScanning: Bool { kind == .stillScanning }
}

/// One entry in the list representation of the treemap that VoiceOver navigates.
public struct TreemapRosterEntry: Sendable, Identifiable, Hashable {
    public let position: TreemapPosition
    public let tile: TreemapTile
    public let label: String
    public var id: TreemapPosition { position }
    /// The rotor reads a short name; the element itself carries the sentence.
    public var rotorLabel: String { SunburstDescription.chartLabel(for: tile.kind, name: tile.name) }
}

/// Everything the treemap says out loud.
///
/// The sentences themselves come from `SunburstDescription.itemSentence`, so
/// the same folder is described in the same words whichever view is on screen.
/// Only the way a share and a container are found differs, because a treemap
/// recovers those from nesting rather than from angles.
public enum TreemapDescription {
    public static func shareOfParent(_ position: TreemapPosition, in index: TreemapIndex,
                                     basis: SizeBasis) -> Double {
        guard let i = index.tileIndex(of: position) else { return 0 }
        let tile = index.tiles[i]
        let denominatorBytes: UInt64
        let denominatorArea: Double
        if let parent = index.parentIndex(of: i) {
            denominatorBytes = index.tiles[parent].bytes(basis)
            denominatorArea = index.tiles[parent].frame.area
        } else {
            denominatorBytes = basis == .physical ? index.totalPhysicalBytes : index.totalLogicalBytes
            denominatorArea = 1
        }
        if denominatorBytes > 0 {
            return min(1, Double(tile.bytes(basis)) / Double(denominatorBytes))
        }
        // A zero-byte parent still has a drawn extent, so fall back to geometry
        // rather than claiming zero.
        return denominatorArea > 0 ? min(1, tile.frame.area / denominatorArea) : 0
    }

    public static func parentName(of position: TreemapPosition, in index: TreemapIndex) -> String {
        guard let i = index.tileIndex(of: position), let parent = index.parentIndex(of: i) else {
            return index.focusName
        }
        return index.tiles[parent].name
    }

    public static func label(for position: TreemapPosition, in index: TreemapIndex,
                             basis: SizeBasis) -> String {
        guard let tile = index[position] else { return "" }
        return SunburstDescription.itemSentence(
            name: tile.name, kind: tile.kind,
            size: ByteFormat.string(tile.bytes(basis), basis: basis),
            share: SunburstDescription.percentPhrase(shareOfParent(position, in: index, basis: basis)),
            container: parentName(of: position, in: index),
            itemCount: tile.itemCount)
    }

    public static func summary(for position: TreemapPosition, in index: TreemapIndex,
                               basis: SizeBasis) -> String {
        guard let tile = index[position] else { return "" }
        let size = ByteFormat.string(tile.bytes(basis), basis: basis)
        let share = SunburstDescription.percentPhrase(shareOfParent(position, in: index, basis: basis))
        return "\(SunburstDescription.chartLabel(for: tile.kind, name: tile.name)) — \(size), \(share)"
    }

    /// The floating readout's three lines, built by the same rules the
    /// sunburst uses.
    public static func readout(for position: TreemapPosition, in index: TreemapIndex,
                               basis: SizeBasis) -> ChartReadoutText? {
        guard let tile = index[position] else { return nil }
        return SunburstDescription.readoutText(
            name: tile.name, kind: tile.kind,
            size: ByteFormat.string(tile.bytes(basis), basis: basis),
            share: SunburstDescription.percentPhrase(shareOfParent(position, in: index, basis: basis)),
            container: parentName(of: position, in: index))
    }

    // MARK: - Chrome

    public static func focusTitle(_ index: TreemapIndex) -> String {
        index.focusName.isEmpty ? "All items" : index.focusName
    }

    public static func focusTotal(_ index: TreemapIndex, basis: SizeBasis) -> String {
        ByteFormat.string(basis == .physical ? index.totalPhysicalBytes : index.totalLogicalBytes,
                          basis: basis)
    }

    public static func provenance(_ index: TreemapIndex) -> String {
        index.isComplete
            ? SunburstDescription.asOf(index.scannedAt)
            : SunburstDescription.asOf(index.scannedAt) + " · still measuring"
    }

    // MARK: - Roster

    /// The map as an ordered list, for assistive technology. Same shape and
    /// same reasoning as the sunburst's: every one of the outer levels, where
    /// the structure is, plus the largest of everything else, and an honest
    /// count of what was left out.
    public static func roster(for index: TreemapIndex, basis: SizeBasis,
                              wholeDepthsThrough: Int = 1,
                              limit: Int = 400) -> (entries: [TreemapRosterEntry], omitted: Int) {
        guard !index.isEmpty else { return ([], 0) }

        var chosen: Set<Int> = []
        var overflow: [Int] = []
        for i in index.tiles.indices {
            if Int(index.tiles[i].depth) <= wholeDepthsThrough { chosen.insert(i) } else { overflow.append(i) }
        }
        if chosen.count > limit {
            let ranked = chosen.sorted { index.tiles[$0].frame.area > index.tiles[$1].frame.area }
            chosen = Set(ranked.prefix(limit))
            overflow = []
        } else if !overflow.isEmpty {
            overflow.sort { index.tiles[$0].frame.area > index.tiles[$1].frame.area }
            chosen.formUnion(overflow.prefix(limit - chosen.count))
        }

        let omitted = index.tiles.count - chosen.count
        let entries = chosen.sorted().compactMap { i -> TreemapRosterEntry? in
            guard let position = index.position(at: i) else { return nil }
            return TreemapRosterEntry(position: position, tile: index.tiles[i],
                                      label: label(for: position, in: index, basis: basis))
        }
        return (entries, max(0, omitted))
    }

    public static func omissionNotice(_ omitted: Int) -> String {
        SunburstDescription.omissionNotice(omitted)
    }
}
