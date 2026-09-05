import SwiftUI
import LoupeCore
import LoupeUI

/// The hero pane. Chrome, honesty lines and the access gate live here; the
/// sunburst itself is `LoupeUI.SunburstView`, which knows nothing about scans.
struct DiskPane: View {
    @Environment(AppModel.self) private var model
    let controller: ScanController

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.access.status == .denied { accessBanner }

            Group {
                if !model.hasChart && !model.scanState.isRunning {
                    ScanHero(volume: model.selectedVolume, action: scan)
                } else {
                    chart
                        .overlay(alignment: .bottom) { controlCluster }
                        .overlay(alignment: .top) { progressPill }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let caveat = model.caveatLine { caveatBar(caveat) }
        }
        // No `.backgroundExtensionEffect()` here, and that is deliberate.
        //
        // It mirrors and blurs the content at a pane's edge so it appears to run
        // on underneath the sidebar and toolbar. That is exactly right for a
        // photo and exactly wrong for these charts: a treemap tiles its frame
        // and the bubbles reach its edges, so the effect would paint mirrored
        // tiles and half-circles that a reader has no way to tell from real
        // ones. In a view whose entire claim is that area equals bytes, invented
        // area at the boundary is a false statement about the disk, and it would
        // be made by the frame rather than by any number we could check.
        .navigationTitle(model.selectedVolume?.name ?? "Disk")
        .navigationSubtitle(model.scanSummaryLine)
        .inspector(isPresented: $model.showsInspector) {
            InspectorPane(item: model.hovered, basis: model.basis,
                          breakdown: model.breakdown)
                .inspectorColumnWidth(min: 240, ideal: 300)
        }
        .searchable(text: $model.searchQuery, placement: .toolbar,
                    prompt: "Find in this scan")
        .toolbar {
            ToolbarItem {
                if model.scanState.isRunning {
                    Button("Stop", systemImage: "stop.fill") { controller.stop() }
                } else {
                    Button("Scan", systemImage: "arrow.clockwise", action: scan)
                        .disabled(model.selectedVolume == nil)
                }
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") {
                    model.showsInspector.toggle()
                }
            }
        }
        // A basis change or a view switch is a re-projection of an arena we
        // already hold — never a re-walk.
        .onChange(of: model.basis) { _, _ in controller.refresh() }
        .onChange(of: model.viewMode) { _, _ in controller.refresh() }
        .animation(.smooth(duration: 0.35), value: model.scanState.isRunning)
    }

    /// Shown only while the walk is running, and it leaves by itself when the
    /// scan completes rather than sitting there as a stale number.
    @ViewBuilder private var progressPill: some View {
        if case .scanning(let progress) = model.scanState {
            ScanProgressPill(progress: progress)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The floating Liquid Glass controls, over the chart rather than in the
    /// toolbar. This is the one place the app leans on the material: a control
    /// layer above content is what it is for.
    @ViewBuilder private var controlCluster: some View {
        @Bindable var model = model
        ChartControlCluster(
            viewMode: $model.viewMode,
            basis: $model.basis,
            zoomOutTarget: model.currentBreadcrumb.dropLast().last?.name,
            onZoomOut: {
                if let parent = model.currentBreadcrumb.dropLast().last {
                    controller.focus(on: parent.node, basis: model.basis)
                }
            })
        .padding(.bottom, 18)
    }

    @ViewBuilder private var chart: some View {
        let search = SunburstSearch(query: model.searchQuery)
        // The glass breadcrumb rail lives inside the chart now, so the pane no
        // longer draws its own — two breadcrumbs is worse than either.
        let options = SunburstOptions(showsHoverReadout: true,
                                      showsBreadcrumbRail: true,
                                      showsLegend: true)
        switch model.viewMode {
        case .sunburst:
            SunburstView(
                layout: model.layout, basis: model.basis, options: options, search: search,
                onHover: { model.hovered = $0.map(InspectedItem.init) },
                onZoom: { controller.focus(on: $0, basis: model.basis) },
                onToggleInspector: { model.showsInspector.toggle() })
            .padding(20)
        case .treemap:
            TreemapView(
                layout: model.treemapLayout, basis: model.basis, options: options, search: search,
                onHover: { model.hovered = $0.map(InspectedItem.init) },
                onZoom: { controller.focus(on: $0, basis: model.basis) },
                onToggleInspector: { model.showsInspector.toggle() })
            .padding(12)
        case .bubbles:
            BubbleView(
                layout: model.bubbleLayout, basis: model.basis, options: options, search: search,
                onHover: { model.hovered = $0.map(InspectedItem.init) },
                onZoom: { controller.focus(on: $0, basis: model.basis) },
                onToggleInspector: { model.showsInspector.toggle() })
            .padding(12)
        }
    }

    private func scan() {
        guard let volume = model.selectedVolume else { return }
        controller.start(root: volume.mountPoint)
    }

    /// Degradation stated plainly. No modal, no nagging, and no pretending the
    /// grant can be obtained programmatically.
    private var accessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
            Text(model.access.explanation).font(.callout)
            Spacer(minLength: 8)
            Button("Open Settings…") { model.access.openSettings() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func caveatBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Both sizes, always labelled. Never one number pretending to be the truth.
///
/// With nothing hovered this panel would be dead space, so it shows the volume's
/// storage accounting instead — which is where the "why doesn't this match
/// Finder?" question gets answered.
private struct InspectorPane: View {
    let item: InspectedItem?
    let basis: SizeBasis
    let breakdown: SpaceBreakdown?

    var body: some View {
        if let item {
            Form {
                Section(item.displayName) {
                    LabeledContent("On disk", value: ByteFormat.string(item.physicalBytes))
                    LabeledContent("Apparent", value: ByteFormat.string(item.logicalBytes))
                    LabeledContent("Items", value: item.itemCount.formatted())
                    if item.logicalBytes > item.physicalBytes * 2 && item.physicalBytes > 0 {
                        Text("Reports far more than it occupies — typical of files that are compressed, sparse, cloned, or stored in iCloud.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if item.isAggregate {
                        Text("Too small to draw separately. Zoom into the folder around them to reach these.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if item.isStillScanning {
                        Text("Still being scanned — this total will grow.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } else if let breakdown {
            ScrollView { StorageSummary(breakdown: breakdown) }
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "cursorarrow",
                                   description: Text("Point at a wedge to inspect it."))
        }
    }
}
