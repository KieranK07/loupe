import Foundation
import LoupeCore

/// Presentation choices the app owns and the charts obey.
///
/// One value for both the sunburst and the treemap, deliberately: the ramp in
/// particular must not be able to differ between them, or toggling views would
/// recolour the machine.
public struct SunburstOptions: Sendable, Equatable {
    /// Which categorical ramp the wedges use. Chrome is always semantic.
    public var ramp: SunburstRamp
    /// Names drawn on the handful of shapes large enough to hold one. Governs
    /// both charts.
    public var showsWedgeLabels: Bool
    /// The "as of HH:MM" line. A live filesystem is never a consistent
    /// snapshot, so this should stay on unless something else on screen is
    /// already saying it.
    public var showsProvenance: Bool
    /// The floating readout that follows the pointer with the size and share of
    /// whatever it is on. The chart writes a *name* onto the wedge under the
    /// cursor either way; this is the numbers, which do not fit there.
    public var showsHoverReadout: Bool
    /// The path into the disk, floating over the top-left of the chart.
    ///
    /// Off by default, because the surrounding app may already be showing a
    /// breadcrumb of its own and two of them is worse than either. Turn it on
    /// where the chart is the whole pane.
    public var showsBreadcrumbRail: Bool
    /// Which colour is which folder, floating over the top-right of the chart.
    /// Off by default: on a wide chart the names are already on the wedges.
    public var showsLegend: Bool
    /// How many accessibility elements the chart exposes at once.
    public var accessibilityRosterLimit: Int

    public init(ramp: SunburstRamp = .standard,
                showsWedgeLabels: Bool = true,
                showsProvenance: Bool = true,
                showsHoverReadout: Bool = true,
                showsBreadcrumbRail: Bool = false,
                showsLegend: Bool = false,
                accessibilityRosterLimit: Int = 400) {
        self.ramp = ramp
        self.showsWedgeLabels = showsWedgeLabels
        self.showsProvenance = showsProvenance
        self.showsHoverReadout = showsHoverReadout
        self.showsBreadcrumbRail = showsBreadcrumbRail
        self.showsLegend = showsLegend
        self.accessibilityRosterLimit = accessibilityRosterLimit
    }
}
