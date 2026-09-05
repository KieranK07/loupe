import SwiftUI
import LoupeCore

/// Colour for the sidebar, kept out of the views that use it.
///
/// The original stance here was that the chrome should be so conventional it is
/// invisible, leaving the chart as the only place with colour. That was wrong in
/// practice rather than in principle: a sidebar of identical grey glyphs gives
/// the eye nothing to aim at, and the three pillars are genuinely different
/// activities — looking, deleting, and checking. They should not look alike.
///
/// What has *not* changed is that colour here is identity, never alarm. Nothing
/// in this file turns red to make the user feel bad about their disk.
extension AppModel.Pillar {
    /// The pillar's identity colour. System colours, so both appearances and
    /// the accessibility tints are correct without a second table.
    var tint: Color {
        switch self {
        case .disk: .blue
        case .reclaim: .green
        case .security: .indigo
        }
    }
}

/// A ring showing how full a volume is.
///
/// Deliberately **not** a warning light. The ring warms as the disk fills
/// because that is a real and useful signal, but it stops at amber and never
/// reaches the red that would be an instruction to start deleting — this app is
/// not allowed to manufacture urgency about space, and a red ring next to a
/// "Reclaim" button is exactly that, in colour instead of in words.
struct CapacityRing: View {
    let used: UInt64
    let total: UInt64
    var diameter: Double = 18

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }

    /// Blue while there is room, warming through teal to amber as it fills.
    /// Interpolated rather than banded, so a volume at 69% and one at 71% do not
    /// look like different kinds of problem.
    private var tint: Color {
        let hue = 0.58 - 0.46 * max(0, min(1, (fraction - 0.55) / 0.45))
        return Color(hue: hue, saturation: 0.72, brightness: 0.88)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: diameter * 0.16)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint.gradient,
                        style: StrokeStyle(lineWidth: diameter * 0.16, lineCap: .round))
                // Trim starts at 3 o'clock; a dial that starts anywhere but the
                // top reads as an arbitrary arc rather than as a proportion.
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.5), value: fraction)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)   // the row states the same fact in words
    }
}
