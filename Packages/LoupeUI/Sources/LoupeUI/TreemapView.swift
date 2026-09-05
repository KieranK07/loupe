import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI

/// The treemap.
///
/// A toggleable alternative to the sunburst, for people who read areas better
/// than angles. It renders a `TreemapLayout` and nothing else — no route to the
/// arena, no route to a syscall, no navigation state of its own beyond which
/// tile the keyboard is on. Zooming is reported upward as a `NodeRef` and comes
/// back as the next layout, exactly as the sunburst does, which is what lets the
/// two views be swapped without the surrounding chrome noticing.
@MainActor
public struct TreemapView: View {
    private let layout: TreemapLayout
    private let basis: SizeBasis
    private let options: SunburstOptions
    private let search: SunburstSearch
    private let onHover: (TreemapTile?) -> Void
    private let onFocusChange: (TreemapTile?) -> Void
    private let onZoom: (NodeRef) -> Void
    private let onToggleInspector: () -> Void
    private let onSearchResults: (SunburstSearchResult) -> Void

    public init(layout: TreemapLayout,
                basis: SizeBasis = .physical,
                options: SunburstOptions = SunburstOptions(),
                search: SunburstSearch = .inactive,
                onHover: @escaping (TreemapTile?) -> Void = { _ in },
                onFocusChange: @escaping (TreemapTile?) -> Void = { _ in },
                onZoom: @escaping (NodeRef) -> Void = { _ in },
                onToggleInspector: @escaping () -> Void = {},
                onSearchResults: @escaping (SunburstSearchResult) -> Void = { _ in }) {
        self.layout = layout
        self.basis = basis
        self.options = options
        self.search = search
        self.onHover = onHover
        self.onFocusChange = onFocusChange
        self.onZoom = onZoom
        self.onToggleInspector = onToggleInspector
        self.onSearchResults = onSearchResults
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var index: TreemapIndex?
    /// The layout being zoomed away from, held only for the length of the
    /// transition so the tiles that survive it have somewhere to slide from.
    @State private var departing: TreemapIndex?
    @State private var progress: Double = 1
    @State private var table: SunburstColorTable?
    @State private var shading: TreemapShadingTable?
    @State private var searchResult: SunburstSearchResult = .inactive

    @State private var hovered: TreemapPosition?
    @State private var hoverChain: Set<TreemapPosition> = []
    /// How far the tile under the pointer has risen, `0...1`. A number rather
    /// than a Bool because a `Canvas` animates nothing by itself — anything in
    /// the map that moves has to arrive as a value SwiftUI is interpolating.
    @State private var hoverLift: Double = 0
    /// Where the pointer is, in the map's own coordinates. Only for placing the
    /// readout beside it — hit testing never reads this.
    @State private var hoverPoint: CGPoint?
    @State private var keyboardFocus: TreemapPosition?
    @FocusState private var hasKeyboardFocus: Bool

    // Derived rather than computed, for the same reason as the sunburst: every
    // entry costs a byte-count format and a parent lookup, and a computed
    // property would pay that on every body evaluation.
    @State private var roster: [TreemapRosterEntry] = []
    @State private var rotorEntries: [TreemapRosterEntry] = []
    @State private var rosterOmitted: Int = 0
    @State private var rosterBuiltAt: Date = .distantPast
    @State private var accessibilitySummary: String = "Space used. Nothing measured yet."
    /// Width ÷ height of the drawn map. Normalised tile coordinates are
    /// unit-free, so the navigator needs this to know what "nearest" means on a
    /// window that is not square.
    @State private var aspectRatio: Double = 1

    // MARK: - Body

    public var body: some View {
        GeometryReader { proxy in
            let metrics = TreemapMetrics(size: proxy.size)
            ZStack {
                if let index, let table, let shading, !index.isEmpty, !metrics.isDegenerate {
                    TreemapChart(index: index,
                                 metrics: metrics,
                                 table: table,
                                 shading: shading,
                                 departing: departing,
                                 progress: progress,
                                 hoverLift: hoverLift,
                                 hovered: hovered,
                                 hoverChain: hoverChain,
                                 keyboardFocus: keyboardFocus,
                                 search: searchResult,
                                 options: options)
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let point): updateHover(at: point, metrics: metrics)
                            case .ended: updateHover(at: nil, metrics: metrics)
                            }
                        }
                        .onTapGesture(coordinateSpace: .local) { point in
                            handleTap(at: point, metrics: metrics)
                        }

                    // Everything below floats *over* the tiles. Nothing goes
                    // behind them: the tiles are the content, and a lensing
                    // layer under a categorical fill fights the fill.
                    floatingChrome(index, table: table, bounds: proxy.size)
                } else if layout.tiles.isEmpty {
                    ContentUnavailableView("Nothing measured yet",
                                           systemImage: "square.grid.3x3",
                                           description: Text("Choose a volume or a folder to see what is using space."))
                } else {
                    // The first index is built when the view appears, one turn
                    // after this first body runs. Hold an empty frame rather
                    // than flashing "nothing measured yet" over a layout that
                    // plainly has tiles in it.
                    Color.clear
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: proxy.size, initial: true) { _, size in
                aspectRatio = size.height > 0 ? size.width / size.height : 1
            }
        }
        .overlay(alignment: .bottom) { provenanceFooter }
        .focusable()
        .focused($hasKeyboardFocus)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            arrow(press)
        }
        .onKeyPress(.return) { zoomIntoFocus() }
        .onKeyPress(.escape) { zoomOut() ? .handled : .ignored }
        .onKeyPress(.space) { onToggleInspector(); return .handled }
        .onChange(of: layoutKey, initial: true) { _, _ in adopt() }
        .onChange(of: paletteKey, initial: true) { _, _ in
            let palette = SunburstPalette(ramp: options.ramp)
            table = SunburstColorTable(palette: palette, scheme: colorScheme)
            // Built together and only together: the flat colour and the
            // gradient it spreads either side of have to come from one palette
            // and one scheme, or the tile a label was inked against is not the
            // tile that got drawn.
            shading = TreemapShadingTable(palette: palette, scheme: colorScheme)
        }
        .onChange(of: basis) { _, _ in rebuildRoster(force: true) }
        .onChange(of: searchKey, initial: true) { _, _ in resolveSearch() }
        .accessibilityElement(children: .contain)
        .accessibilityChildren { accessibilityRoster }
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text("Arrow keys move to the nearest item in that direction at the same level. Option with the down arrow enters the largest item inside this one, Option with the up arrow moves back out. Return zooms in, Escape zooms out, Space toggles the inspector."))
        .accessibilityRotor(Text("Largest items"),
                            entries: rotorEntries,
                            entryLabel: \TreemapRosterEntry.rotorLabel)
    }

    // MARK: - Chrome

    /// The glass layer: the path in, the colour key, and what the pointer is
    /// on. The same three pieces the sunburst floats, in the same places, so
    /// switching views does not move the furniture.
    @ViewBuilder
    private func floatingChrome(_ index: TreemapIndex, table: SunburstColorTable,
                                bounds: CGSize) -> some View {
        if options.showsBreadcrumbRail {
            ChartBreadcrumbRail(crumbs: index.breadcrumb) { onZoom($0) }
                .padding(ChartGlassMetrics.edgeInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        if options.showsLegend {
            ChartLegend(entries: ChartLegendEntry.entries(for: index, palette: table.palette,
                                                          scheme: table.scheme, basis: basis))
                .padding(ChartGlassMetrics.edgeInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        if options.showsHoverReadout, let point = hoverPoint, let position = hovered,
           let text = TreemapDescription.readout(for: position, in: index, basis: basis) {
            ChartReadoutOverlay(point: point, bounds: bounds) {
                // The glass picks up the colour of the tile it is describing,
                // faintly, and slides to the next colour as the pointer moves
                // between tiles. It is the one tint in the chrome, and it is
                // carrying information rather than decorating. The swatch goes
                // in rather than a colour because the interpolation has to know
                // where on the hue wheel it started.
                ChartHoverReadout(text, swatch: index[position].map { table.swatch(for: $0) })
            }
        }
    }

    @ViewBuilder
    private var provenanceFooter: some View {
        if options.showsProvenance, let index {
            // A live filesystem is never a consistent snapshot, so the map
            // always says when it looked instead of implying it is looking now.
            Text(TreemapDescription.provenance(index))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Layout adoption

    private struct LayoutKey: Hashable {
        let generation: UInt64
        let focus: UInt32
        let count: Int
    }

    private struct PaletteKey: Hashable {
        let ramp: SunburstRamp
        let scheme: ColorScheme
    }

    private struct SearchKey: Hashable {
        let query: String
        let generation: UInt64
        let focus: UInt32
    }

    private var layoutKey: LayoutKey {
        LayoutKey(generation: layout.generation, focus: layout.focus.rawValue, count: layout.tiles.count)
    }

    private var paletteKey: PaletteKey {
        PaletteKey(ramp: options.ramp, scheme: colorScheme)
    }

    private var searchKey: SearchKey {
        SearchKey(query: search.query, generation: layout.generation, focus: layout.focus.rawValue)
    }

    private func adopt() {
        let next = TreemapIndex(layout)
        let previous = index
        // A new generation ten times a second during a scan is not a zoom — the
        // tiles are just growing. Only a change of focus is a zoom, and only a
        // zoom animates; animating a scan's churn would be unreadable.
        let isZoom = previous.map { $0.focus != next.focus } ?? false
        let focusedNode = keyboardFocus.flatMap { previous?[$0]?.node }

        if isZoom, !reduceMotion {
            departing = previous
            index = next
            progress = 0
            Task { @MainActor in
                // A second main-actor turn, deliberately, for the reason
                // `SunburstView` spells out: setting progress to 0 and then to 1
                // inside one transaction is a no-op as far as SwiftUI is
                // concerned and the transition never plays.
                withAnimation(TreemapAnimation.animation(reduceMotion: false)) { progress = 1 }
                try? await Task.sleep(for: .seconds(TreemapAnimation.duration + 0.1))
                // Guarded, because a second zoom may have started in the
                // meantime and this index is now somebody else's `departing`.
                if progress >= 1 { departing = nil }
            }
        } else {
            departing = nil
            index = next
            progress = 1
        }

        if isZoom {
            keyboardFocus = TreemapNavigator(index: next, aspectRatio: aspectRatio).initialFocus()
        } else if let focusedNode, focusedNode.isValid, let moved = next.position(ofNode: focusedNode) {
            // Hold the keyboard on the same node as the layout regenerates under
            // it, otherwise a scan quietly steals the selection every 100 ms.
            keyboardFocus = moved
        } else if let current = keyboardFocus, next[current] == nil {
            keyboardFocus = nil
        }

        hovered = nil
        hoverChain = []
        hoverPoint = nil
        // Dropped rather than animated down: the tile it was lifting no longer
        // exists, so there is nothing for a settling animation to settle onto.
        hoverLift = 0
        onHover(nil)
        resolveSearch()
        rebuildRoster(force: isZoom || previous?.isComplete != next.isComplete)
    }

    private func resolveSearch() {
        guard let index else {
            searchResult = .inactive
            onSearchResults(.inactive)
            return
        }
        let resolved = search.result(in: index)
        searchResult = resolved
        onSearchResults(resolved)
    }

    // MARK: - Pointer

    private func updateHover(at point: CGPoint?, metrics: TreemapMetrics) {
        guard let index else { return }
        guard let point else {
            hoverPoint = nil
            setHover(nil, in: index)
            return
        }
        switch index.hit(at: point, metrics: metrics) {
        case .tile(let position):
            // Tracked at the pointer's own rate so the readout follows rather
            // than jumps; the expensive half below still only runs when the
            // answer to "which tile" changes.
            hoverPoint = point
            setHover(position, in: index)
        case .background, .none:
            hoverPoint = nil
            setHover(nil, in: index)
        }
    }

    private func setHover(_ position: TreemapPosition?, in index: TreemapIndex) {
        // The pointer reports at the display's refresh rate. Only tell the app
        // when the answer actually changed, or the inspector rebuilds for every
        // pixel of mouse travel.
        guard position != hovered else { return }
        let wasLifted = hovered != nil
        hovered = position
        hoverChain = position.map {
            Set(TreemapNavigator(index: index, aspectRatio: aspectRatio).ancestors(of: $0))
        } ?? []
        // Only the edges animate. Sweeping from one tile to the next leaves the
        // lift where it is and moves it, because re-running the rise for every
        // tile the pointer crosses turns a sweep across the map into a ripple.
        if wasLifted != (position != nil) {
            withAnimation(TreemapAnimation.lift(reduceMotion: reduceMotion)) {
                hoverLift = position == nil ? 0 : 1
            }
        }
        onHover(position.flatMap { index[$0] })
    }

    private func handleTap(at point: CGPoint, metrics: TreemapMetrics) {
        guard let index else { return }
        hasKeyboardFocus = true
        switch index.hit(at: point, metrics: metrics) {
        case .tile(let position):
            keyboardFocus = position
            announceFocus()
            zoom(into: position)
        case .background, .none:
            // The margin around the map is the treemap's answer to the
            // sunburst's centre disc: a pointer-only user needs a way back out
            // that does not depend on a keyboard.
            _ = zoomOut()
        }
    }

    // MARK: - Keyboard

    private func arrow(_ press: KeyPress) -> KeyPress.Result {
        // The four arrows are spatial here — depth is stacking in a treemap, not
        // a direction — so Option carries the two moves that change level.
        let move: TreemapNavigator.Move
        if press.modifiers.contains(.option) {
            switch press.key {
            case .downArrow: move = .deeper
            case .upArrow: move = .shallower
            default: return .ignored
            }
        } else {
            switch press.key {
            case .leftArrow: move = .left
            case .rightArrow: move = .right
            case .upArrow: move = .up
            case .downArrow: move = .down
            default: return .ignored
            }
        }
        return step(move)
    }

    private func step(_ move: TreemapNavigator.Move) -> KeyPress.Result {
        guard let index, !index.isEmpty else { return .ignored }
        let navigator = TreemapNavigator(index: index, aspectRatio: aspectRatio)
        guard let current = keyboardFocus, index[current] != nil else {
            // First keypress with nothing selected lands on the largest thing at
            // the outermost level — which is where the eye already was.
            guard let start = navigator.initialFocus() else { return .ignored }
            keyboardFocus = start
            announceFocus()
            return .handled
        }
        guard let next = navigator.destination(from: current, move: move) else {
            // Nothing that way: the edge of the map, or the deepest level.
            // Report it as unhandled so the system can do whatever it does with
            // an arrow key nobody wanted.
            return .ignored
        }
        keyboardFocus = next
        announceFocus()
        return .handled
    }

    private func zoomIntoFocus() -> KeyPress.Result {
        guard let position = keyboardFocus else { return .ignored }
        return zoom(into: position) ? .handled : .ignored
    }

    @discardableResult
    private func zoom(into position: TreemapPosition) -> Bool {
        guard let index, let tile = index[position] else { return false }
        // An aggregate borrows the NodeRef of the largest sibling it swallowed so
        // that tile ids stay unique — so `isValid` is true here and cannot be the
        // test. Zooming would silently drop the user into one arbitrary member of
        // a group labelled "N smaller items", which is not what they clicked.
        if case .aggregated = tile.kind {
            announce("This group stands for several items too small to draw separately. Zoom into the folder around it to reach them.")
            return false
        }
        guard tile.node.isValid else { return false }
        onZoom(tile.node)
        return true
    }

    @discardableResult
    private func zoomOut() -> Bool {
        guard let index, index.breadcrumb.count >= 2 else { return false }
        onZoom(index.breadcrumb[index.breadcrumb.count - 2].node)
        return true
    }

    private func announceFocus() {
        guard let index, let position = keyboardFocus else {
            onFocusChange(nil)
            return
        }
        onFocusChange(index[position])
        announce(TreemapDescription.label(for: position, in: index, basis: basis))
    }

    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Accessibility

    /// The map as an ordered list. VoiceOver walks this instead of a single
    /// opaque "chart" element, and the rotor below indexes the same entries.
    @ViewBuilder
    private var accessibilityRoster: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(roster) { entry in
                Text(entry.label)
                    .accessibilityLabel(Text(entry.label))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Zooms into this item."))
                    .accessibilityAction { zoom(into: entry.position) }
                    .id(entry.id)
            }
            if rosterOmitted > 0 {
                Text(TreemapDescription.omissionNotice(rosterOmitted))
            }
        }
    }

    private func rebuildRoster(force: Bool) {
        guard let index else {
            roster = []
            rotorEntries = []
            rosterOmitted = 0
            accessibilitySummary = "Space used. Nothing measured yet."
            return
        }
        accessibilitySummary = "Space used in \(TreemapDescription.focusTitle(index)), "
            + "\(TreemapDescription.focusTotal(index, basis: basis)), "
            + "\(TreemapDescription.provenance(index)). \(index.tiles.count.formatted()) items charted."
        // A scan regenerates the layout ten times a second. Rebuilding on every
        // one of those would spend real main-thread time describing tiles nobody
        // is reading, so throttle unless something structural changed.
        let now = Date()
        guard force || now.timeIntervalSince(rosterBuiltAt) >= 0.5 else { return }
        rosterBuiltAt = now
        let built = TreemapDescription.roster(for: index, basis: basis,
                                              limit: options.accessibilityRosterLimit)
        roster = built.entries
        rosterOmitted = built.omitted
        rotorEntries = Array(built.entries
            .sorted { $0.tile.frame.area > $1.tile.frame.area }
            .prefix(20))
    }
}
