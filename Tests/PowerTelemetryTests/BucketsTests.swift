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
