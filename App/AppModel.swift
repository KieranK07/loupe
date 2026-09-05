import Foundation
import SwiftUI
import LoupeCore
import LoupeUI

/// Everything the UI is allowed to know. Deliberately small: no arena, no
/// filesystem handle, no engine internals. The scan produces bounded immutable
/// projections and this is where they land.
@MainActor
@Observable
final class AppModel {

    enum Pillar: String, CaseIterable, Identifiable, Hashable {
        case disk, reclaim, security
        var id: String { rawValue }

        var title: String {
            switch self {
            case .disk: "Disk"
            case .reclaim: "Reclaim"
            case .security: "Security"
            }
        }

        /// SF Symbols only.
        var symbol: String {
            switch self {
            case .disk: "chart.pie"
            case .reclaim: "arrow.up.bin"
            case .security: "checkmark.shield"
            }
        }

        var subtitle: String {
            switch self {
            case .disk: "Where the space went"
            case .reclaim: "Files you can safely remove"
            case .security: "How this Mac is configured"
            }
        }
    }

    /// Which chart is on screen. Only the active one is projected — laying out
    /// both on every progress tick would double the work for a view nobody is
    /// looking at. Uses LoupeUI's `ChartViewMode` rather than a second enum that
    /// would have to be kept in step with it.
    var viewMode: ChartViewMode = .sunburst
    var treemapLayout: TreemapLayout = .empty
    var bubbleLayout: BubbleLayout = .empty
    var selectedPillar: Pillar? = .disk
    var layout: SunburstLayout = .empty
    var scanState: ScanState = .idle
    var basis: SizeBasis = .physical
    var volumes: [VolumeDescriptor] = []
    var selectedVolume: VolumeDescriptor?
    var hovered: InspectedItem?
    var breakdown: SpaceBreakdown?

    // MARK: Reclaim
    var catalog: [CatalogRow] = []
    /// Empty by default and reset on every re-survey. Nothing is ever
    /// pre-selected for the user, at any safety level.
    var selectedTargetIDs: Set<String> = []
    var pendingPlan: IdentifiablePlan?
    var lastOutcome: ReclaimOutcome?
    var isSurveying = false
    var searchQuery = ""
    var showsInspector = true
    let access = FullDiskAccessGate()

    /// Layouts arrive out of order under load. A generation older than the one
    /// on screen is stale work and is dropped rather than allowed to redraw an
    /// earlier state over a later one.
    func apply(_ incoming: SunburstLayout) {
        guard incoming.generation >= layout.generation else { return }
        layout = incoming
    }

    func apply(_ incoming: TreemapLayout) {
        guard incoming.generation >= treemapLayout.generation else { return }
        treemapLayout = incoming
    }

    func apply(_ incoming: BubbleLayout) {
        guard incoming.generation >= bubbleLayout.generation else { return }
        bubbleLayout = incoming
    }

    /// Whichever chart is showing, these are the facts the surrounding chrome
    /// needs — so the toolbar and breadcrumb do not care which view is active.
    ///
    /// Switched exhaustively rather than with a ternary. The ternary these
    /// replaced read `viewMode == .sunburst ? layout : treemapLayout`, which was
    /// correct only while there were exactly two charts: adding a third made
    /// every one of them silently answer for the *treemap* while the bubbles
    /// were on screen, so the breadcrumb and the zoom-out target would have
    /// pointed at a different folder than the one being looked at. An exhaustive
    /// switch turns the next chart into a compile error instead.
    var currentFocus: NodeRef {
        switch viewMode {
        case .sunburst: layout.focus
        case .treemap: treemapLayout.focus
        case .bubbles: bubbleLayout.focus
        }
    }

    var currentBreadcrumb: [Breadcrumb] {
        switch viewMode {
        case .sunburst: layout.breadcrumb
        case .treemap: treemapLayout.breadcrumb
        case .bubbles: bubbleLayout.breadcrumb
        }
    }

    var hasChart: Bool {
        switch viewMode {
        case .sunburst: !layout.wedges.isEmpty
        case .treemap: !treemapLayout.tiles.isEmpty
        case .bubbles: !bubbleLayout.circles.isEmpty
        }
    }

    var scanSummaryLine: String {
        switch scanState {
        case .idle: "No scan yet"
        case .scanning(let p):
            "\(p.entriesSeen.formatted()) items · \(ByteFormat.string(p.physicalBytes)) on disk"
        case .paused(let p): "Paused at \(p.entriesSeen.formatted()) items"
        case .complete(let s):
            "\(s.progress.entriesSeen.formatted()) items · \(ByteFormat.string(s.progress.physicalBytes)) on disk"
        case .failed: "Scan failed"
        }
    }

    /// Surfaced rather than buried: a total that silently excludes unreadable
    /// directories is a total the user cannot trust.
    var caveatLine: String? {
        let progress: ScanProgress? = switch scanState {
        case .scanning(let p), .paused(let p): p
        case .complete(let s): s.progress
        default: nil
        }
        guard let progress, progress.deniedCount > 0 || progress.truncatedPathCount > 0
        else { return nil }
        var parts: [String] = []
        if progress.deniedCount > 0 {
            parts.append("\(progress.deniedCount.formatted()) folders could not be read")
        }
        if progress.truncatedPathCount > 0 {
            parts.append("\(progress.truncatedPathCount.formatted()) paths were too long to follow")
        }
        return parts.joined(separator: " · ") + " — these are not included in the totals."
    }
}
