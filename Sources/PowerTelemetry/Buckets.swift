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

    /// Fraction of the slice trimmed from each side. macOS's own battery chart draws
    /// narrow columns with a clear gap rather than a near-solid block, which is what
    /// lets you count bars and see a single slice against its neighbours.
    static let inset = 0.2

    /// Bar edges inset so neighbouring bars read as separate columns. The hit target
    /// for scrubbing stays the full slice — see `contains(_:)` — so narrowing the bar
    /// costs nothing in pointing accuracy.
    var barStart: Date { start.addingTimeInterval(end.timeIntervalSince(start) * Self.inset) }
    var barEnd: Date { end.addingTimeInterval(-end.timeIntervalSince(start) * Self.inset) }
}

extension Array where Element == PowerSample {
    /// Samples from `date` onward. The trace is sorted, so this is a binary search
    /// rather than a scan of the whole retained history on every redraw — at 12 hours
    /// that is 43 200 samples walked once a second to draw a one-minute window.
    func suffix(from date: Date) -> [PowerSample] {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        return Array(self[lo...])
    }

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
        let keys = groups.keys.sorted()
        guard let firstKey = keys.first, let lastKey = keys.last else { return [] }
        let i0 = Int((firstKey.timeIntervalSince1970 / width).rounded())
        let i1 = Int((lastKey.timeIntervalSince1970 / width).rounded())
        // An empty slot between occupied ones borrows the previous sample, as long as
        // that sample is at most a couple of slots stale. Two reasons this is sound:
        // slots narrower than the 1 Hz sampling interval ("30 s" uses 0.6 s slots so
        // every range shares one bar width) would otherwise alternate bar/gap; and a
        // dropped sample at any range would leave a missing-bar hole. The cap keeps it
        // honest at scale: a sleep gap spans minutes and is never bridged — absence of
        // data stays visible as absent bars.
        // Half a slot of tolerance: grid times are products of `width` and carry
        // floating-point error, so a slot exactly at the cap can miss it by an ulp.
        let maxFill = Swift.min(width * 2, 3.0) + width / 2
        var carry: (sample: PowerSample, level: PowerSample)?
        var out: [PowerBucket] = []
        for i in i0...i1 {
            let start = Date(timeIntervalSince1970: Double(i) * width)
            let end = start.addingTimeInterval(width)
            if let group = groups[start], let busiest = group.max(by: { $0.loadW < $1.loadW }),
               let level = group.last {
                carry = (busiest, level)
                out.append(PowerBucket(id: start, start: start, end: end, sample: busiest,
                                       levelPct: level.pct, isPartial: end > newest))
            } else if let c = carry, start.timeIntervalSince(c.level.date) <= maxFill {
                out.append(PowerBucket(id: start, start: start, end: end, sample: c.sample,
                                       levelPct: c.level.pct, isPartial: end > newest))
            }
        }
        return out
    }
}
