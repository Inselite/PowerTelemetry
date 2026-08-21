import XCTest
@testable import PowerTelemetry

final class SuffixFromTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// One sample per second starting at `t0`.
    private func trace(_ n: Int) -> [PowerSample] {
        (0..<n).map { PowerSample(date: t0.addingTimeInterval(Double($0))) }
    }

    func testEmptyTraceStaysEmpty() {
        XCTAssertTrue([PowerSample]().suffix(from: t0).isEmpty)
    }

    func testKeepsTheSampleExactlyOnTheBoundary() {
        // The cutoff is "now minus the range", and a sample landing on it is inside
        // the range — dropping it would shorten every window by one sample.
        let s = trace(10).suffix(from: t0.addingTimeInterval(4))
        XCTAssertEqual(s.count, 6)
        XCTAssertEqual(s.first?.date, t0.addingTimeInterval(4))
    }

    func testCutoffBeforeTheTraceKeepsEverything() {
        XCTAssertEqual(trace(10).suffix(from: t0.addingTimeInterval(-60)).count, 10)
    }

    func testCutoffAfterTheTraceKeepsNothing() {
        XCTAssertTrue(trace(10).suffix(from: t0.addingTimeInterval(60)).isEmpty)
    }

    func testMatchesAFilterAtEveryOffset() {
        let samples = trace(64)
        for i in -2...66 {
            let cutoff = t0.addingTimeInterval(Double(i))
            XCTAssertEqual(samples.suffix(from: cutoff).map(\.date),
                           samples.filter { $0.date >= cutoff }.map(\.date),
                           "offset \(i)")
        }
    }
}

final class BucketedTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_020) // a multiple of 60, so it starts a slice

    private func sample(_ offset: Double, load: Double, adapter: Double = 0,
                        pct: Double = 50) -> PowerSample {
        var s = PowerSample(date: t0.addingTimeInterval(offset))
        s.loadW = load
        s.totalInW = adapter
        s.pct = pct
        return s
    }

    func testSlicesAlignToAbsoluteTimeNotToTheFirstSample() {
        // The first sample lands mid-slice; the bar it belongs to must still start on
        // the minute, or every bar shifts as history scrolls past.
        let bars = [sample(25, load: 5), sample(35, load: 6)].bucketed(width: 60)
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].start, t0)
        XCTAssertEqual(bars[0].end, t0.addingTimeInterval(60))
    }

    func testBarTakesTheBusiestSampleWhole() {
        // Mixing the peak load from one instant with the peak adapter output from
        // another would break `adapter = load + charge` and the bar would stop adding up.
        let bars = [sample(0, load: 10, adapter: 90),
                    sample(1, load: 40, adapter: 50),
                    sample(2, load: 20, adapter: 70)].bucketed(width: 60)
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].sample.loadW, 40)
        XCTAssertEqual(bars[0].sample.totalInW, 50)
        XCTAssertEqual(bars[0].fromAdapter + bars[0].fromBattery, 40)
    }

    func testLevelComesFromTheEndOfTheSlice() {
        let bars = [sample(0, load: 5, pct: 80), sample(30, load: 5, pct: 77)]
            .bucketed(width: 60)
        XCTAssertEqual(bars[0].levelPct, 77)
    }

    func testOnlyTheNewestSliceIsPartial() {
        let bars = [sample(0, load: 5), sample(70, load: 5)].bucketed(width: 60)
        XCTAssertEqual(bars.map(\.isPartial), [false, true])
    }

    func testSegmentsSplitTheLoadByWhoIsSupplyingIt() {
        // Adapter under the load: the shortfall is on the battery, nothing is charging.
        let short = [sample(0, load: 100, adapter: 60)].bucketed(width: 60)[0]
        XCTAssertEqual(short.fromAdapter, 60)
        XCTAssertEqual(short.fromBattery, 40)
        XCTAssertEqual(short.intoBattery, 0)
        XCTAssertEqual(short.top, 100)

        // Adapter over the load: the surplus is charge, nothing comes from the battery.
        let spare = [sample(0, load: 60, adapter: 100)].bucketed(width: 60)[0]
        XCTAssertEqual(spare.fromAdapter, 60)
        XCTAssertEqual(spare.fromBattery, 0)
        XCTAssertEqual(spare.intoBattery, 40)
        XCTAssertEqual(spare.top, 100)
    }
}

final class SensorWattsTests: XCTestCase {
    func testMilliwattsBecomeWatts() {
        XCTAssertEqual(PowerSensor.watts(NSNumber(value: 117_807)), 117.807, accuracy: 0.0001)
    }

    func testMissingFieldReadsZero() {
        XCTAssertEqual(PowerSensor.watts(nil), 0)
        XCTAssertEqual(PowerSensor.watts("not a number"), 0)
    }

    func testNegativeFlowIsFlooredAtZero() {
        // The firmware has been seen reporting a negative SystemLoad, which reached the
        // panel as an impossible "−50 W". A flow magnitude has no negative branch.
        XCTAssertEqual(PowerSensor.watts(NSNumber(value: -50_000)), 0)
        XCTAssertEqual(PowerSensor.watts(NSNumber(value: -1)), 0)
    }
}

final class SettledLoadTests: XCTestCase {
    func testPositiveReadingIsTakenAsIs() {
        XCTAssertEqual(PowerSensor.settledLoad(rawLoadW: 25.7, lastGood: 38), 25.7, accuracy: 0.0001)
    }

    func testNegativeReadingHoldsTheLastGoodLoad() {
        // The unplug transient: SystemLoad derives negative from a stale BatteryPower.
        // The load must not read 0, nor the impossible negative — it holds the last good.
        XCTAssertEqual(PowerSensor.settledLoad(rawLoadW: -91.5, lastGood: 38), 38, accuracy: 0.0001)
    }

    func testNegativeWithNoHistoryFallsToZero() {
        // App launched straight onto a stale battery reading, nothing to hold.
        XCTAssertEqual(PowerSensor.settledLoad(rawLoadW: -91.5, lastGood: nil), 0)
    }

    func testZeroIsRealAndKept() {
        XCTAssertEqual(PowerSensor.settledLoad(rawLoadW: 0, lastGood: 38), 0)
    }
}

final class ForwardFillTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_020) // multiple of 60 and of 0.6

    private func sample(_ offset: Double, load: Double) -> PowerSample {
        var s = PowerSample(date: t0.addingTimeInterval(offset))
        s.loadW = load
        return s
    }

    func testSubSampleSlotsBorrowThePreviousSample() {
        // 1 Hz samples over 0.6 s slots: slots with no sample of their own borrow the
        // previous one, so a 50-column short range has no picket-fence gaps.
        let bars = [sample(0, load: 5), sample(2, load: 7)].bucketed(width: 0.6)
        XCTAssertEqual(bars.count, 4)
        for (a, b) in zip(bars, bars.dropFirst()) {
            XCTAssertEqual(b.start.timeIntervalSince(a.end), 0, accuracy: 0.001)
        }
        XCTAssertEqual(bars[1].sample.loadW, 5) // borrowed backward, never forward
    }

    func testASingleDroppedSampleLeavesNoHole() {
        let bars = [sample(0, load: 5), sample(2, load: 7)].bucketed(width: 1)
        XCTAssertEqual(bars.count, 3)
        XCTAssertEqual(bars[1].sample.loadW, 5)
    }

    func testLongGapsAreNeverBridged() {
        // An idle ten minutes must stay visible as absent bars, not render as a flat
        // run of stale readings.
        let bars = [sample(0, load: 5), sample(600, load: 7)].bucketed(width: 60)
        XCTAssertEqual(bars.count, 2)
    }
}

extension ForwardFillTests {
    func testAShortSamplerStallIsBridgedAtEveryWidth() {
        // The 1 Hz sampler shares the main thread with chart redraws and has been seen
        // starving for ~2-3 s. The sensor holds readings ~14 s, so bridging that stall
        // fabricates nothing — and the cap is absolute time, so the same stall must
        // bridge at the sub-second widths too, not only at the wide ones.
        let stalled = [sample(0, load: 5), sample(1, load: 5), sample(2, load: 6),
                       sample(5.4, load: 7), sample(6, load: 7)]
        let bars = stalled.bucketed(width: 0.6)
        XCTAssertEqual(bars.count, 11) // slots 0.0 ... 6.0, none missing
        for (a, b) in zip(bars, bars.dropFirst()) {
            XCTAssertEqual(b.start.timeIntervalSince(a.end), 0, accuracy: 0.001)
        }
    }
}
