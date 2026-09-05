import Foundation
import LoupeCore
import SwiftUI

/// How a trail of folders is shortened when it will not fit.
///
/// Pure and separate from the view: a path fifteen deep is normal on a Mac, and
/// what gets dropped when that happens is a decision worth testing rather than
/// a `lineLimit` and a shrug.
public enum ChartBreadcrumbTrail {
    public enum Entry: Sendable, Hashable, Identifiable {
        case crumb(Breadcrumb)
        /// How many folders were left out here.
        case elision(Int)

        public var id: String {
            switch self {
            case .crumb(let crumb): "c\(crumb.node.rawValue)"
            case .elision(let count): "e\(count)"
            }
        }
    }

    /// What happened to the trail between two navigations.
    ///
    /// Which one it was decides how the crumbs move, and the distinction that
    /// matters is `replaced`: when the user switches volume, *nothing* in the
    /// old trail survives into the new one, and sliding the new crumbs in from
    /// where the old ones left would claim a continuity that does not exist.
    /// That case cross-fades. The other two slide.
    public enum Change: Sendable, Hashable {
        /// The old trail is a prefix of the new one — the user went in.
        case deeper
        /// The new trail is a prefix of the old one — the user came out.
        case shallower
        /// Neither is a prefix of the other. A different disk, or a jump.
        case replaced
        case unchanged
    }

    /// Compared by node, not by name: two different folders can share a name,
    /// and two scans of the same folder must not read as a jump just because
    /// the layout was regenerated underneath.
    public static func change(from old: [Breadcrumb], to new: [Breadcrumb]) -> Change {
        let oldNodes = old.map(\.node), newNodes = new.map(\.node)
        if oldNodes == newNodes { return .unchanged }
        // The empty trail is a prefix of everything, which would make the first
        // rail of a session a descent from nowhere and slide six crumbs in from
        // the right at once. There is nothing for that motion to be about, so it
        // is excluded before the prefix tests rather than after them.
        guard !oldNodes.isEmpty, !newNodes.isEmpty else { return .replaced }
        if oldNodes.count < newNodes.count, newNodes.starts(with: oldNodes) { return .deeper }
        if newNodes.count < oldNodes.count, oldNodes.starts(with: newNodes) { return .shallower }
        return .replaced
    }

    /// Keep the root and the deep end; drop the middle.
    ///
    /// The two ends are the parts anyone reads — where you started and where
    /// you are — and the middle of a long path is the part that is the same on
    /// every Mac.
    public static func condensed(_ crumbs: [Breadcrumb], limit: Int = 5) -> [Entry] {
        guard limit >= 2 else { return crumbs.suffix(1).map(Entry.crumb) }
        guard crumbs.count > limit else { return crumbs.map(Entry.crumb) }
        let tail = crumbs.suffix(limit - 1)
        return [.crumb(crumbs[0]), .elision(crumbs.count - limit)] + tail.map(Entry.crumb)
    }
}

/// The path into the disk, floating over the chart.
///
/// Every crumb but the last is a way back out. The last one is where you are,
/// so it is a label rather than a button — a control that does nothing when you
/// press it is worse than no control. At the root there is only that one crumb
/// and nothing to navigate, so the rail draws nothing at all rather than
/// floating an ornament over the chart.
@MainActor
public struct ChartBreadcrumbRail: View {
    private let crumbs: [Breadcrumb]
    private let limit: Int
    private let onSelect: (NodeRef) -> Void

    public init(crumbs: [Breadcrumb], limit: Int = 5,
                onSelect: @escaping (NodeRef) -> Void) {
        self.crumbs = crumbs
        self.limit = limit
        self.onSelect = onSelect
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    /// The trail as it was on the pass before this one.
    ///
    /// Held rather than derived because the direction of the motion is a fact
    /// about *history*, and read in `body` rather than written there so the
    /// pass that performs the insertion still sees the old trail — the pass
    /// after it, where this has caught up, has no transition left to decide.
    @State private var previous: [Breadcrumb] = []

    public var body: some View {
        let entries = ChartBreadcrumbTrail.condensed(crumbs, limit: limit)
        let change = ChartBreadcrumbTrail.change(from: previous, to: crumbs)
        if entries.count > 1 {
            GlassEffectContainer(spacing: ChartGlassMetrics.containerSpacing) {
                HStack(spacing: 3) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                        if position > 0 { chevron }
                        view(for: entry, isLast: position == entries.count - 1)
                            // Each crumb keeps its own glass identity, so the
                            // ones that survive a navigation are recognised as
                            // the same shapes moving along the rail rather than
                            // as a new rail that happens to start the same way.
                            .glassEffectID(entry.id, in: glass)
                            .transition(transition(for: change))
                    }
                }
            }
            // The rail is redrawn ten times a second during a scan and the
            // trail is identical every time, so this is keyed on the ids: an
            // animation that re-ran on every regenerated layout would leave the
            // crumbs permanently mid-slide.
            .animation(ChartGlassMotion.crumbs(reduceMotion: reduceMotion),
                       value: entries.map(\.id))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Path into this scan"))
            .onChange(of: crumbs, initial: true) { _, new in previous = new }
        }
    }

    /// Crumbs enter and leave at the deep end, because that is where the trail
    /// actually changes: going in appends, coming out truncates. Sliding from
    /// the leading edge would send a new crumb across every crumb that did not
    /// move, which reads as the whole rail shifting rather than one item
    /// arriving.
    private func transition(for change: ChartBreadcrumbTrail.Change) -> AnyTransition {
        switch change {
        case .deeper, .shallower, .unchanged:
            .move(edge: .trailing).combined(with: .opacity)
        case .replaced:
            .opacity
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.compact.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func view(for entry: ChartBreadcrumbTrail.Entry, isLast: Bool) -> some View {
        switch entry {
        case .crumb(let crumb) where isLast:
            Text(crumb.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, ChartGlassMetrics.contentPadding)
                .padding(.vertical, 5)
                .chartGlassCapsule()
                .accessibilityLabel(Text("\(crumb.name), the folder you are looking at"))
        case .crumb(let crumb):
            Button {
                onSelect(crumb.node)
            } label: {
                Text(crumb.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.glass)
            .help("Zoom out to \(crumb.name)")
            .accessibilityHint(Text("Zooms out to this folder."))
        case .elision(let count):
            Text(verbatim: "…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .chartGlassCapsule()
                .help("\(count.formatted()) folders in between")
                .accessibilityLabel(Text("\(count.formatted()) folders in between"))
        }
    }
}

#Preview("Breadcrumb rail") {
    @Previewable @State var depth = 6
    let all = [
        Breadcrumb(node: .directory(1), name: "Macintosh HD"),
        Breadcrumb(node: .directory(2), name: "Users"),
        Breadcrumb(node: .directory(3), name: "kieran"),
        Breadcrumb(node: .directory(4), name: "Library"),
        Breadcrumb(node: .directory(5), name: "Application Support"),
        Breadcrumb(node: .directory(6), name: "com.apple.sharedfilelist"),
    ]
    VStack(spacing: 20) {
        ChartBreadcrumbRail(crumbs: Array(all.prefix(depth))) { _ in }
        Stepper("Depth", value: $depth, in: 1...all.count)
            .fixedSize()
    }
    .padding(40)
}
