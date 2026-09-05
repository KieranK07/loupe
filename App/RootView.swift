import SwiftUI
import LoupeCore

/// A standard `NavigationSplitView` with a sidebar that is allowed some colour.
///
/// The earlier rule here was that only the chart got to be beautiful and the
/// chrome should be invisible. Held strictly, that produced a column of
/// identical grey labels — invisible in the wrong sense. The pillars now carry
/// their identity colour and volumes carry a fill ring, because those are the
/// two things the eye actually looks for in this column. Everything else stays
/// a system control.
struct RootView: View {
    @Environment(AppModel.self) private var model
    let controller: ScanController
    let reclaim: ReclaimController

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selectedPillar) {
                Section("Inspect") {
                    ForEach(AppModel.Pillar.allCases) { pillar in
                        PillarRow(pillar: pillar, isSelected: model.selectedPillar == pillar)
                            .tag(pillar)
                    }
                }
                if !model.volumes.isEmpty {
                    Section("Volumes") {
                        ForEach(model.volumes) { volume in
                            VolumeRow(volume: volume)
                                .tag(volume)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 232)
        } detail: {
            detail
        }
    }

    /// Switching pillars used to be an instant swap, which read as the window
    /// being replaced rather than as moving between sections of one app.
    ///
    /// The transition is keyed on the pillar rather than applied to the `switch`
    /// itself: without an explicit `id`, SwiftUI sees one view whose contents
    /// changed and animates nothing. This is also why it is a cross-fade and not
    /// a slide — a slide implies the sections are ordered and that you are
    /// moving along them, and these three are not a sequence.
    @ViewBuilder private var detail: some View {
        Group {
            switch model.selectedPillar {
            case .disk:      DiskPane(controller: controller)
            case .reclaim:   ReclaimPane(controller: reclaim)
            case .security:  PlaceholderPane(pillar: .security, phase: "Phase 4")
            case nil:        ContentUnavailableView("Select a section", systemImage: "sidebar.left")
            }
        }
        .id(model.selectedPillar)
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
        .animation(.smooth(duration: 0.26), value: model.selectedPillar)
    }
}

/// One pillar. The glyph carries the pillar's colour and grows very slightly
/// when selected — enough to feel like it responded, not enough to shift the
/// row's layout, which is why the scale is on the icon and not on the label.
private struct PillarRow: View {
    let pillar: AppModel.Pillar
    let isSelected: Bool

    var body: some View {
        Label {
            Text(pillar.title)
        } icon: {
            Image(systemName: pillar.symbol)
                .foregroundStyle(pillar.tint)
                .scaleEffect(isSelected ? 1.12 : 1)
                .animation(.bouncy(duration: 0.32), value: isSelected)
        }
        .symbolVariant(isSelected ? .fill : .none)
        .symbolEffect(.bounce, value: isSelected)
    }
}

private struct VolumeRow: View {
    let volume: VolumeDescriptor

    var body: some View {
        HStack(spacing: 9) {
            CapacityRing(used: volume.usedCapacity, total: volume.totalCapacity)
            VStack(alignment: .leading, spacing: 1) {
                Label(volume.name,
                      systemImage: volume.isInternal ? "internaldrive" : "externaldrive")
                    .labelStyle(.titleOnly)
                Text("\(ByteFormat.string(volume.usedCapacity)) of \(ByteFormat.string(volume.totalCapacity)) used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Honest about what is not built yet, rather than showing an empty pane that
/// looks broken.
private struct PlaceholderPane: View {
    let pillar: AppModel.Pillar
    let phase: String

    var body: some View {
        ContentUnavailableView {
            Label(pillar.title, systemImage: pillar.symbol)
        } description: {
            Text("\(pillar.subtitle). Arrives in \(phase).")
        }
    }
}
