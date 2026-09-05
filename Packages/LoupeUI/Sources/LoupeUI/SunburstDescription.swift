import Foundation
import LoupeCore

public extension Wedge {
    /// The number this wedge is currently drawn against.
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

/// One entry in the list representation of the chart that VoiceOver navigates.
public struct SunburstRosterEntry: Sendable, Identifiable, Hashable {
    public let position: SunburstPosition
    public let wedge: Wedge
    public let label: String
    public var id: SunburstPosition { position }
}

/// Everything the chart says out loud.
///
/// Kept apart from the view so the wording is testable, and so the same
/// sentence describes a wedge whether it is being hovered, read by VoiceOver or
/// announced after a keypress. One description, one place to get it right.
public enum SunburstDescription {
    // MARK: - Share of parent

    /// A wedge's share of its parent, in `0...1`.
    ///
    /// Taken from bytes rather than from the drawn angle wherever a denominator
    /// exists. The two agree by construction, but bytes are the thing the user
    /// is actually being told, and a share derived from the number on screen can
    /// never drift from it.
    public static func shareOfParent(_ position: SunburstPosition, in index: SunburstIndex,
                                     basis: SizeBasis) -> Double {
        guard let wedge = index[position] else { return 0 }
        let navigator = SunburstNavigator(index: index)
        let denominatorBytes: UInt64
        let denominatorSweep: Double
        if let parentPosition = navigator.parent(of: position), let parent = index[parentPosition] {
            denominatorBytes = parent.bytes(basis)
            denominatorSweep = parent.sweep
        } else {
            denominatorBytes = basis == .physical ? index.totalPhysicalBytes : index.totalLogicalBytes
            denominatorSweep = SunburstAngle.fullTurn
        }
        if denominatorBytes > 0 {
            return min(1, Double(wedge.bytes(basis)) / Double(denominatorBytes))
        }
        // A zero-byte parent still has a drawn extent, so fall back to geometry
        // rather than claiming zero.
        return denominatorSweep > 0 ? min(1, wedge.sweep / denominatorSweep) : 0
    }

    public static func percentPhrase(_ share: Double) -> String {
        let percent = share * 100
        if percent > 0, percent < 0.5 { return "less than 1 percent" }
        return "\(Int(percent.rounded())) percent"
    }

    public static func parentName(of position: SunburstPosition, in index: SunburstIndex) -> String {
        let navigator = SunburstNavigator(index: index)
        if let parentPosition = navigator.parent(of: position), let parent = index[parentPosition] {
            return parent.name
        }
        return index.focusName
    }

    // MARK: - Labels

    /// The full spoken description of a wedge: what it is, how big it is, and
    /// how much of its container it accounts for.
    public static func label(for position: SunburstPosition, in index: SunburstIndex,
                             basis: SizeBasis) -> String {
        guard let wedge = index[position] else { return "" }
        let share = percentPhrase(shareOfParent(position, in: index, basis: basis))
        let size = ByteFormat.string(wedge.bytes(basis), basis: basis)
        let container = parentName(of: position, in: index)

        return itemSentence(name: wedge.name, kind: wedge.kind, size: size,
                            share: share, container: container, itemCount: wedge.itemCount)
    }

    /// A short line for a hover readout or a tooltip, where the container name
    /// is already visible elsewhere.
    public static func summary(for position: SunburstPosition, in index: SunburstIndex,
                               basis: SizeBasis) -> String {
        guard let wedge = index[position] else { return "" }
        let size = ByteFormat.string(wedge.bytes(basis), basis: basis)
        let share = percentPhrase(shareOfParent(position, in: index, basis: basis))
        return "\(wedge.name) — \(size), \(share)"
    }

    /// The name to paint *on* a shape, as opposed to the sentence read aloud.
    ///
    /// An aggregate carries the `NodeRef` and the name of the largest sibling it
    /// swallowed, so drawing `wedge.name` on one would put a real folder's name
    /// on a shape that is mostly other folders. Say what it is instead.
    public static func chartLabel(for kind: WedgeKind, name: String) -> String {
        if case .aggregated(let count) = kind {
            return "\(count.formatted()) smaller items"
        }
        return name
    }

    public static func chartLabel(for wedge: Wedge) -> String {
        chartLabel(for: wedge.kind, name: wedge.name)
    }

    // MARK: - Readout

    /// The three lines the floating readout says about an item.
    ///
    /// Shared by both charts for the same reason `itemSentence` is: the two
    /// views must not be able to describe the same folder differently.
    public static func readoutText(name: String, kind: WedgeKind, size: String,
                                   share: String, container: String) -> ChartReadoutText {
        let detail = "\(size) · \(share) of \(container)"
        switch kind {
        case .real:
            return ChartReadoutText(title: name, detail: detail)
        case .aggregated(let count):
            return ChartReadoutText(
                title: "\(count.formatted()) smaller items",
                detail: detail,
                footnote: "Each is too small to draw separately. Zoom into the folder around them to reach these.")
        case .stillScanning:
            return ChartReadoutText(title: name, detail: detail,
                                    footnote: "Still being measured, so this total will grow.")
        }
    }

    public static func readout(for position: SunburstPosition, in index: SunburstIndex,
                               basis: SizeBasis) -> ChartReadoutText? {
        guard let wedge = index[position] else { return nil }
        return readoutText(name: wedge.name, kind: wedge.kind,
                           size: ByteFormat.string(wedge.bytes(basis), basis: basis),
                           share: percentPhrase(shareOfParent(position, in: index, basis: basis)),
                           container: parentName(of: position, in: index))
    }

    /// The one sentence that describes an item, wherever it is being read from.
    ///
    /// Shared by the sunburst and the treemap so the two views cannot drift
    /// into describing the same folder differently.
    public static func itemSentence(name: String, kind: WedgeKind, size: String,
                                    share: String, container: String,
                                    itemCount: UInt32) -> String {
        switch kind {
        case .real:
            var sentence = "\(name), \(size), \(share) of \(container)"
            if itemCount > 1 { sentence += ", \(itemCount.formatted()) items" }
            return sentence + "."
        case .aggregated(let count):
            return "\(count.formatted()) smaller items together, \(size), \(share) of \(container). "
                + "Shown as one shape because each is too small to draw separately."
        case .stillScanning:
            return "\(name), \(size) so far, \(share) of \(container). "
                + "Still being measured, so this total will grow."
        }
    }

    // MARK: - Chrome

    public static func focusTitle(_ index: SunburstIndex) -> String {
        index.focusName.isEmpty ? "All items" : index.focusName
    }

    public static func focusTotal(_ index: SunburstIndex, basis: SizeBasis) -> String {
        ByteFormat.string(basis == .physical ? index.totalPhysicalBytes : index.totalLogicalBytes,
                          basis: basis)
    }

    /// A live filesystem is never a consistent snapshot, so the chart always
    /// says when it looked rather than implying it is looking now.
    public static func asOf(_ date: Date) -> String {
        guard date != .distantPast else { return "not measured yet" }
        return "as of " + date.formatted(date: .omitted, time: .shortened)
    }

    public static func provenance(_ index: SunburstIndex) -> String {
        index.isComplete ? asOf(index.scannedAt) : asOf(index.scannedAt) + " · still measuring"
    }

    // MARK: - Roster

    /// The chart as an ordered list, for assistive technology.
    ///
    /// A layout can hold six thousand wedges. Handing every one of them to
    /// VoiceOver would technically make them all "reachable" while making none
    /// of them findable, so the roster keeps the whole of the inner rings —
    /// which is where the structure is — plus the largest of everything else,
    /// and says plainly how many it left out and how to get to them.
    public static func roster(for index: SunburstIndex, basis: SizeBasis,
                              wholeRingsThrough: Int = 1,
                              limit: Int = 400) -> (entries: [SunburstRosterEntry], omitted: Int) {
        guard !index.isEmpty else { return ([], 0) }

        var chosen = Set<SunburstPosition>()
        var overflow: [SunburstPosition] = []
        for ring in 0..<index.ringCount {
            let range = index.ringRanges[ring]
            for i in range {
                let position = SunburstPosition(ring: ring, offset: i - range.lowerBound)
                if ring <= wholeRingsThrough { chosen.insert(position) } else { overflow.append(position) }
            }
        }
        if chosen.count > limit {
            // Even the inner rings can overflow on a pathological tree; keep the
            // largest of them rather than an arbitrary angular prefix.
            let ranked = chosen.sorted { (index[$0]?.sweep ?? 0) > (index[$1]?.sweep ?? 0) }
            chosen = Set(ranked.prefix(limit))
            overflow = []
        } else if !overflow.isEmpty {
            overflow.sort { (index[$0]?.sweep ?? 0) > (index[$1]?.sweep ?? 0) }
            chosen.formUnion(overflow.prefix(limit - chosen.count))
        }

        let omitted = index.wedges.count - chosen.count
        let entries = chosen
            .sorted { a, b in
                a.ring == b.ring
                    ? (index[a]?.startAngle ?? 0) < (index[b]?.startAngle ?? 0)
                    : a.ring < b.ring
            }
            .compactMap { position -> SunburstRosterEntry? in
                guard let wedge = index[position] else { return nil }
                return SunburstRosterEntry(position: position, wedge: wedge,
                                           label: label(for: position, in: index, basis: basis))
            }
        return (entries, max(0, omitted))
    }

    public static func omissionNotice(_ omitted: Int) -> String {
        "\(omitted.formatted()) further items are not listed here. Zoom into a folder to reach them."
    }
}
