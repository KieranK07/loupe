import Foundation
@testable import LoupeUI

/// Perceptual colour arithmetic, for tests only.
///
/// The palette's own claims — "adjacent seeds are distinguishable", "a label is
/// readable on every fill" — are numbers, not opinions, and they are only worth
/// anything if something checks them. `SunburstPalette` carries the WCAG half
/// because the renderer needs it; CIEDE2000 and the colour-vision simulations
/// live here because nothing that ships needs them.
enum ColourMetrics {

    // MARK: - CIE Lab

    /// sRGB (gamma-encoded, 0...1) to CIE L*a*b* under D65.
    static func lab(_ rgb: (Double, Double, Double)) -> (L: Double, a: Double, b: Double) {
        let r = Contrast.linearise(rgb.0)
        let g = Contrast.linearise(rgb.1)
        let b = Contrast.linearise(rgb.2)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389.0 ? cbrt(t) : (841.0 / 108.0) * t + 4.0 / 29.0
        }
        let fx = f(x / 0.95047), fy = f(y / 1.0), fz = f(z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func lab(_ swatch: SunburstSwatch) -> (L: Double, a: Double, b: Double) {
        let c = swatch.components
        return lab((c.red, c.green, c.blue))
    }

    // MARK: - CIEDE2000

    /// CIEDE2000 colour difference. Roughly: 1 is the threshold of noticing,
    /// 2.3 a "just noticeable difference", 10 obviously two different colours.
    static func difference(_ one: (L: Double, a: Double, b: Double),
                           _ two: (L: Double, a: Double, b: Double)) -> Double {
        let (l1, a1, b1) = one
        let (l2, a2, b2) = two
        let c1 = (a1 * a1 + b1 * b1).squareRoot()
        let c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot()
        let c2p = (a2p * a2p + b2 * b2).squareRoot()

        func degrees(_ y: Double, _ x: Double) -> Double {
            guard y != 0 || x != 0 else { return 0 }
            let d = atan2(y, x) * 180 / .pi
            return d < 0 ? d + 360 : d
        }
        let h1p = degrees(b1, a1p), h2p = degrees(b2, a2p)

        let dLp = l2 - l1
        let dCp = c2p - c1p
        var dhp: Double
        if c1p * c2p == 0 {
            dhp = 0
        } else if abs(h2p - h1p) <= 180 {
            dhp = h2p - h1p
        } else {
            dhp = h2p - h1p > 180 ? h2p - h1p - 360 : h2p - h1p + 360
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp * .pi / 360)

        let lBar = (l1 + l2) / 2
        let cBarP = (c1p + c2p) / 2
        var hBar: Double
        if c1p * c2p == 0 {
            hBar = h1p + h2p
        } else if abs(h1p - h2p) <= 180 {
            hBar = (h1p + h2p) / 2
        } else {
            hBar = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2
        }
        func cosd(_ d: Double) -> Double { cos(d * .pi / 180) }
        let t = 1 - 0.17 * cosd(hBar - 30) + 0.24 * cosd(2 * hBar)
            + 0.32 * cosd(3 * hBar + 6) - 0.20 * cosd(4 * hBar - 63)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rC = 2 * (cBarP7 / (cBarP7 + pow(25, 7))).squareRoot()
        let sL = 1 + (0.015 * pow(lBar - 50, 2)) / (20 + pow(lBar - 50, 2)).squareRoot()
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rT = -sin(2 * dTheta * .pi / 180) * rC

        let dl = dLp / sL, dc = dCp / sC, dh = dHp / sH
        return (dl * dl + dc * dc + dh * dh + rT * dc * dh).squareRoot()
    }

    static func difference(_ one: SunburstSwatch, _ two: SunburstSwatch) -> Double {
        difference(lab(one), lab(two))
    }

    // MARK: - Colour vision deficiency

    /// The three dichromacies, simulated with Viénot–Brettel–Mollon (1999).
    ///
    /// Not a claim about what anyone sees — it is a repeatable transform that
    /// collapses one opponent channel, which is enough to catch a ramp whose
    /// separation lives entirely in red versus green.
    enum Vision: String, CaseIterable {
        case normal, deuteranope, protanope

        func simulate(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
            guard self != .normal else { return rgb }
            let r = Contrast.linearise(rgb.0)
            let g = Contrast.linearise(rgb.1)
            let b = Contrast.linearise(rgb.2)
            let l = 17.8824 * r + 43.5161 * g + 4.11935 * b
            let m = 3.45565 * r + 27.1554 * g + 3.86714 * b
            let s = 0.0299566 * r + 0.184309 * g + 1.46709 * b

            var (l2, m2) = (l, m)
            switch self {
            case .deuteranope: m2 = 0.494207 * l + 1.24827 * s
            case .protanope: l2 = 2.02344 * m - 2.52581 * s
            case .normal: break
            }

            let rr = 0.080944_4479 * l2 - 0.130504_409 * m2 + 0.116721_066 * s
            let gg = -0.010248_5335 * l2 + 0.054019_3266 * m2 - 0.113614_708 * s
            let bb = -0.000365_296938 * l2 - 0.004121_61469 * m2 + 0.693511_405 * s
            func encode(_ c: Double) -> Double {
                let v = min(max(c, 0), 1)
                return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            }
            return (encode(rr), encode(gg), encode(bb))
        }

        func lab(_ swatch: SunburstSwatch) -> (L: Double, a: Double, b: Double) {
            let c = swatch.components
            return ColourMetrics.lab(simulate((c.red, c.green, c.blue)))
        }
    }
}
