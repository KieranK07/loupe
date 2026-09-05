import Foundation
import LoupeCore
import SwiftUI

/// The controls that belong to the chart, floating over it.
///
/// These are the choices you make *while looking at the disk* — which shape to
/// read it in, which of the two true sizes to read, and the way back out. They
/// are here rather than in the toolbar because the toolbar is where the app's
/// choices live, and because a control that floats over the thing it changes is
/// the one thing Liquid Glass is unambiguously for.
///
/// Everything in it is a system control with a system button style. Glass is a
/// style applied to buttons, not a set of buttons reimplemented in glass — which
/// is not fussiness: `.glass` and `.glassProminent` are what get the selected
/// segment's label ink right against whatever accent colour the user has set,
/// and a hand-drawn indicator capsule would get white-on-yellow wrong.
@MainActor
public struct ChartControlCluster: View {
    @Binding private var viewMode: ChartViewMode
    @Binding private var basis: SizeBasis
    private let zoomOutTarget: String?
    private let onZoomOut: () -> Void

    /// - Parameter zoomOutTarget: the name of the folder the way out leads to.
    ///   `nil` when there is nowhere to go, which hides the control rather than
    ///   showing a dead one.
    public init(viewMode: Binding<ChartViewMode>,
                basis: Binding<SizeBasis>,
                zoomOutTarget: String? = nil,
                onZoomOut: @escaping () -> Void = {}) {
        _viewMode = viewMode
        _basis = basis
        self.zoomOutTarget = zoomOutTarget
        self.onZoomOut = onZoomOut
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    /// What each glass shape in the cluster is called.
    ///
    /// `modeSelection` and `basisSelection` are the load-bearing ones: a single
    /// id used by *whichever* segment is currently on is what makes the
    /// selection travel. Liquid Glass morphs a shape it recognises from where it
    /// was to where it now is, so the lit capsule slides along the row instead
    /// of switching off here and on there.
    private enum Element: Hashable {
        case modeSelection
        case mode(ChartViewMode)
        case basisSelection
        case basis(SizeBasis)
        case zoomOut
    }

    public var body: some View {
        // One container, so the neighbouring capsules lens each other's edges
        // instead of stacking up their own. Stacked glass is the thing that
        // makes an interface look like it was applied rather than designed.
        //
        // Three chart modes, two size bases and a way out is six controls, and
        // six capsules in one undifferentiated row is a list, not a control
        // panel. So the row is spaced rather than divided: members of a group
        // sit closer than the container's merge distance and fuse into one
        // continuous pill, groups sit further apart than it and stay separate.
        // The old hairline separators are gone — a gap that the material itself
        // honours says the same thing without drawing anything.
        GlassEffectContainer(spacing: ChartGlassMetrics.containerSpacing) {
            HStack(spacing: ChartGlassMetrics.groupSpacing) {
                modeGroup
                basisGroup
                if let zoomOutTarget { zoomOut(to: zoomOutTarget) }
            }
        }
        .animation(ChartGlassMotion.morph(reduceMotion: reduceMotion), value: viewMode)
        .animation(ChartGlassMotion.morph(reduceMotion: reduceMotion), value: basis)
        // Keyed on presence rather than on the name: the way out appears and
        // disappears as you cross the root, and only that is worth animating.
        // Re-running the morph because you zoomed from one folder to another at
        // the same depth would be motion reporting nothing.
        .animation(ChartGlassMotion.morph(reduceMotion: reduceMotion), value: zoomOutTarget != nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Chart controls"))
    }

    // MARK: - Groups

    private var modeGroup: some View {
        HStack(spacing: ChartGlassMetrics.memberSpacing) {
            ForEach(ChartViewMode.allCases) { mode in
                let isOn = viewMode == mode
                choice(isOn: isOn,
                       help: "\(mode.title). \(mode.explanation)",
                       label: mode.title) {
                    viewMode = mode
                } content: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol)
                        // The name is written on the segment you are on and
                        // nowhere else. It is what gives the sliding capsule
                        // something to do — it grows as it arrives — and it
                        // keeps three icon-only segments from being three
                        // guesses. The other two still carry the name in their
                        // tooltip and their accessibility label.
                        if isOn {
                            Text(mode.title)
                                .fixedSize()
                                .transition(.opacity)
                        }
                    }
                }
                .glassEffectID(isOn ? Element.modeSelection : Element.mode(mode), in: glass)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Chart shape"))
    }

    private var basisGroup: some View {
        HStack(spacing: ChartGlassMetrics.memberSpacing) {
            ForEach(SizeBasis.allCases) { option in
                let isOn = basis == option
                choice(isOn: isOn,
                       help: option.explanation,
                       label: option.shortLabel) {
                    basis = option
                } content: {
                    Text(option.shortLabel).fixedSize()
                }
                .glassEffectID(isOn ? Element.basisSelection : Element.basis(option), in: glass)
            }
        }
        .accessibilityElement(children: .contain)
        // Not "size basis": the label a screen reader reads has to be the
        // sentence a person would say, and nobody says basis.
        .accessibilityLabel(Text("Which size to show"))
    }

    private func zoomOut(to target: String) -> some View {
        choice(isOn: false,
               help: "Zoom out to \(target)",
               label: "Zoom out to \(target)",
               action: onZoomOut) {
            Image(systemName: "minus.magnifyingglass")
        }
        .glassEffectID(Element.zoomOut, in: glass)
        // It used to pop in. Scaling up from the middle of the row is the
        // material's own idiom for a shape being formed rather than revealed,
        // and it is the difference between a control that arrived and a control
        // that was always there and you had not noticed.
        .transition(.scale(scale: 0.55).combined(with: .opacity))
    }

    // MARK: - One control

    /// Selected reads as prominent glass, unselected as plain glass — both
    /// system button styles, which is also what makes them do the right thing
    /// when the user has asked for reduced transparency.
    @ViewBuilder
    private func choice(isOn: Bool, help: String, label: String,
                        action: @escaping () -> Void,
                        @ViewBuilder content: () -> some View) -> some View {
        let body = content()
            .font(.callout)
            .frame(minWidth: 20, minHeight: 18)
            .padding(.horizontal, 2)
        Group {
            if isOn {
                Button(action: action) { body }.buttonStyle(.glassProminent)
            } else {
                Button(action: action) { body }.buttonStyle(.glass)
            }
        }
        .help(help)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

#Preview("Chart controls") {
    @Previewable @State var mode = ChartViewMode.sunburst
    @Previewable @State var basis = SizeBasis.physical
    VStack(spacing: 30) {
        ChartControlCluster(viewMode: $mode, basis: $basis, zoomOutTarget: "Users") {}
        ChartControlCluster(viewMode: $mode, basis: $basis)
    }
    .padding(40)
}
