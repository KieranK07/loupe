import SwiftUI
import LoupeCore

/// The screen before there is anything to look at.
///
/// This was a stock `ContentUnavailableView`: a grey glyph, a grey sentence and
/// a plain button. It is the first thing anyone sees, it is on screen for the
/// entire length of the first scan, and it looked like an error state. A launch
/// screen that looks like a failure is a bad first impression to hand someone
/// who just opened the app.
///
/// What it must NOT become is a pitch. There is no claim here about speed, no
/// promise about how much can be freed, and no number invented before the walk
/// has produced one. It is a picture and an invitation.
struct ScanHero: View {
    let volume: VolumeDescriptor?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bloom = false

    var body: some View {
        VStack(spacing: 22) {
            emblem
            VStack(spacing: 6) {
                Text(volume.map { "Look inside \($0.name)" } ?? "Choose a volume")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                Text(volume.map { subtitle(for: $0) }
                     ?? "Pick a disk in the sidebar to scan it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: action) {
                Label("Scan", systemImage: "sparkle.magnifyingglass")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(volume == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { bloom = true }
    }

    /// The volume's real numbers, not a teaser. Someone deciding whether to
    /// spend a minute scanning wants to know how big the thing is.
    private func subtitle(for volume: VolumeDescriptor) -> String {
        "\(ByteFormat.string(volume.usedCapacity)) used of "
        + "\(ByteFormat.string(volume.totalCapacity)). "
        + "Loupe reads sizes only — it never opens a file."
    }

    /// A stylised sunburst: what the app is about to draw, drawn small.
    ///
    /// The proportions are arbitrary and that is fine because it is decoration
    /// with no axis and no legend. The moment it carried a number it would have
    /// to be real, so it carries none.
    private var emblem: some View {
        ZStack {
            ForEach(Array(Self.petals.enumerated()), id: \.offset) { index, petal in
                Circle()
                    .trim(from: petal.start, to: petal.end)
                    .stroke(petal.tint.gradient,
                            style: StrokeStyle(lineWidth: petal.width, lineCap: .butt))
                    .frame(width: petal.diameter, height: petal.diameter)
                    .rotationEffect(.degrees(bloom ? 0 : -40))
                    .opacity(bloom ? 1 : 0)
                    .animation(reduceMotion ? nil
                               : .bouncy(duration: 0.7).delay(Double(index) * 0.055),
                               value: bloom)
            }
        }
        .frame(width: 132, height: 132)
        .accessibilityHidden(true)
    }

    private struct Petal {
        let start: Double, end: Double, diameter: Double, width: Double, tint: Color
    }

    /// Two rings of arcs with gaps, so it reads as a chart rather than as a
    /// loading spinner — which is what an unbroken ring would look like.
    private static let petals: [Petal] = [
        Petal(start: 0.00, end: 0.30, diameter: 60, width: 26, tint: .blue),
        Petal(start: 0.32, end: 0.55, diameter: 60, width: 26, tint: .purple),
        Petal(start: 0.57, end: 0.78, diameter: 60, width: 26, tint: .pink),
        Petal(start: 0.80, end: 0.98, diameter: 60, width: 26, tint: .orange),
        Petal(start: 0.02, end: 0.16, diameter: 104, width: 20, tint: .cyan),
        Petal(start: 0.18, end: 0.29, diameter: 104, width: 20, tint: .teal),
        Petal(start: 0.34, end: 0.52, diameter: 104, width: 20, tint: .indigo),
        Petal(start: 0.59, end: 0.71, diameter: 104, width: 20, tint: .mint),
        Petal(start: 0.73, end: 0.84, diameter: 104, width: 20, tint: .yellow),
        Petal(start: 0.86, end: 0.97, diameter: 104, width: 20, tint: .red),
    ]
}
