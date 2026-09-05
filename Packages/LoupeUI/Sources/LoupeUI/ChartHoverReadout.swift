import CoreGraphics
import Foundation
import LoupeCore
import SwiftUI

/// Where a readout goes when it is following the pointer.
///
/// Pure, so the rule that it never leaves the chart can be a test rather than a
/// thing someone notices at the edge of a window six months from now.
public enum ChartReadoutPlacement {
    /// How far off the pointer the readout sits. Far enough not to be under the
    /// cursor's own shadow, near enough to read without moving your eyes.
    public static let offset = CGSize(width: 18, height: 20)
    /// Clearance kept from the edge of the chart.
    public static let margin: Double = 10

    /// The centre to place a readout of `size` at, for a pointer at `point`
    /// inside a chart of `bounds`.
    ///
    /// Below and to the right by default, because that is where a pointer's own
    /// hotspot leaves room. It flips rather than slides when a side would
    /// overrun: sliding leaves the readout sitting on the very thing the
    /// pointer is asking about.
    public static func centre(near point: CGPoint, size: CGSize, in bounds: CGSize) -> CGPoint {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2

        var x = point.x + offset.width + halfWidth
        if x + halfWidth > bounds.width - margin {
            x = point.x - offset.width - halfWidth
        }
        var y = point.y + offset.height + halfHeight
        if y + halfHeight > bounds.height - margin {
            y = point.y - offset.height - halfHeight
        }

        return CGPoint(x: clamp(x, half: halfWidth, limit: bounds.width),
                       y: clamp(y, half: halfHeight, limit: bounds.height))
    }

    /// Keep the whole box inside, unless the box is wider than the chart — in
    /// which case centre it, because there is no correct answer and a readout
    /// pinned hard against one edge looks like a bug.
    private static func clamp(_ value: Double, half: Double, limit: Double) -> Double {
        let low = half + margin
        let high = limit - half - margin
        guard high > low else { return limit / 2 }
        return min(max(value, low), high)
    }
}

/// The three lines a readout says.
///
/// A value, built by `SunburstDescription`/`TreemapDescription`, so the two
/// charts cannot drift into describing the same folder differently and so the
/// wording is testable without a pointer.
public struct ChartReadoutText: Sendable, Hashable {
    public let title: String
    public let detail: String
    public let footnote: String?

    public init(title: String, detail: String, footnote: String? = nil) {
        self.title = title
        self.detail = detail
        self.footnote = footnote
    }
}

/// What the pointer is on, floating beside the pointer.
///
/// The chart already writes a name onto the wedge under the cursor; this
/// carries the numbers, which will not fit on two degrees of arc. It is glass
/// because it is the one piece of chrome that is genuinely *over* the content
/// and moving across it — the case Liquid Glass exists for.
@MainActor
public struct ChartHoverReadout: View {
    /// Where the glass gets its colour from.
    ///
    /// A swatch rather than a `Color` is what buys the transition: a colour is
    /// already flattened, and two flattened colours cannot be interpolated the
    /// short way round a hue wheel that neither of them remembers being on.
    /// The fixed case stays because a caller with a colour and no swatch — the
    /// legend, a preview — should not have to invent one.
    private enum Tint {
        case fixed(Color?)
        case following(SunburstSwatch?)
    }

    private let title: String
    private let detail: String
    private let footnote: String?
    private let tint: Tint

    public init(title: String, detail: String, footnote: String? = nil, tint: Color? = nil) {
        self.init(title: title, detail: detail, footnote: footnote, tint: .fixed(tint))
    }

    public init(_ text: ChartReadoutText, tint: Color? = nil) {
        self.init(title: text.title, detail: text.detail, footnote: text.footnote, tint: .fixed(tint))
    }

    /// The readout that carries the colour of the mark under the pointer, and
    /// slides to the next one as the pointer moves. What the charts use.
    public init(_ text: ChartReadoutText, swatch: SunburstSwatch?) {
        self.init(title: text.title, detail: text.detail, footnote: text.footnote,
                  tint: .following(swatch))
    }

    private init(title: String, detail: String, footnote: String?, tint: Tint) {
        self.title = title
        self.detail = detail
        self.footnote = footnote
        self.tint = tint
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ChartGlassMetrics.panelRadius, style: .continuous)
    }

    public var body: some View {
        surfaced(lines)
            // The pointer has to reach the wedge underneath, and VoiceOver
            // already has the whole chart as a list — this would be a second
            // copy of one row of it, arriving at whatever moment the mouse
            // happened to stop.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .padding(.horizontal, ChartGlassMetrics.contentPadding)
        .padding(.vertical, 7)
    }

    /// Neither branch calls `.interactive()`: the readout follows the cursor,
    /// it does not answer to it, and interactive glass reacts to a press that
    /// can never arrive here.
    @ViewBuilder
    private func surfaced(_ content: some View) -> some View {
        switch tint {
        case .fixed(let color):
            content.chartGlass(in: shape, tint: color)
        case .following(let swatch):
            content.chartGlass(in: shape, tintedBy: swatch)
        }
    }
}

/// Holds a readout beside the pointer without letting it leave the chart.
struct ChartReadoutOverlay<Content: View>: View {
    let point: CGPoint
    let bounds: CGSize
    @ViewBuilder var content: Content

    @State private var size: CGSize = .zero

    var body: some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            // Until it has been measured there is nowhere honest to put it, and
            // a readout that appears at the origin for one frame reads as a
            // flicker every time the pointer enters the chart.
            .opacity(size == .zero ? 0 : 1)
            .position(ChartReadoutPlacement.centre(near: point, size: size, in: bounds))
    }
}

#Preview("Hover readout") {
    // Stepping the seed drives the shipping path — the tint slides from one
    // folder's colour to the next rather than cutting, which is the thing worth
    // looking at here and is invisible in a still.
    @Previewable @State var seed = 5
    let text = ChartReadoutText(title: "com.apple.MobileSoftwareUpdate",
                                detail: "4.21 GB on disk · 38 percent of Library",
                                footnote: "Still being measured, so this total will grow.")
    VStack(spacing: 20) {
        ChartHoverReadout(text, swatch: SunburstPalette().swatch(seed: UInt16(seed), ring: 1,
                                                                 scheme: .light))
        Stepper("Folder", value: $seed, in: 0...9).fixedSize()
    }
    .padding(40)
}
