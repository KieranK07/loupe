import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI

/// The sunburst.
///
/// Renders a `SunburstLayout` and nothing else. It has no route to the arena, no
/// route to a syscall, and no navigation state of its own beyond which wedge the
/// keyboard is on — zooming is reported upward as a `NodeRef` and comes back as
/// the next layout. That is the whole of the contract in `docs/ARCHITECTURE.md`
/// §3, and it is what makes "the UI never blocks" structural.
@MainActor
public struct SunburstView: View {
    private let layout: SunburstLayout
    private let basis: SizeBasis
    private let options: SunburstOptions
    /// The app owns the `.searchable` field; the chart is handed the text and
    /// decides what it picks out.
    private let search: SunburstSearch
    private let onHover: (Wedge?) -> Void
    private let onFocusChange: (Wedge?) -> Void
    private let onZoom: (NodeRef) -> Void
    private let onToggleInspector: () -> Void
    private let onSearchResults: (SunburstSearchResult) -> Void

    public init(layout: SunburstLayout,
                basis: SizeBasis = .physical,
                options: SunburstOptions = SunburstOptions(),
                search: SunburstSearch = .inactive,
                onHover: @escaping (Wedge?) -> Void = { _ in },
                onFocusChange: @escaping (Wedge?) -> Void = { _ in },
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

    @State private var index: SunburstIndex?
    /// The layout being animated away from. Non-nil only during a transition.
    @State private var departing: SunburstIndex?
    @State private var progress: Double = 1
    @State private var table: SunburstColorTable?
    @State private var gradients: MarkGradientTable?
    // Folding several thousand names is not something to do inside a draw call,
    // so the query is resolved against the layout once and the chart reads a
    // set of ids per frame.
    @State private var searchResult: SunburstSearchResult = .inactive

    // MARK: Transition state
    //
    // `progress` is what SwiftUI animates; the three below are what the *next*
    // layout needs in order to pick up where this one got to. A `@State` read
    // back after `withAnimation` gives the target, not the current value, so the
    // only honest way to know how far a transition has run is to time it — which
    // is exact, because every transition is driven linearly and shaped in
    // `SunburstAnimation.Timing`.
    @State private var activeTiming: SunburstAnimation.Timing = .immediate
    @State private var activeKind: SunburstAnimation.Plan.Kind = .immediate
    @State private var transitionStartedAt: Date = .distantPast
    @State private var transitionToken: UInt64 = 0
    /// Exponential mean of the gap between layouts. A scan's cadence is the
    /// app's to choose and sags under load, so growth is sized from what
    /// actually arrives rather than from a constant that is wrong on any
    /// machine but the one it was tuned on.
    @State private var tickInterval: Double = 0.1
    @State private var lastAdoptAt: Date?
    /// Whole ticks of dash travel already spent, so the provisional edge on a
    /// directory still being walked marches on rather than restarting.
    @State private var dashSeed: Double = 0

    // MARK: Pointer state

    @State private var hovered: SunburstPosition?
    /// Two slots and a phase, so one wedge can fade out while the next fades in.
    @State private var hoverA: SunburstHoverTarget = .none
    @State private var hoverB: SunburstHoverTarget = .none
    @State private var hoverPhase: Double = 0
    @State private var pressed: SunburstPosition?
    @State private var pressPhase: Double = 0
    /// Where the pointer is, in the chart's own coordinates. Only for placing
    /// the readout beside it — hit testing never reads this.
    @State private var hoverPoint: CGPoint?
    @State private var keyboardFocus: SunburstPosition?
    @FocusState private var hasKeyboardFocus: Bool

    // The accessibility text is derived state rather than a computed property:
    // building it costs byte-count formatting and a parent lookup per entry, and
    // a computed property would pay that on every body evaluation — including
    // the sixty of them a zoom animation triggers.
    @State private var roster: [SunburstRosterEntry] = []
    @State private var rotorEntries: [SunburstRosterEntry] = []
    @State private var rosterOmitted: Int = 0
    @State private var rosterBuiltAt: Date = .distantPast
    @State private var accessibilitySummary: String = "Space used. Nothing measured yet."

    // MARK: - Body

    public var body: some View {
        GeometryReader { proxy in
            let metrics = SunburstMetrics(size: proxy.size, ringCount: index?.ringCount ?? 0)
            ZStack {
                if let index, let table, let gradients, !index.isEmpty {
                    SunburstCanvas(progress: progress,
                                   hoverPhase: hoverPhase,
                                   pressPhase: pressPhase,
                                   current: index,
                                   departing: departing,
                                   timing: activeTiming,
                                   metrics: metrics,
                                   table: table,
                                   gradients: gradients,
                                   hoverA: hoverA,
                                   hoverB: hoverB,
                                   pressed: pressed,
                                   keyboardFocus: keyboardFocus,
                                   search: searchResult,
                                   options: options,
                                   dashSeed: dashSeed,
                                   hidesOverlays: hidesOverlays)
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

                    if metrics.centreRadius * 2 >= 56 {
                        centreDisc(index, diameter: metrics.centreRadius * 2 - 8)
                    }

                    // Everything below floats *over* the rings. Nothing goes
                    // behind them: the wedges are the content, and a lensing
                    // layer under a categorical fill fights the fill.
                    floatingChrome(index, table: table, bounds: proxy.size)
                } else if layout.wedges.isEmpty {
                    ContentUnavailableView("Nothing measured yet",
                                           systemImage: "chart.pie",
                                           description: Text("Choose a volume or a folder to see what is using space."))
                } else {
                    // The first index is built when the view appears, one turn
                    // after this first body runs. Hold an empty frame rather
                    // than flashing "nothing measured yet" over a layout that
                    // plainly has wedges in it.
                    Color.clear
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .overlay(alignment: .bottom) { provenanceFooter }
        .focusable()
        .focused($hasKeyboardFocus)
        .onKeyPress(.leftArrow) { step(.previousSibling) }
        .onKeyPress(.rightArrow) { step(.nextSibling) }
        .onKeyPress(.downArrow) { step(.largestChild) }
        .onKeyPress(.upArrow) { step(.parent) }
        .onKeyPress(.return) { zoomIntoFocus() }
        .onKeyPress(.escape) { zoomOut() ? .handled : .ignored }
        .onKeyPress(.space) { onToggleInspector(); return .handled }
        .onChange(of: layoutKey, initial: true) { _, _ in adopt() }
        .onChange(of: paletteKey, initial: true) { _, _ in
            let palette = SunburstPalette(ramp: options.ramp)
            table = SunburstColorTable(palette: palette, scheme: colorScheme)
            gradients = MarkGradientTable(palette: palette, scheme: colorScheme)
        }
        .onChange(of: basis) { _, _ in rebuildRoster(force: true) }
        .onChange(of: searchKey, initial: true) { _, _ in resolveSearch() }
        .accessibilityElement(children: .contain)
        .accessibilityChildren { accessibilityRoster }
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text("Left and right arrows move between neighbouring items. Down arrow enters the largest item inside this one, up arrow moves back out. Return zooms in, Escape zooms out, Space toggles the inspector."))
        .accessibilityRotor(Text("Largest items"),
                            entries: rotorEntries,
                            entryLabel: \SunburstRosterEntry.rotorLabel)
    }

    /// Only a zoom hides them. A scan tick animates too, and hiding the labels
    /// on a tick would mean no labels at all for the length of the scan.
    private var hidesOverlays: Bool { departing != nil && activeKind == .zoom }

    // MARK: - Chrome

    /// The glass layer: the path in, the colour key, and what the pointer is
    /// on. Grouped here rather than scattered through the body so "where does
    /// this app use Liquid Glass" has one answer per view.
    @ViewBuilder
    private func floatingChrome(_ index: SunburstIndex, table: SunburstColorTable,
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
           let text = SunburstDescription.readout(for: position, in: index, basis: basis) {
            ChartReadoutOverlay(point: point, bounds: bounds) {
                // The glass picks up the colour of the wedge it is describing,
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

    @ViewBuilder
    private var provenanceFooter: some View {
        if options.showsProvenance, let index {
            // A live filesystem is never a consistent snapshot, so the chart
            // always says when it looked instead of implying it is looking now.
            Text(SunburstDescription.provenance(index))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
        }
    }

    private func centreDisc(_ index: SunburstIndex, diameter: Double) -> some View {
        let parent = index.breadcrumb.count >= 2 ? index.breadcrumb[index.breadcrumb.count - 2] : nil
        return Button {
            _ = zoomOut()
        } label: {
            VStack(spacing: 3) {
                Text(SunburstDescription.focusTitle(index))
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(SunburstDescription.focusTotal(index, basis: basis))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !index.isComplete {
                    Label("Still measuring", systemImage: "ellipsis.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(width: max(0, diameter), height: max(0, diameter))
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(parent == nil)
        .help(parent.map { "Zoom out to \($0.name)" } ?? SunburstDescription.focusTitle(index))
        .accessibilityLabel(Text("\(SunburstDescription.focusTitle(index)), \(SunburstDescription.focusTotal(index, basis: basis))"))
        .accessibilityHint(Text(parent.map { "Zooms out to \($0.name)." } ?? "This is the outermost level."))
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

    private var layoutKey: LayoutKey {
        LayoutKey(generation: layout.generation, focus: layout.focus.rawValue, count: layout.wedges.count)
    }

    private var paletteKey: PaletteKey {
        PaletteKey(ramp: options.ramp, scheme: colorScheme)
    }

    private struct SearchKey: Hashable {
        let query: String
        let generation: UInt64
        let focus: UInt32
    }

    private var searchKey: SearchKey {
        SearchKey(query: search.query, generation: layout.generation, focus: layout.focus.rawValue)
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

    private func adopt() {
        let next = SunburstIndex(layout)
        let previous = index
        let now = Date()

        let focusChanged = previous.map { $0.focus != next.focus } ?? false
        // Which way the camera should move. Breadcrumb depth rather than ring
        // count: a folder with fewer levels under it is still *deeper* in.
        let depthChange = previous.map { next.breadcrumb.count - $0.breadcrumb.count } ?? 0

        if !focusChanged, let last = lastAdoptAt {
            let gap = now.timeIntervalSince(last)
            // Ignore the absurd in both directions: two layouts in the same
            // runloop turn are not a cadence, and a gap of seconds is the user
            // having sat idle rather than the scanner having slowed down.
            if gap > 0.005, gap < 2 { tickInterval = tickInterval * 0.6 + gap * 0.4 }
        }
        lastAdoptAt = now

        let plan = SunburstAnimation.plan(hasPrevious: previous != nil,
                                          previousIsEmpty: previous?.isEmpty ?? true,
                                          nextIsEmpty: next.isEmpty,
                                          focusChanged: focusChanged,
                                          depthChange: depthChange,
                                          tickInterval: tickInterval,
                                          reduceMotion: reduceMotion)

        let focusedNode = keyboardFocus.flatMap { previous?[$0]?.node }
        let base = departingIndex(for: plan, previous: previous, at: now)

        transitionToken &+= 1
        let token = transitionToken

        if plan.isAnimated, let base {
            departing = base
            index = next
            activeTiming = plan.timing
            activeKind = plan.kind
            progress = 0
            Task { @MainActor in
                // A second main-actor turn, deliberately. Setting progress to 0
                // and then to 1 inside one transaction is a no-op as far as
                // SwiftUI is concerned and the transition never plays; the hop
                // lets the old geometry be rendered once first.
                guard token == transitionToken else { return }
                transitionStartedAt = Date()
                withAnimation(SunburstAnimation.animation(plan.timing, reduceMotion: false)) {
                    progress = 1
                }
                try? await Task.sleep(for: .seconds(plan.timing.duration + 0.05))
                guard token == transitionToken else { return }
                // Back onto the resting path, which allocates nothing per frame.
                departing = nil
                activeKind = .immediate
                activeTiming = .immediate
            }
        } else {
            // Reduce Motion, and every degenerate case, land here: the new
            // geometry is adopted whole, at rest, with no departing layout kept
            // and nothing left running to interpolate.
            departing = nil
            index = next
            progress = 1
            activeTiming = .immediate
            activeKind = .immediate
        }

        dashSeed = reduceMotion ? 0 : dashSeed + 1

        if focusChanged {
            keyboardFocus = SunburstNavigator(index: next).initialFocus()
        } else if let focusedNode, focusedNode.isValid, let moved = next.position(ofNode: focusedNode) {
            // Hold the keyboard on the same node as the layout regenerates under
            // it, otherwise a scan quietly steals the selection every 100 ms.
            keyboardFocus = moved
        } else if let current = keyboardFocus, next[current] == nil {
            keyboardFocus = nil
        }

        clearHover()
        resolveSearch()
        rebuildRoster(force: focusChanged || previous?.isComplete != next.isComplete)
    }

    /// What the new layout should animate *away from*.
    private func departingIndex(for plan: SunburstAnimation.Plan,
                                previous: SunburstIndex?, at now: Date) -> SunburstIndex? {
        switch plan.kind {
        case .immediate:
            return nil
        case .entrance:
            // Nothing to move away from, so it moves away from nothing: against
            // an empty layout every wedge is an entrant, and entrants open from
            // zero sweep. The disk unrolls instead of appearing.
            return SunburstIndex(.empty)
        case .zoom:
            return previous
        case .growth:
            guard let previous else { return nil }
            guard let departing, activeKind == .growth, activeTiming.duration > 0 else {
                return previous
            }
            // A tick has arrived on top of a growth animation that has not
            // finished. Starting again from `previous` would yank every wedge
            // back to where it stood before this animation moved it — a twitch
            // on every tick, which is the jump-cut this was meant to fix. So the
            // half-finished geometry becomes the new starting point.
            let elapsed = now.timeIntervalSince(transitionStartedAt)
            let t = elapsed / activeTiming.duration
            guard t < 0.99 else { return previous }
            return SunburstAnimation.rebased(from: departing, to: previous,
                                             progress: t, timing: activeTiming)
        }
    }

    // MARK: - Pointer

    private func updateHover(at point: CGPoint?, metrics: SunburstMetrics) {
        guard let index else { return }
        guard let point else {
            hoverPoint = nil
            setHover(nil, in: index)
            return
        }
        switch index.hit(at: point, metrics: metrics) {
        case .wedge(let position):
            // Tracked at the pointer's own rate so the readout follows rather
            // than jumps; the expensive half below still only runs when the
            // answer to "which wedge" changes.
            hoverPoint = point
            setHover(position, in: index)
        case .centre, .none:
            hoverPoint = nil
            setHover(nil, in: index)
        }
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: SunburstAnimation.hoverDuration)
    }

    private func setHover(_ position: SunburstPosition?, in index: SunburstIndex) {
        // The pointer reports at the display's refresh rate. Only tell the app
        // when the answer actually changed, or the inspector rebuilds for every
        // pixel of mouse travel.
        guard position != hovered else { return }
        hovered = position
        let target = SunburstHoverTarget(
            position: position,
            chain: position.map { Set(SunburstNavigator(index: index).ancestors(of: $0)) } ?? [])
        // Write into whichever slot is currently hidden and cross-fade onto it.
        // Two slots rather than one value reset to zero: a reset would need the
        // same extra main-actor turn the zoom needs, and the pointer moves far
        // too often to spend a turn per wedge it crosses.
        if hoverPhase >= 0.5 {
            hoverA = target
            withAnimation(hoverAnimation) { hoverPhase = 0 }
        } else {
            hoverB = target
            withAnimation(hoverAnimation) { hoverPhase = 1 }
        }
        onHover(position.flatMap { index[$0] })
    }

    private func clearHover() {
        hovered = nil
        hoverA = .none
        hoverB = .none
        hoverPhase = 0
        hoverPoint = nil
        onHover(nil)
    }

    private func handleTap(at point: CGPoint, metrics: SunburstMetrics) {
        guard let index else { return }
        hasKeyboardFocus = true
        switch index.hit(at: point, metrics: metrics) {
        case .wedge(let position):
            keyboardFocus = position
            announceFocus()
            zoom(into: position)
        case .centre:
            _ = zoomOut()
        case .none:
            break
        }
    }

    /// Flash the wedge, then do the thing.
    ///
    /// The wait is `pressLead` — well under a tenth of a second, which is short
    /// enough not to read as lag and long enough that the wedge has visibly
    /// reacted before the whole chart starts moving. Without it, the only
    /// acknowledgement a click gets is the zoom itself, and a zoom that begins
    /// before anything has confirmed *what* was clicked is the difference
    /// between a chart that answers you and a chart that lurches.
    private func acknowledge(_ position: SunburstPosition, then act: @escaping () -> Void) {
        guard !reduceMotion else { act(); return }
        pressed = position
        pressPhase = 0
        Task { @MainActor in
            // The same extra turn a zoom needs, for the same reason.
            withAnimation(.linear(duration: SunburstAnimation.pressDuration)) { pressPhase = 1 }
            try? await Task.sleep(for: .seconds(SunburstAnimation.pressLead))
            act()
            try? await Task.sleep(for: .seconds(SunburstAnimation.pressDuration))
            if pressed == position { pressed = nil }
        }
    }

    // MARK: - Keyboard

    private func step(_ move: SunburstNavigator.Move) -> KeyPress.Result {
        guard let index, !index.isEmpty else { return .ignored }
        let navigator = SunburstNavigator(index: index)
        guard let current = keyboardFocus, index[current] != nil else {
            // First keypress with nothing selected lands on the largest thing in
            // the innermost ring — which is where the eye already was.
            guard let start = navigator.initialFocus() else { return .ignored }
            keyboardFocus = start
            announceFocus()
            return .handled
        }
        guard let next = navigator.destination(from: current, move: move) else {
            // Nothing there: down arrow on the outermost ring, up arrow at ring
            // 0. Report it as unhandled so the system can do whatever it does
            // with an arrow key nobody wanted.
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
    private func zoom(into position: SunburstPosition) -> Bool {
        guard let index, let wedge = index[position] else { return false }
        // An aggregate borrows the NodeRef of the largest sibling it swallowed so
        // that wedge ids stay unique — so `isValid` is true here and cannot be the
        // test. Zooming would silently drop the user into one arbitrary member of
        // a group labelled "N smaller items", which is not what they clicked.
        if case .aggregated = wedge.kind {
            announce("This group stands for several items too small to draw separately. Zoom into the folder around it to reach them.")
            return false
        }
        guard wedge.node.isValid else { return false }
        let node = wedge.node
        acknowledge(position) { onZoom(node) }
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
        announce(SunburstDescription.label(for: position, in: index, basis: basis))
    }

    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Accessibility

    /// The chart as an ordered list. VoiceOver walks this instead of a single
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
                Text(SunburstDescription.omissionNotice(rosterOmitted))
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
        accessibilitySummary = "Space used in \(SunburstDescription.focusTitle(index)), "
            + "\(SunburstDescription.focusTotal(index, basis: basis)), "
            + "\(SunburstDescription.provenance(index)). \(index.wedges.count.formatted()) items charted."
        // Every entry costs a byte-count format and a parent lookup, and a scan
        // regenerates the layout ten times a second. Rebuilding on every one of
        // those would spend real main-thread time describing wedges nobody is
        // reading, so throttle unless something structural changed.
        let now = Date()
        guard force || now.timeIntervalSince(rosterBuiltAt) >= 0.5 else { return }
        rosterBuiltAt = now
        let built = SunburstDescription.roster(for: index, basis: basis,
                                               limit: options.accessibilityRosterLimit)
        roster = built.entries
        rosterOmitted = built.omitted
        rotorEntries = Array(built.entries.sorted { $0.wedge.sweep > $1.wedge.sweep }.prefix(20))
    }
}

extension SunburstRosterEntry {
    /// The rotor reads a short name; the element itself carries the full sentence.
    var rotorLabel: String { wedge.name }
}
