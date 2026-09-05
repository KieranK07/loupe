import CoreGraphics
import Foundation
import LoupeCore

/// Turning tile geometry into label slots.
///
/// Shares `LabelPlacement` with the sunburst, so the non-overlap rule is
/// literally the same code and the two views cannot drift apart on it. What
/// differs is only where a label may legitimately go, and in a treemap that is
/// a question about *stacking*: tiles arrive outermost-first and children are
/// painted over their parents, so the middle of a folder is usually somebody
/// else's colour by the time the labels go on.
public enum TreemapLabels {
    public static let font = SunburstLabels.font
    public static let nominalLineHeight = SunburstLabels.nominalLineHeight
    /// The same legibility floor as the sunburst, for the same reason: four
    /// characters and an elision at 10pt is about 24pt of run, and a fragment
    /// shorter than that identifies nothing.
    public static let minimumLabelWidth = SunburstLabels.minimumLabelWidth
    /// Clear space kept inside a tile's own edges.
    public static let inset: Double = 4

    /// How much of a tile has to survive its children before its name may be
    /// written across the middle of it. Below this the middle of the tile is
    /// mostly somebody else's colour, and a name there would look like a label
    /// for the child underneath it.
    public static let exposureThreshold: Double = 0.55

    /// A group header is drawn on a plate over its own children, so it needs a
    /// tile big enough that the plate reads as belonging to the region rather
    /// than covering it.
    public static let minimumHeaderWidth: Double = 64
    public static let minimumHeaderHeight: Double = 26
    public static let headerInset: Double = 5
    public static let maximumHeaderWidth: Double = 200

    public static let slotLimit: Int = 140

    public static func slots(for index: TreemapIndex, metrics: TreemapMetrics,
                             hovered: TreemapPosition? = nil,
                             keyboardFocus: TreemapPosition? = nil,
                             limit: Int = slotLimit) -> [LabelSlot] {
        var slots: [LabelSlot] = []
        var forced = Set<UInt32>()
        guard !metrics.isDegenerate else { return slots }

        for position in [hovered, keyboardFocus] {
            guard let position, let i = index.tileIndex(of: position) else { continue }
            guard forced.insert(index.tiles[i].id).inserted else { continue }
            if let slot = forcedSlot(at: i, in: index, metrics: metrics) { slots.append(slot) }
        }
        guard limit > 0 else { return slots }

        var candidates: [(index: Int, priority: Double)] = []
        candidates.reserveCapacity(min(limit * 2, index.tiles.count))
        for i in index.tiles.indices where !forced.contains(index.tiles[i].id) {
            let rect = metrics.rect(for: index.tiles[i])
            // Cull before sorting, not after: a layout can hold four thousand
            // tiles and almost none of them are big enough to hold a name, so
            // sorting the lot every frame would be work spent on nothing.
            let fitsALabel = rect.width >= minimumLabelWidth + inset * 2
                && rect.height >= nominalLineHeight + inset * 2
            let couldBeHeader = index.tiles[i].depth == 0
                && rect.width >= minimumHeaderWidth && rect.height >= minimumHeaderHeight
            guard fitsALabel || couldBeHeader else { continue }
            candidates.append((i, Double(rect.width * rect.height)))
        }
        // Drawn area, so the biggest shapes claim their names first — the same
        // rule the sunburst applies to arc length.
        candidates.sort { a, b in
            a.priority == b.priority ? a.index < b.index : a.priority > b.priority
        }

        var produced = 0
        for candidate in candidates {
            guard produced < limit else { break }
            if let slot = slot(at: candidate.index, in: index, metrics: metrics,
                               priority: candidate.priority) {
                slots.append(slot)
                produced += 1
            }
        }
        return slots
    }

    // MARK: - One tile

    static func slot(at i: Int, in index: TreemapIndex, metrics: TreemapMetrics,
                     priority: Double) -> LabelSlot? {
        let tile = index.tiles[i]
        let text = SunburstDescription.chartLabel(for: tile.kind, name: tile.name)
        guard !text.isEmpty else { return nil }

        if index.exposure[i].visibleFraction >= exposureThreshold {
            // Enough of the tile is its own colour to write across it. Use the
            // part that actually survived rather than the whole frame, so a
            // folder with children down one side still labels the side that is
            // showing.
            let visible = intersection(index.exposure[i].visibleBounds, tile.frame)
            let rect = metrics.rect(for: visible).insetBy(dx: inset, dy: inset)
            guard rect.width >= minimumLabelWidth, rect.height >= nominalLineHeight else { return nil }
            return LabelSlot(id: tile.id, text: text,
                             anchor: CGPoint(x: rect.midX, y: rect.midY), rotation: 0,
                             widthBudget: rect.width, heightBudget: rect.height,
                             priority: priority)
        }

        // Buried under its children. Only the outermost level earns a header:
        // the top-level folders are the coarse read of the whole volume, and
        // losing their names to their own contents would leave the map
        // unreadable. Anything deeper stays unlabelled rather than stacking
        // plate on plate.
        guard tile.depth == 0 else { return nil }
        let rect = metrics.rect(for: tile)
        guard rect.width >= minimumHeaderWidth, rect.height >= minimumHeaderHeight else { return nil }
        let width = min(rect.width - headerInset * 2 - inset * 2, maximumHeaderWidth)
        guard width >= minimumLabelWidth else { return nil }
        return LabelSlot(id: tile.id, text: text,
                         anchor: CGPoint(x: rect.midX,
                                         y: rect.minY + headerInset + nominalLineHeight / 2 + inset / 2),
                         rotation: 0,
                         widthBudget: width, heightBudget: nominalLineHeight + 2,
                         priority: priority, wantsPlate: true)
    }

    static func forcedSlot(at i: Int, in index: TreemapIndex, metrics: TreemapMetrics) -> LabelSlot? {
        let tile = index.tiles[i]
        let text = SunburstDescription.chartLabel(for: tile.kind, name: tile.name)
        guard !text.isEmpty else { return nil }
        let rect = metrics.rect(for: tile).insetBy(dx: inset, dy: inset)
        return LabelSlot(id: tile.id, text: text,
                         anchor: CGPoint(x: rect.midX, y: rect.midY), rotation: 0,
                         widthBudget: max(0, rect.width), heightBudget: max(0, rect.height),
                         priority: 0, isForced: true)
    }

    static func intersection(_ a: TreemapRect, _ b: TreemapRect) -> TreemapRect {
        let x = max(a.x, b.x), y = max(a.y, b.y)
        let maxX = min(a.maxX, b.maxX), maxY = min(a.maxY, b.maxY)
        return TreemapRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
    }
}
