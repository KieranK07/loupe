import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI

/// The bubble chart: a hierarchical circle pack you fall into.
///
/// The third of the three views, and the same object as the other two from the
/// outside — it renders a `BubbleLayout` and nothing else, has no route to the
/// arena and no route to a syscall, and reports a zoom upward as a `NodeRef`
/// that comes back as the next layout. That is what lets the three be swapped
/// without the surrounding chrome noticing.
///
/// What it is *for* is different, and the chart says so out loud rather than
/// letting a pretty picture imply otherwise: circles do not tile, so this is the
/// view for seeing how a volume is built and the wrong one for deciding which of
/// two similar folders is bigger. See `BubbleDescription.comparisonCaveat`,
/// which is in the footer and in the accessibility summary.
@MainActor
public struct BubbleView: View {
    private let layout: BubbleLayout
    private let basis: SizeBasis
    private let options: SunburstOptions
    private let search: SunburstSearch
    private let onHover: (BubbleCircle?) -> Void
    private let onFocusChange: (BubbleCircle?) -> Void
    private let onZoom: (NodeRef) -> Void
    private let onToggleInspector: () -> Void
    private let onSearchResults: (SunburstSearchResult) -> Void

    public init(layout: BubbleLayout,
                basis: SizeBasis = .physical,
                options: SunburstOptions = SunburstOptions(),
                search: SunburstSearch = .inactive,
                onHover: @escaping (BubbleCircle?) -> Void = { _ in },
                onFocusChange: @escaping (BubbleCircle?) -> Void = { _ in },
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var index: BubbleIndex?
    @State private var departing: BubbleIndex?
    @State private var progress: Double = 1
    @State private var table: BubbleShadingTable?
    @State private var searchResult: SunburstSearchResult = .inactive

    @State private var hovered: BubblePosition?
    @State private var hoverChain: Set<BubblePosition> = []
    /// Where the pointer is, in the chart's own coordinates. Only for placing
    /// the readout beside it — hit testing never reads this.
    @State private var hoverPoint: CGPoint?
    @State private var keyboardFocus: BubblePosition?
    @FocusState private var hasKeyboardFocus: Bool

    // Derived rather than computed, for the same reason as the other two: every
    // entry costs a byte-count format and a parent lookup, and a computed
    // property would pay that on every body evaluation.
    @State private var roster: [BubbleRosterEntry] = []
    @State private var rotorEntries: [BubbleRosterEntry] = []
    @State private var rosterOmitted: Int = 0
    @State private var rosterBuiltAt: Date = .distantPast
    @State private var accessibilitySummary: String = "Space used. Nothing measured yet."

    // MARK: - Body

    public var body: some View {
        GeometryReader { proxy in
            let metrics = BubbleMetrics(size: proxy.size)
            ZStack {
                if let index, let table, !index.isEmpty, !metrics.isDegenerate {
                    BubbleChart(progress: progress,
                                current: index,
                                departing: departing,
                                metrics: metrics,
                                table: table,
                                hovered: hovered,
                                hoverChain: hoverChain,
                                keyboardFocus: keyboardFocus,
                                search: searchResult,
                                options: options,
                                reduceTransparency: reduceTransparency)
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
                        .contextMenu { pointerMenu(index) }

                    // Everything below floats *over* the bubbles. Nothing goes
                    // behind them: they are the content, and a lensing layer
                    // under a categorical fill fights the fill.
                    floatingChrome(index, table: table, bounds: proxy.size)
                } else if layout.circles.isEmpty {
                    ContentUnavailableView("Nothing measured yet",
                                           systemImage: "circle.circle",
                                           description: Text("Choose a volume or a folder to see what is using space."))
                } else {
                    // The first index is built when the view appears, one turn
                    // after this first body runs. Hold an empty frame rather
                    // than flashing "nothing measured yet" over a layout that
                    // plainly has circles in it.
                    Color.clear
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
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
            table = BubbleShadingTable(palette: SunburstPalette(ramp: options.ramp),
                                       scheme: colorScheme)
        }
        .onChange(of: basis) { _, _ in rebuildRoster(force: true) }
        .onChange(of: searchKey, initial: true) { _, _ in resolveSearch() }
        .accessibilityElement(children: .contain)
        .accessibilityChildren { accessibilityRoster }
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text("Arrow keys move to the nearest item in that direction at the same level. Option with the down arrow falls into the largest item inside this one, Option with the up arrow moves back out. Return zooms in, Escape zooms out, Space toggles the inspector."))
        .accessibilityRotor(Text("Largest items"),
                            entries: rotorEntries,
                            entryLabel: \BubbleRosterEntry.rotorLabel)
    }

    // MARK: - Chrome

    /// The glass layer: the path in, the colour key, and what the pointer is on.
    /// The same three pieces the other two charts float, in the same places, so
    /// switching views does not move the furniture.
    @ViewBuilder
    private func floatingChrome(_ index: BubbleIndex, table: BubbleShadingTable,
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
        if options.showsHoverReadout, progress >= 1, let point = hoverPoint, let position = hovered,
           let text = BubbleDescription.readout(for: position, in: index, basis: basis) {
            ChartReadoutOverlay(point: point, bounds: bounds) {
                // The glass picks up the colour of the ball it is describing,
                // faintly. It is the one tint in the chrome, and it is carrying
                // information rather than decorating.
                // Through `swatch:` rather than a pre-faded `Color`: the readout
                // interpolates the tint between marks, and a colour with the
                // opacity already baked in cannot be taken back apart to tell
                // "the tint changed" from "the tint arrived from nothing".
                ChartHoverReadout(text, swatch: index[position].map { table.swatch(for: $0) })
            }
        }
    }

    /// A live filesystem is never a consistent snapshot, so the chart always
    /// says when it looked instead of implying it is looking now — and here it
    /// also says what this shape is and is not good for, which is not an aside:
    /// a chart this enjoyable to look at is one people will trust further than
    /// it deserves.
    @ViewBuilder
    private var provenanceFooter: some View {
        if options.showsProvenance, let index {
            Text(BubbleDescription.footer(index))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
                .padding(.horizontal, 12)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func pointerMenu(_ index: BubbleIndex) -> some View {
        // Right-click zooms out, matching the treemap's click-on-the-background
        // and the sunburst's centre disc. Offered as a menu rather than as a
        // bare secondary click so the target is named: "out" is ambiguous in a
        // chart you are four levels deep in.
        // Offered for any real directory, not only one that already has circles
        // inside it: a folder whose children were all too small to draw is
        // precisely the folder worth zooming into, because zooming is what makes
        // them big enough.
        if let position = hovered, let circle = index[position], !circle.isAggregated,
           circle.node.isValid, circle.node.isDirectory {
            Button("Zoom into \(circle.name)") { zoom(into: position) }
        }
        if index.breadcrumb.count >= 2 {
            Button("Zoom out to \(index.breadcrumb[index.breadcrumb.count - 2].name)") {
                _ = zoomOut()
            }
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
        LayoutKey(generation: layout.generation, focus: layout.focus.rawValue,
                  count: layout.circles.count)
    }

    private var paletteKey: PaletteKey {
        PaletteKey(ramp: options.ramp, scheme: colorScheme)
    }

    private var searchKey: SearchKey {
        SearchKey(query: search.query, generation: layout.generation, focus: layout.focus.rawValue)
    }

    private func adopt() {
        let next = BubbleIndex(layout)
        let previous = index
        // A new generation ten times a second during a scan is not a zoom — the
        // circles are just growing. Only a change of focus is a zoom, and only a
        // zoom animates; animating a scan's churn would be unreadable.
        let isZoom = previous.map { $0.focus != next.focus } ?? false
        let focusedNode = keyboardFocus.flatMap { previous?[$0]?.node }

        if isZoom, !reduceMotion {
            departing = previous
            index = next
            progress = 0
            Task { @MainActor in
                // A second main-actor turn, deliberately. Setting progress to 0
                // and then to 1 inside one transaction is a no-op as far as
                // SwiftUI is concerned and the transition never plays; the hop
                // lets the old geometry be rendered once first.
                withAnimation(BubbleAnimation.animation(reduceMotion: false)) { progress = 1 }
                try? await Task.sleep(for: .seconds(BubbleAnimation.duration + 0.1))
                if progress >= 1 { departing = nil }
            }
        } else {
            departing = nil
            index = next
            progress = 1
        }

        if isZoom {
            keyboardFocus = BubbleNavigator(index: next).initialFocus()
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

    private func updateHover(at point: CGPoint?, metrics: BubbleMetrics) {
        guard let index else { return }
        // Hover during a zoom would point at geometry that has already moved.
        guard progress >= 1, let point else {
            hoverPoint = nil
            setHover(nil, in: index)
            return
        }
        switch index.hit(at: point, metrics: metrics) {
        case .circle(let position):
            // Tracked at the pointer's own rate so the readout follows rather
            // than jumps; the expensive half below still only runs when the
            // answer to "which circle" changes.
            hoverPoint = point
            setHover(position, in: index)
        case .background, .none:
            hoverPoint = nil
            setHover(nil, in: index)
        }
    }

    private func setHover(_ position: BubblePosition?, in index: BubbleIndex) {
        // The pointer reports at the display's refresh rate. Only tell the app
        // when the answer actually changed, or the inspector rebuilds for every
        // pixel of mouse travel.
        guard position != hovered else { return }
        hovered = position
        hoverChain = position.map { Set(BubbleNavigator(index: index).ancestors(of: $0)) } ?? []
        onHover(position.flatMap { index[$0] })
    }

    private func handleTap(at point: CGPoint, metrics: BubbleMetrics) {
        guard let index, progress >= 1 else { return }
        hasKeyboardFocus = true
        switch index.hit(at: point, metrics: metrics) {
        case .circle(let position):
            keyboardFocus = position
            announceFocus()
            zoom(into: position)
        case .background, .none:
            // The space around the pack is this chart's answer to the sunburst's
            // centre disc: a pointer-only user needs a way back out that does
            // not depend on a keyboard.
            _ = zoomOut()
        }
    }

    // MARK: - Keyboard

    private func arrow(_ press: KeyPress) -> KeyPress.Result {
        // The four arrows are spatial here — depth is nesting in a pack, not a
        // direction — so Option carries the two moves that change level. Exactly
        // the treemap's bindings.
        let move: BubbleNavigator.Move
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

    private func step(_ move: BubbleNavigator.Move) -> KeyPress.Result {
        guard let index, !index.isEmpty else { return .ignored }
        let navigator = BubbleNavigator(index: index)
        guard let current = keyboardFocus, index[current] != nil else {
            // First keypress with nothing selected lands on the largest thing at
            // the outermost level — which is where the eye already was.
            guard let start = navigator.initialFocus() else { return .ignored }
            keyboardFocus = start
            announceFocus()
            return .handled
        }
        guard let next = navigator.destination(from: current, move: move) else {
            // Nothing that way: the edge of the pack, or the deepest level.
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
    private func zoom(into position: BubblePosition) -> Bool {
        guard let index, let circle = index[position] else { return false }
        // An aggregate borrows the NodeRef of the largest sibling it swallowed so
        // that circle ids stay unique — so `isValid` is true here and cannot be
        // the test. Zooming would silently drop the user into one arbitrary
        // member of a group labelled "N smaller items", which is not what they
        // clicked.
        if case .aggregated = circle.kind {
            announce("This group stands for several items too small to draw separately. Zoom into the folder around it to reach them.")
            return false
        }
        guard circle.node.isValid else { return false }
        onZoom(circle.node)
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
        announce(BubbleDescription.label(for: position, in: index, basis: basis))
    }

    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Accessibility

    /// The pack as an ordered list. VoiceOver walks this instead of a single
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
                Text(BubbleDescription.omissionNotice(rosterOmitted))
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
        accessibilitySummary = BubbleDescription.accessibilitySummary(index, basis: basis)
        // A scan regenerates the layout ten times a second. Rebuilding on every
        // one of those would spend real main-thread time describing circles
        // nobody is reading, so throttle unless something structural changed.
        let now = Date()
        guard force || now.timeIntervalSince(rosterBuiltAt) >= 0.5 else { return }
        rosterBuiltAt = now
        let built = BubbleDescription.roster(for: index, basis: basis,
                                             limit: options.accessibilityRosterLimit)
        roster = built.entries
        rosterOmitted = built.omitted
        rotorEntries = Array(built.entries
            .sorted { $0.circle.radius > $1.circle.radius }
            .prefix(20))
    }
}
