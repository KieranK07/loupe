import Foundation
import Testing
@testable import LoupeUI

@Suite("Angles across the 0 / 2π seam")
struct SunburstAngleTests {
    @Test("Normalisation lands in the half-open turn")
    func normalisationRange() {
        #expect(SunburstAngle.normalized(0) == 0)
        #expect(SunburstAngle.normalized(.pi) == .pi)
        #expect(abs(SunburstAngle.normalized(SunburstAngle.fullTurn) - 0) < 1e-12)
        #expect(abs(SunburstAngle.normalized(SunburstAngle.fullTurn + 0.5) - 0.5) < 1e-12)
        #expect(abs(SunburstAngle.normalized(-0.5) - (SunburstAngle.fullTurn - 0.5)) < 1e-12)
        #expect(abs(SunburstAngle.normalized(-7 * SunburstAngle.fullTurn - 0.25)
            - (SunburstAngle.fullTurn - 0.25)) < 1e-9)
    }

    /// The specific bug this guards: a hair anticlockwise of 12 o'clock, the
    /// naive `remainder + 2π` rounds to exactly 2π, which is outside every
    /// wedge in the ring. Nothing would be under the pointer at the top of
    /// the chart.
    @Test("A sub-ulp negative angle folds to zero, never to a full turn")
    func subUlpNegativeFoldsToZero() {
        for exponent in 16...300 {
            let tiny = -pow(10.0, -Double(exponent))
            let normalized = SunburstAngle.normalized(tiny)
            #expect(normalized >= 0)
            #expect(normalized < SunburstAngle.fullTurn,
                    "10^-\(exponent) escaped the half-open range")
        }
    }

    @Test("Lifting puts an angle into the base's own turn")
    func lifting() {
        #expect(abs(SunburstAngle.lifted(0.05, into: 6.2) - (0.05 + SunburstAngle.fullTurn)) < 1e-12)
        #expect(abs(SunburstAngle.lifted(6.2, into: 6.2) - 6.2) < 1e-12)
        // 6.5 is past 0.1 + 2π (≈6.383), so it lifts *down* into the base's turn.
        #expect(abs(SunburstAngle.lifted(6.5, into: 0.1) - (6.5 - SunburstAngle.fullTurn)) < 1e-12)
        #expect(abs(SunburstAngle.lifted(6.3, into: 0.1) - 6.3) < 1e-12)
        // A value one whole turn above the base lands back on the base.
        #expect(abs(SunburstAngle.lifted(1.0 + SunburstAngle.fullTurn, into: 1.0) - 1.0) < 1e-9)
    }

    @Test("Spans are half-open, so shared edges are owned exactly once")
    func spanIsHalfOpen() {
        #expect(SunburstAngle.span(1.0, 2.0, contains: 1.0))
        #expect(SunburstAngle.span(1.0, 2.0, contains: 1.9999))
        #expect(!SunburstAngle.span(1.0, 2.0, contains: 2.0))
        #expect(!SunburstAngle.span(1.0, 2.0, contains: 0.9999))
    }

    @Test("A span that runs past a full turn still owns angles near zero")
    func spanCrossingTheSeam() {
        let start = 6.2
        let end = SunburstAngle.fullTurn + 0.1
        #expect(SunburstAngle.span(start, end, contains: 6.25))
        #expect(SunburstAngle.span(start, end, contains: 0.05))
        #expect(SunburstAngle.span(start, end, contains: 0.0))
        #expect(!SunburstAngle.span(start, end, contains: 0.15))
        #expect(!SunburstAngle.span(start, end, contains: 6.1))
    }

    @Test("Shortest delta takes the short way round")
    func shortestDelta() {
        #expect(abs(SunburstAngle.shortestDelta(from: 0.1, to: 0.4) - 0.3) < 1e-12)
        #expect(abs(SunburstAngle.shortestDelta(from: 0.4, to: 0.1) + 0.3) < 1e-12)
        // 6.24 -> 0.02 is a small step forwards across the seam, not a near
        // full turn backwards.
        let across = SunburstAngle.shortestDelta(from: 6.24, to: 0.02)
        #expect(across > 0)
        #expect(across < 0.1)
        #expect(abs(SunburstAngle.shortestDelta(from: 0.02, to: 6.24)) < 0.1)
        #expect(SunburstAngle.shortestDelta(from: 0.02, to: 6.24) < 0)
    }
}
