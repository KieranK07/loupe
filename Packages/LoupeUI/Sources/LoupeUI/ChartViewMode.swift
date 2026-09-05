import Foundation

/// Which chart is on screen.
///
/// Lives in its own file rather than beside the control that switches it,
/// because three views, the app model and the scan controller all have to agree
/// on this enum and none of them should have to import the others' opinions.
///
/// The order of `allCases` is the order the segmented control draws them in,
/// so it is deliberate: the two shapes that answer "where did the space go"
/// first, then the one that answers "what is in here" by letting you fall into
/// it. Do not reorder to alphabetise.
public enum ChartViewMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case sunburst
    case treemap
    case bubbles

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sunburst: "Sunburst"
        case .treemap: "Treemap"
        case .bubbles: "Bubbles"
        }
    }

    public var symbol: String {
        switch self {
        case .sunburst: "chart.pie"
        case .treemap: "square.grid.2x2"
        case .bubbles: "circle.circle"
        }
    }

    public var explanation: String {
        switch self {
        case .sunburst: "Rings out from the folder you are in. Angle is size."
        case .treemap: "Nested rectangles. Area is size."
        case .bubbles: "Nested circles you fall into. Area is size."
        }
    }
}
