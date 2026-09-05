import Foundation
import LoupeCore
import SwiftUI

public extension BubbleCircle {
    /// The number this circle is currently drawn against.
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

/// One entry in the list representation of the pack that VoiceOver navigates.
public struct BubbleRosterEntry: Sendable, Identifiable, Hashable {
    public let position: BubblePosition
    public let circle: BubbleCircle
    public let label: String
    public var id: BubblePosition { position }
    /// The rotor reads a short name; the element itself carries the sentence.
    public var rotorLabel: String {
        SunburstDescription.chartLabel(for: circle.kind, name: circle.name)
    }
}

/// Everything the bubble chart says out loud.
///
/// The sentences themselves come from `SunburstDescription.itemSentence`, so the
/// same folder is described in the same words whichever view is on screen. Only
/// the way a share and a container are found differs, because a circle pack
/// recovers those from nesting rather than from angles.
public enum BubbleDescription {

    /// What this view is honestly good for, in one sentence, said out loud
    /// rather than left for the user to discover.
    ///
    /// Circles do not tile. A folder's children fill a fraction of it that
    /// depends on how well they happened to pack, so two similar sizes are
    /// genuinely hard to compare here in a way they are not in a treemap. The
    /// contract says so; a chart this enjoyable to look at has an obligation to
    /// repeat it rather than let the picture imply a precision it does not have.
    public static let comparisonCaveat =
        "Circles nest, they do not tile — good for seeing what is inside what, "
        + "poor for telling two similar sizes apart. Switch to the treemap to compare."

    /// The short form, for a footer sitting next to the provenance line.
    public static let shortCaveat = "Sizes are approximate — circles do not tile."

    public static func shareOfParent(_ position: BubblePosition, in index: BubbleIndex,
                                     basis: SizeBasis) -> Double {
        guard let i = index.circleIndex(of: position) else { return 0 }
        let circle = index.circles[i]
        let denominatorBytes: UInt64
        let denominatorArea: Double
        if let parent = index.parentIndex(of: i) {
            denominatorBytes = index.circles[parent].bytes(basis)
            denominatorArea = index.circles[parent].area
        } else {
            denominatorBytes = basis == .physical ? index.totalPhysicalBytes : index.totalLogicalBytes
            denominatorArea = 0
        }
        if denominatorBytes > 0 {
            return min(1, Double(circle.bytes(basis)) / Double(denominatorBytes))
        }
        // A zero-byte parent still has a drawn extent, so fall back to geometry
        // rather than claiming zero. Areas here are only as good as the packing,
        // which is exactly what `comparisonCaveat` warns about — and it is still
        // better than saying nothing.
        return denominatorArea > 0 ? min(1, circle.area / denominatorArea) : 0
    }

    public static func parentName(of position: BubblePosition, in index: BubbleIndex) -> String {
        guard let i = index.circleIndex(of: position), let parent = index.parentIndex(of: i) else {
            return index.focusName
        }
        return index.circles[parent].name
    }

    public static func label(for position: BubblePosition, in index: BubbleIndex,
                             basis: SizeBasis) -> String {
        guard let circle = index[position] else { return "" }
        return SunburstDescription.itemSentence(
            name: circle.name, kind: circle.kind,
            size: ByteFormat.string(circle.bytes(basis), basis: basis),
            share: SunburstDescription.percentPhrase(shareOfParent(position, in: index, basis: basis)),
            container: parentName(of: position, in: index),
            itemCount: circle.itemCount)
    }

    public static func summary(for position: BubblePosition, in index: BubbleIndex,
                               basis: SizeBasis) -> String {
        guard let circle = index[position] else { return "" }
        let size = ByteFormat.string(circle.bytes(basis), basis: basis)
        let share = SunburstDescription.percentPhrase(shareOfParent(position, in: index, basis: basis))
        return "\(SunburstDescription.chartLabel(for: circle.kind, name: circle.name)) — \(size), \(share)"
    }

    /// The floating readout's lines, built by the same rules the other two
    /// charts use.
    public static func readout(for position: BubblePosition, in index: BubbleIndex,
                               basis: SizeBasis) -> ChartReadoutText? {
        guard let circle = index[position] else { return nil }
        return SunburstDescription.readoutText(
            name: circle.name, kind: circle.kind,
            size: ByteFormat.string(circle.bytes(basis), basis: basis),
            share: SunburstDescription.percentPhrase(shareOfParent(position, in: index, basis: basis)),
            container: parentName(of: position, in: index))
    }

    // MARK: - Chrome

    public static func focusTitle(_ index: BubbleIndex) -> String {
        index.focusName.isEmpty ? "All items" : index.focusName
    }

    public static func focusTotal(_ index: BubbleIndex, basis: SizeBasis) -> String {
        ByteFormat.string(basis == .physical ? index.totalPhysicalBytes : index.totalLogicalBytes,
                          basis: basis)
    }

    public static func provenance(_ index: BubbleIndex) -> String {
        index.isComplete
            ? SunburstDescription.asOf(index.scannedAt)
            : SunburstDescription.asOf(index.scannedAt) + " · still measuring"
    }

    /// The footer line: when we looked, and what this shape can and cannot tell
    /// you. Both, always — the caveat is not an easter egg for the curious.
    public static func footer(_ index: BubbleIndex) -> String {
        "\(provenance(index)) · \(shortCaveat)"
    }

    public static func accessibilitySummary(_ index: BubbleIndex, basis: SizeBasis) -> String {
        "Space used in \(focusTitle(index)), \(focusTotal(index, basis: basis)), "
            + "\(provenance(index)). \(index.circles.count.formatted()) items charted. "
            + comparisonCaveat
    }

    // MARK: - Roster

    /// The pack as an ordered list, for assistive technology. Same shape and
    /// same reasoning as the other two: every one of the outer levels, where the
    /// structure is, plus the largest of everything else, and an honest count of
    /// what was left out.
    public static func roster(for index: BubbleIndex, basis: SizeBasis,
                              wholeDepthsThrough: Int = 1,
                              limit: Int = 400) -> (entries: [BubbleRosterEntry], omitted: Int) {
        guard !index.isEmpty else { return ([], 0) }

        var chosen: Set<Int> = []
        var overflow: [Int] = []
        for i in index.circles.indices {
            if Int(index.circles[i].depth) <= wholeDepthsThrough { chosen.insert(i) }
            else { overflow.append(i) }
        }
        if chosen.count > limit {
            let ranked = chosen.sorted { index.circles[$0].radius > index.circles[$1].radius }
            chosen = Set(ranked.prefix(limit))
            overflow = []
        } else if !overflow.isEmpty {
            overflow.sort { index.circles[$0].radius > index.circles[$1].radius }
            chosen.formUnion(overflow.prefix(limit - chosen.count))
        }

        let omitted = index.circles.count - chosen.count
        let entries = chosen.sorted().compactMap { i -> BubbleRosterEntry? in
            guard let position = index.position(at: i) else { return nil }
            return BubbleRosterEntry(position: position, circle: index.circles[i],
                                     label: label(for: position, in: index, basis: basis))
        }
        return (entries, max(0, omitted))
    }

    public static func omissionNotice(_ omitted: Int) -> String {
        SunburstDescription.omissionNotice(omitted)
    }
}

// MARK: - Search

public extension SunburstSearch {
    /// The bubble chart's half of the search, resolved once per layout and
    /// query rather than per frame. Same walk as the treemap's, over the same
    /// geometric parent links.
    func result(in index: BubbleIndex) -> SunburstSearchResult {
        guard isActive else { return .inactive }
        var matched: Set<UInt32> = []
        var onPath: Set<UInt32> = []
        for (i, circle) in index.circles.enumerated() {
            guard matches(SunburstDescription.chartLabel(for: circle.kind, name: circle.name))
            else { continue }
            matched.insert(circle.id)
            var current = i
            while let parent = index.parentIndex(of: current) {
                if !onPath.insert(index.circles[parent].id).inserted { break }
                current = parent
            }
        }
        onPath.subtract(matched)
        return SunburstSearchResult(query: query, matched: matched, onPath: onPath)
    }
}

// MARK: - Legend

public extension ChartLegendEntry {
    /// The outermost level, largest first. That level *is* the categorical
    /// scale: one entry per top-level folder under the focus, which is exactly
    /// what `colorSeed` indexes.
    static func entries(for index: BubbleIndex, palette: SunburstPalette,
                        scheme: ColorScheme, basis: SizeBasis,
                        limit: Int = 12) -> [ChartLegendEntry] {
        index.circles(atDepth: 0)
            .sorted { $0.radius > $1.radius }
            .prefix(limit)
            .map { circle in
                ChartLegendEntry(
                    id: circle.id,
                    name: SunburstDescription.chartLabel(for: circle.kind, name: circle.name),
                    detail: ByteFormat.string(circle.bytes(basis), basis: basis),
                    swatch: palette.swatch(seed: circle.colorSeed, ring: 0,
                                           kind: circle.kind, scheme: scheme))
            }
    }
}
