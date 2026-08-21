import Foundation

/// One column of the bar charts.
///
/// The three power figures are not independent — the adapter's output splits into
/// what the Mac is using and what is going into the cells:
///
///     adapter output = system load + battery charge
///
/// so one bar can carry all three without stacking unrelated quantities. The solid
/// part is always the system load, coloured by where that power came from; the faded
/// cap on top is adapter output the Mac isn't using, i.e. charge. Reading the height
/// therefore means the same thing in every state: charging, on battery, or the
/// battery supplementing an overloaded adapter.
struct PowerBucket: Identifiable {
    let id: Date       // the bucket's start — stable across recomputes, unlike UUID
    let start: Date
    let end: Date
    /// The busiest sample in the slice. Taking one whole sample rather than
    /// per-field maxima is what keeps the three figures additive: mixing the peak
    /// load from one instant with the peak adapter output from another would break
    /// `adapter = load + charge` and the bar would stop adding up.
    let sample: PowerSample
    /// Charge level at the end of the slice, the way a level is normally read.
    let levelPct: Double
    /// The newest slice is still filling, so its bar is drawn dimmed.
    let isPartial: Bool

    private var load: Double { max(sample.loadW, 0) }
    private var adapterOut: Double { max(sample.totalInW, 0) }

    /// Portion of the load the adapter is covering.
    var fromAdapter: Double { min(adapterOut, load) }
    /// Portion the battery is covering — non-zero only once the load outruns the adapter.
    var fromBattery: Double { max(load - adapterOut, 0) }
    /// Adapter output above the load: surplus going into the cells.
    var intoBattery: Double { max(adapterOut - load, 0) }
    /// Full silhouette: adapter output while charging, system load otherwise.
    var top: Double { max(load, adapterOut) }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Bar edges inset so neighbouring bars read as separate columns.
    var barStart: Date { start.addingTimeInterval(end.timeIntervalSince(start) * 0.08) }
    var barEnd: Date { end.addingTimeInterval(-end.timeIntervalSince(start) * 0.08) }
}

extension Array where Element == PowerSample {
    /// Groups samples into fixed slices of `width` seconds.
    ///
    /// Slices are aligned to absolute time (multiples of `width` since the epoch) rather
    /// than to "now", so a bar's edges never move once drawn — as time passes new bars
    /// appear at the right instead of every existing bar shifting under the cursor.
    func bucketed(width: TimeInterval) -> [PowerBucket] {
        guard width > 0, !isEmpty else { return [] }
        var groups: [Date: [PowerSample]] = [:]
        for s in self {
            let slot = (s.date.timeIntervalSince1970 / width).rounded(.down) * width
            groups[Date(timeIntervalSince1970: slot), default: []].append(s)
        }
        let newest = last?.date ?? .distantPast
        return groups.keys.sorted().compactMap { start in
            guard let group = groups[start], let busiest = group.max(by: { $0.loadW < $1.loadW }),
                  let level = group.last else { return nil }
            let end = start.addingTimeInterval(width)
            return PowerBucket(id: start, start: start, end: end, sample: busiest,
                               levelPct: level.pct, isPartial: end > newest)
        }
    }
}
