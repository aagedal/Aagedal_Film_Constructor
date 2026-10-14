import XCTest
@testable import EditorCore

final class AudioFadeRampPlanTests: XCTestCase {
    func testInterpolatedEnvelopeRespectsBoundAcrossDurationsCurvesAndOverlap() throws {
        for scale: Int64 in [1, 48_000, 1_000_000_000] {
            let duration = try RationalTime(100, scale)
            for incoming: Int64 in [0, 1, 37, 100] {
                for outgoing: Int64 in [0, 1, 71, 100] {
                    for a in AudioFadeCurve.allCases {
                        for b in AudioFadeCurve.allCases {
                            let fadeIn = AudioFade(duration: try RationalTime(incoming, scale), curve: a)
                            let fadeOut = AudioFade(duration: try RationalTime(outgoing, scale), curve: b)
                            let plan = try AudioFadeRampPlan(duration: duration, fadeIn: fadeIn, fadeOut: fadeOut, gain: 0.65)
                            XCTAssertLessThanOrEqual(plan.maximumVolumeError, 0.0001)
                            XCTAssertLessThan(plan.points.count, 400)
                            var segment = 0
                            for sample: Int64 in 0...1000 {
                                let t = try RationalTime(sample, scale * 10)
                                while segment + 2 < plan.points.count && plan.points[segment + 1].seconds < t.seconds { segment += 1 }
                                let left = plan.points[segment], right = plan.points[segment + 1]
                                let fraction = (t.seconds - left.seconds) / (right.seconds - left.seconds)
                                let interpolated = left.volume + fraction * (right.volume - left.volume)
                                let exact = try AudioFadeEnvelope.gain(at: t, duration: duration, fadeIn: fadeIn, fadeOut: fadeOut) * 0.65
                                XCTAssertEqual(interpolated, exact, accuracy: plan.maximumVolumeError + 1e-12)
                            }
                        }
                    }
                }
            }
        }
    }

    func testConstantAndSeparateLinearFadesNeedOnlyEdgeKnots() throws {
        let duration = try RationalTime(36_000)
        let constant = try AudioFadeRampPlan(duration: duration, fadeIn: .init(), fadeOut: .init(), gain: 0.5)
        XCTAssertEqual(constant.points.count, 2)
        XCTAssertFalse(constant.isNonlinear)
        let linear = try AudioFadeRampPlan(duration: duration,
            fadeIn: .init(duration: RationalTime(10_000)), fadeOut: .init(duration: RationalTime(10_000)), gain: 1)
        XCTAssertEqual(linear.points.count, 4)
        XCTAssertEqual(linear.maximumVolumeError, 0)
        XCTAssertFalse(linear.isNonlinear)
        let overlap = try AudioFadeRampPlan(duration: duration,
            fadeIn: .init(duration: duration), fadeOut: .init(duration: duration), gain: 1)
        XCTAssertTrue(overlap.isNonlinear)
    }

    func testBoundedWorkAndInputValidation() throws {
        let duration = try RationalTime(1)
        let fade = AudioFade(duration: duration, curve: .equalPower)
        let capped = try AudioFadeRampPlan(duration: duration, fadeIn: fade, fadeOut: fade, gain: 1, tolerance: 1e-30)
        XCTAssertEqual(capped.points.count, 4097)
        XCTAssertGreaterThan(capped.maximumVolumeError, 1e-30)
        for gain in [-1, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try AudioFadeRampPlan(duration: duration, fadeIn: fade, fadeOut: fade, gain: gain))
        }
        XCTAssertThrowsError(try AudioFadeRampPlan(duration: .zero, fadeIn: .init(), fadeOut: .init(), gain: 1))
        XCTAssertThrowsError(try AudioFadeRampPlan(duration: duration, fadeIn: .init(duration: RationalTime(2)), fadeOut: fade, gain: 1))
        XCTAssertThrowsError(try AudioFadeRampPlan(duration: duration, fadeIn: fade, fadeOut: fade, gain: 1, tolerance: 0))
    }
}
