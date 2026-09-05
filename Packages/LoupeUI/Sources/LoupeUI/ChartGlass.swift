import Foundation
import SwiftUI

/// Which surface the chrome that floats *over* a chart is made of.
///
/// A value rather than a branch buried in a view body, so "what happens when
/// Reduce Transparency is on" is something a test can ask instead of something
/// a screenshot has to reveal.
public enum ChartSurface: String, Sendable, Hashable, CaseIterable {
    /// Liquid Glass: a lensing layer that samples the chart underneath it.
    case liquidGlass
    /// An opaque semantic fill with a hairline edge. Not a dimmer glass — glass
    /// with the blur turned down is still a surface whose contrast depends on
    /// what happens to be behind it, which is the thing being asked for less of.
    case solid

    public static func resolved(reduceTransparency: Bool) -> ChartSurface {
        reduceTransparency ? .solid : .liquidGlass
    }

    public var usesGlass: Bool { self == .liquidGlass }
}

public extension EnvironmentValues {
    /// Forces the surface the floating chrome is made of.
    ///
    /// `nil` — the shipping value — follows the system's Reduce Transparency
    /// setting. Set only by previews and tests, because the system setting is
    /// not writable and "does the fallback actually happen" is not a question
    /// worth answering by turning on an accessibility switch and looking.
    @Entry var chartSurfaceOverride: ChartSurface? = nil
}

/// The one place glass is applied in this module.
///
/// Everything floating over a chart goes through here, so the fallback exists
/// once, the corner radii agree, and there is a single answer to "where is
/// glass used" that does not involve reading every view.
struct ChartGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    /// A whisper of the colour of whatever the chrome is about. Left nil for
    /// anything that is not about one particular wedge.
    let tint: Color?
    /// Only for elements that actually respond to the cursor. A readout that
    /// merely follows the pointer is not interactive, and saying it is makes it
    /// shimmer at things the user cannot click.
    let isInteractive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chartSurfaceOverride) private var override

    private var surface: ChartSurface {
        let system = ChartSurface.resolved(reduceTransparency: reduceTransparency)
        // The override can force the fallback *on*; it can never put glass back
        // once the user has asked for less transparency. Otherwise the seam that
        // exists to test the accessibility path becomes a way to defeat it.
        guard system.usesGlass else { return system }
        return override ?? system
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if surface.usesGlass {
            content.glassEffect(.regular.tint(tint).interactive(isInteractive), in: shape)
        } else {
            content
                .background(.background, in: shape)
                .overlay { shape.stroke(Color.primary.opacity(0.22), lineWidth: 1) }
        }
    }
}

public extension View {
    /// Float this view over the chart on glass, or on an opaque semantic fill
    /// when the user has asked for less transparency.
    func chartGlass(in shape: some Shape, tint: Color? = nil,
                    interactive: Bool = false) -> some View {
        modifier(ChartGlassSurface(shape: shape, tint: tint, isInteractive: interactive))
    }

    /// The common case: a capsule of floating chrome.
    func chartGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        chartGlass(in: Capsule(style: .continuous), tint: tint, interactive: interactive)
    }
}

/// Shared geometry, so the cluster, the rail and the readout look like one
/// family of objects rather than three people's ideas of a floating panel.
enum ChartGlassMetrics {
    /// How near two glass shapes have to be before they should merge rather
    /// than stack. Handed to `GlassEffectContainer`.
    static let containerSpacing: Double = 14
    static let panelRadius: Double = 14
    static let contentPadding: Double = 10
    /// Clearance kept between floating chrome and the edge of the chart.
    static let edgeInset: Double = 14

    /// Gap between two controls that should read as one object. Under
    /// `containerSpacing`, which is the whole mechanism: the container merges
    /// what is closer than its spacing and leaves the rest alone.
    static let memberSpacing: Double = 6
    /// Gap between two groups that must stay separate. Over `containerSpacing`
    /// for the same reason, and the reason these two numbers are defined here
    /// next to it rather than typed into a view: they are only correct
    /// *relative* to it, and nothing about `HStack(spacing: 6)` says so.
    static let groupSpacing: Double = 20
}

/// How the floating chrome moves.
///
/// One clock for the cluster, the rail and the readout. Chrome that morphs at
/// three different speeds reads as three panels that happen to be adjacent,
/// which is the thing this file exists to prevent — and the durations are the
/// half of "one family of objects" that geometry cannot express.
///
/// Every entry returns `nil` under Reduce Motion, so the setting is honoured by
/// construction: a caller cannot animate without asking this file for the
/// animation, and this file has already asked the user.
enum ChartGlassMotion {
    /// Glass shapes merging, splitting and sliding between positions.
    static let morphDuration: Double = 0.28
    /// A crumb arriving or leaving. Shorter, because it happens *during* a
    /// navigation the user is already watching elsewhere on screen.
    static let crumbDuration: Double = 0.22
    /// The tint sliding from one mark's colour to the next. Slower than the
    /// pointer on purpose: the tint is a mood, and a mood that keeps up with a
    /// mouse sweeping a chart is a strobe.
    static let tintDuration: Double = 0.30

    static func morph(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: morphDuration)
    }

    static func crumbs(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: crumbDuration)
    }

    static func tint(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: tintDuration)
    }
}

// MARK: - Tinting glass with the data

/// A tint mid-transition: which colour, and how much of it has arrived.
///
/// Two fields rather than one `Color` because appearing and disappearing are
/// different from changing: a tint arriving from nothing has to fade *up* from
/// zero strength, and a `Color` with the alpha already baked in cannot be
/// interpolated back apart to say so.
public struct ChartTint: Sendable, Hashable {
    /// `nil` exactly when there is no tint at all — which is also what
    /// `strength == 0` means, kept in sync by `ChartGlassTint.blend`.
    public let swatch: SunburstSwatch?
    public let strength: Double

    public static let none = ChartTint(swatch: nil, strength: 0)

    public init(swatch: SunburstSwatch?, strength: Double) {
        if let swatch, strength > 0 {
            self.swatch = swatch
            self.strength = strength
        } else {
            self.swatch = nil
            self.strength = 0
        }
    }

    /// What `chartGlass(tint:)` wants. `nil` is untinted glass, not clear glass.
    public var color: Color? { swatch.map { $0.color.opacity(strength) } }
}

/// Deriving a glass tint from the colour of the mark the chrome is about.
///
/// Pure, and separate from the view, because "is the text still legible on a
/// tinted panel" is arithmetic. `ChartGlassTintTests` composites `strength` of
/// every swatch in every ramp over the Reduce Transparency fallback and checks
/// the label still clears WCAG AA in both appearances — so the strength below
/// cannot be nudged upward in a hurry without something failing.
public enum ChartGlassTint {
    /// How much of the mark's colour reaches the glass.
    ///
    /// A whisper, not a fill. Enough that the readout is visibly *about* the
    /// thing under the pointer; not enough to turn it into a coloured panel
    /// with text on it, which is both illegible and a lie about how much the
    /// colour matters.
    public static let strength: Double = 0.30

    /// The numeric statement of "a whisper, not a fill": a tinted panel has to
    /// stay recognisably light in a light appearance and dark in a dark one.
    ///
    /// That is not an aesthetic preference. `Color.primary` is chosen by the
    /// *appearance*, not by the panel — so a tint strong enough to flip a panel
    /// across the middle would leave black text on a dark panel with no code
    /// anywhere having made a mistake. These two bounds are what stop that, and
    /// `ChartGlassTintTests` walks every swatch of every ramp against them.
    public static let minimumLightPanelLuminance: Double = 0.45
    public static let maximumDarkPanelLuminance: Double = 0.22

    public static func whisper(of swatch: SunburstSwatch) -> ChartTint {
        ChartTint(swatch: swatch, strength: strength)
    }

    /// The signed distance from `a` to `b` the short way round the hue wheel.
    ///
    /// Lerping hue directly would send a red-to-magenta move — 0.02 to 0.94, a
    /// twelfth of the wheel — the other way instead, through orange, green and
    /// cyan. A rainbow wipe across the chrome because the pointer crossed
    /// between two adjacent folders.
    public static func shortestHueDelta(from a: Double, to b: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 1)
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        return delta
    }

    /// The tint part-way from one mark's colour to the next.
    ///
    /// The three cases are genuinely different and collapsing them is the bug
    /// this function exists to avoid: colour to colour *slides*, nothing to
    /// colour *fades up*, and colour to nothing *fades down*. Cross-fading the
    /// first case through zero strength would make the readout blink pale every
    /// time the pointer crossed a boundary.
    public static func blend(from old: SunburstSwatch?, to new: SunburstSwatch?,
                             progress: Double) -> ChartTint {
        let t = min(max(progress, 0), 1)
        switch (old, new) {
        case (nil, nil):
            return .none
        case (nil, .some(let new)):
            return ChartTint(swatch: new, strength: strength * t)
        case (.some(let old), nil):
            return ChartTint(swatch: old, strength: strength * (1 - t))
        case (.some(let old), .some(let new)):
            let hue = old.hue + shortestHueDelta(from: old.hue, to: new.hue) * t
            return ChartTint(swatch: SunburstSwatch(
                hue: hue - hue.rounded(.down),
                saturation: old.saturation + (new.saturation - old.saturation) * t,
                brightness: old.brightness + (new.brightness - old.brightness) * t),
                             strength: strength)
        }
    }
}

/// Glass whose tint interpolates rather than cuts.
///
/// `Animatable` on the modifier, not on the view that uses it, so the view
/// stays a plain declarative body and the frame-by-frame part is one small
/// thing with one number in it — the same division `SunburstChart` makes.
private struct ChartTintedGlass<S: Shape>: ViewModifier, @MainActor Animatable {
    var progress: Double
    let shape: S
    let from: SunburstSwatch?
    let to: SunburstSwatch?
    let isInteractive: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.chartGlass(in: shape,
                           tint: ChartGlassTint.blend(from: from, to: to, progress: progress).color,
                           interactive: isInteractive)
    }
}

/// Holds the two ends of a tint transition and drives the number between them.
private struct ChartSlidingTint<S: Shape>: ViewModifier {
    let shape: S
    let target: SunburstSwatch?
    let isInteractive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var from: SunburstSwatch?
    @State private var to: SunburstSwatch?
    @State private var progress: Double = 1

    func body(content: Content) -> some View {
        content
            .modifier(ChartTintedGlass(progress: progress, shape: shape,
                                       from: from, to: to, isInteractive: isInteractive))
            .onChange(of: target, initial: true) { _, next in
                // Start from where the tint actually *is*, not from where the
                // last transition was aimed. A pointer crossing four wedges in
                // a second interrupts three transitions, and restarting each
                // one from a colour that never appeared on screen is what makes
                // a fast sweep flash.
                from = ChartGlassTint.blend(from: from, to: to, progress: progress).swatch
                to = next
                progress = 0
                guard let animation = ChartGlassMotion.tint(reduceMotion: reduceMotion) else {
                    progress = 1
                    return
                }
                Task { @MainActor in
                    // A second main-actor turn, for the reason `SunburstView`
                    // spells out: 0 and then 1 inside one transaction is a
                    // no-op and the transition never plays.
                    withAnimation(animation) { progress = 1 }
                }
            }
    }
}

public extension View {
    /// Float this view on glass carrying a whisper of the colour of the mark it
    /// is about, sliding to the next colour as the pointer moves.
    ///
    /// Distinct from `chartGlass(in:tint:)` on purpose: that one takes a colour
    /// and does as it is told, which is what a caller with a fixed tint wants.
    /// This one owns the transition, and to interpolate a colour it has to be
    /// handed the swatch rather than the flattened `Color`.
    func chartGlass(in shape: some Shape, tintedBy swatch: SunburstSwatch?,
                    interactive: Bool = false) -> some View {
        modifier(ChartSlidingTint(shape: shape, target: swatch, isInteractive: interactive))
    }
}
