import Foundation

/// A contiguous stretch on the adapter, split by what the battery was actually
/// doing: taking charge, or holding while the adapter carried the load.
struct ChargeSpan: Identifiable, Equatable {
    enum Kind { case charging, held }
    let id = UUID()
    let start: Date
    var end: Date
    let kind: Kind

    var duration: TimeInterval { end.timeIntervalSince(start) }

    static func == (a: ChargeSpan, b: ChargeSpan) -> Bool {
        a.start == b.start && a.end == b.end && a.kind == b.kind
    }
}

extension Array where Element == PowerSample {
    /// Groups consecutive samples into charging / held spans for the level chart.
    ///
    /// Two guards, both for things the trace actually does rather than things it might:
    /// a run breaks when the gap between samples exceeds `maxGap`, because sleep/wake
    /// leaves an hours-long hole that would otherwise render as one continuous band;
    /// and spans under `minSpan` are dropped, because `IsCharging` flickers for a second
    /// or two either side of plugging in and each flicker would draw its own bar in the lane.
    func chargeSpans(maxGap: TimeInterval = 30, minSpan: TimeInterval = 5) -> [ChargeSpan] {
        var spans: [ChargeSpan] = []
        for s in self {
            let kind: ChargeSpan.Kind? = s.isCharging ? .charging : (s.onAC ? .held : nil)
            guard let kind else { continue }
            if var last = spans.last, last.kind == kind,
               s.date.timeIntervalSince(last.end) <= maxGap {
                last.end = s.date
                spans[spans.count - 1] = last
            } else {
                spans.append(ChargeSpan(start: s.date, end: s.date, kind: kind))
            }
        }
        return spans.filter { $0.duration >= minSpan }
    }
}
