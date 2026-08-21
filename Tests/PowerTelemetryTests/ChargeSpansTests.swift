import XCTest
@testable import PowerTelemetry

final class ChargeSpansTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Builds a 1 Hz trace from a compact string: `-` on battery, `c` charging,
    /// `h` on adapter but not charging.
    private func trace(_ s: String, step: TimeInterval = 1, gapAfter: Int? = nil,
                       gap: TimeInterval = 3600) -> [PowerSample] {
        var out: [PowerSample] = []
        var t = t0
        for (i, ch) in s.enumerated() {
            var sample = PowerSample(date: t)
            switch ch {
            case "c": sample.isCharging = true;  sample.onAC = true
            case "h": sample.isCharging = false; sample.onAC = true
            default:  sample.isCharging = false; sample.onAC = false
            }
            out.append(sample)
            t = t.addingTimeInterval(i == gapAfter ? gap : step)
        }
        return out
    }

    func testNoSpansWhenAlwaysOnBattery() {
        XCTAssertTrue(trace("----------").chargeSpans().isEmpty)
    }

    func testSingleChargingRunIsOneSpan() {
        let spans = trace("--cccccccccc--").chargeSpans()
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .charging)
        XCTAssertEqual(spans[0].duration, 9)
    }

    func testChargingAndHoldingAreSeparateAdjacentSpans() {
        let spans = trace("cccccchhhhhh").chargeSpans()
        XCTAssertEqual(spans.map(\.kind), [.charging, .held])
        // The held span starts where charging stopped, so the bands abut rather
        // than overlap — otherwise the glyphs would stack.
        XCTAssertEqual(spans[0].end.addingTimeInterval(1), spans[1].start)
    }

    func testFlickerShorterThanMinSpanIsDropped() {
        // IsCharging bouncing for two samples on plug-in must not draw its own glyph.
        XCTAssertTrue(trace("---cc---").chargeSpans().isEmpty)
        XCTAssertEqual(trace("---cccccc---").chargeSpans().count, 1)
    }

    func testSleepGapBreaksOneRunIntoTwoSpans() {
        // Ten charging samples with an hour of missing data in the middle: two bands,
        // not one band bridging a period we never observed.
        let spans = trace("cccccccccccccccccccc", gapAfter: 9).chargeSpans()
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].duration, 9)
        XCTAssertEqual(spans[1].duration, 9)
    }

    func testGapWithinToleranceKeepsOneSpan() {
        // A 3 s hiccup at 1 Hz is dropped frames, not a new charging session.
        let spans = trace("cccccccccccccccccccc", gapAfter: 9, gap: 3).chargeSpans()
        XCTAssertEqual(spans.count, 1)
    }

    func testTrailingSpanEndsAtLastSample() {
        let samples = trace("---ccccccc")
        let spans = samples.chargeSpans()
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].end, samples.last?.date)
    }
}
