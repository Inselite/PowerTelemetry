import SwiftUI
import Charts

/// A periodic schedule that can be switched off.
///
/// `TimelineSchedule` has no type eraser, so pausing can't mean swapping `.periodic`
/// for a different schedule type — it has to be one type that stops handing out
/// entries. That matters here: `MenuBarExtra` keeps its content view alive after the
/// popover is dismissed, so an unpaused chart goes on redrawing at full rate into a
/// window nobody can see, and the cost never comes back down.
private struct PausableTimeline: TimelineSchedule {
    let interval: TimeInterval
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            guard !paused else { return nil }
            defer { next = next.addingTimeInterval(interval) }
            return next
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: PowerStore
    @Environment(\.openWindow) private var openWindow
    @State private var range: TimeRange = .hour
    @State private var hovered: PowerSample?
    /// False while this copy of the dashboard is off screen — see `PausableTimeline`.
    @State private var onScreen = false

    /// 5 Hz on the short ranges, where the window slides 12-25 px/s and the redraw
    /// rate is the frame rate of that motion; 1 Hz elsewhere, where the slide is
    /// sub-pixel per tick and the sampler's own rate is enough. Flowing motion on the
    /// short ranges is the priority by explicit request. Every rate was measured with
    /// the popover open at "1 m" before choosing: Swift Charts renders the whole chart
    /// per frame, so 10 Hz costs 33-42% CPU, 5 Hz 21-27%, and the cost is paid only
    /// while such a range is on screen — `paused` stops everything off screen. Going
    /// smoother than this means taking the bars out of Swift Charts, not ticking faster.
    private var timeline: PausableTimeline {
        PausableTimeline(interval: (range.cutoff ?? allWindowSeconds) <= 60 ? 0.2 : 1,
                         paused: !onScreen)
    }

    private enum TimeRange: String, CaseIterable {
        case halfMinute = "30 s", minute = "1 m", hour = "1 h", fourHours = "4 h", all = "All"
        var cutoff: TimeInterval? {
            switch self {
            case .halfMinute: return 30
            case .minute: return 60
            case .hour: return 3600
            case .fourHours: return 14400
            case .all: return nil
            }
        }
        /// Every range is cut into the same number of columns, so a bar is the same
        /// width whichever range is selected: switching from "1 h" to "4 h" changes
        /// what a bar covers, not how the chart looks. Hard-coded widths used to give
        /// 30 columns at "1 m" and 60 at "1 h", so bars visibly changed size.
        ///
        /// The same count for every range, so a bar is the same width whichever range
        /// is selected — no exceptions. "30 s" gives 0.6 s columns from a 1 Hz sampler;
        /// columns without a sample of their own borrow the previous one — see
        /// `bucketed(width:)`. The sensor only refreshes every ~14 s, so a 1 Hz series
        /// is already repeats of each real reading and the borrow fabricates nothing.
        var columns: Double { 50 }

        /// Seconds per column. "All" has no fixed span, so it derives its own width
        /// from the session — see `bucket(_:)`.
        var bucket: TimeInterval {
            guard let cutoff else { return 0 }
            return cutoff / columns
        }
    }

    /// The seconds "All" spans: the smallest 50-column window that covers the whole
    /// session, with the column width on a doubling ladder (1 s, 2 s, 4 s…). A window
    /// derived directly from the session span would either fatten the bars as the
    /// session grows or re-grid every second to hold the count; the ladder holds the
    /// same 8 px pitch as every other range and re-grids once per doubling instead.
    private var allWindowSeconds: TimeInterval {
        let span = max(50, Date().timeIntervalSince(store.samples.first?.date ?? Date()))
        return 50 * pow(2, (log2(span / 50)).rounded(.up))
    }

    private var latest: PowerSample? { store.latest }
    /// What the metric cells describe: the scrubbed point while the pointer is over a
    /// chart, otherwise the live sample. The chart's own scales stay tied to `latest`
    /// so the axes don't shift under the cursor while scrubbing.
    private var shown: PowerSample? { hovered ?? latest }
    /// The negotiated adapter ceiling, or nil when nothing is plugged in or the adapter
    /// doesn't report its wattage — the chart shouldn't draw a limit it hasn't measured.
    private var adapterCeiling: Double? {
        guard let s = latest, s.onAC, s.adapterWatts > 0 else { return nil }
        return Double(s.adapterWatts)
    }
    /// Samples inside the range, at full resolution — bucketing does the reducing.
    private var rangeSamples: [PowerSample] {
        guard let cutoff = range.cutoff else { return store.samples }
        // One extra bucket beyond the left edge: the oldest bar then leaves by sliding
        // through the plot's clip edge during the step, instead of vanishing the
        // instant its samples age out of the cutoff — "the last one jumps off".
        let since = Date().addingTimeInterval(-cutoff - range.bucket)
        return store.samples.suffix(from: since)
    }

    /// The bars. "All" takes its width from the ladder window so its columns match
    /// every other range exactly.
    private func bucket(_ samples: [PowerSample]) -> [PowerBucket] {
        let width = range == .all ? allWindowSeconds / range.columns : range.bucket
        return samples.bucketed(width: width)
    }

    /// Dynamic y-domain: data peak + 15% headroom, snapped to 5 W, floored at 10 W.
    /// Bars are always positive — direction is carried by colour, not by sign — so the
    /// domain no longer has to reach below zero for battery discharge.
    private func yDomain(for buckets: [PowerBucket]) -> ClosedRange<Double> {
        let peak = buckets.map(\.top).max() ?? 0
        var top = max((peak * 1.15 / 5).rounded(.up) * 5, 10)
        // Only reach for the ceiling once the data is in its neighbourhood. Forcing a
        // 140 W domain around an idle 7 W trace flattens every bar onto the axis.
        if let ceiling = adapterCeiling, peak >= ceiling * 0.5 { top = max(top, ceiling + 5) }
        return 0...top
    }

    /// The visible window, its edge riding "now": the field slides continuously, and
    /// the redraw rate (`timeline`) is chosen so the slide reads as motion rather than
    /// as jumps. A snapped, stepping window was tried and rejected — with uniform bars
    /// a one-slot step reads as the edge bars popping — as were animated steps, which
    /// Swift Charts renders at full-chart cost per frame (27-49% CPU measured). The
    /// edge-fade ramp (`edgeFade`) keeps the ends gentle instead.
    private func xDomain(endingAt end: Date) -> ClosedRange<Date> {
        if let cutoff = range.cutoff {
            return end.addingTimeInterval(-cutoff)...end
        }
        // "All": the ladder window, which by construction contains the whole session.
        // Early in a session it is mostly empty on the left and the bars grow leftward
        // into it — the pitch never changes, which is the point.
        return end.addingTimeInterval(-allWindowSeconds)...end
    }

    var body: some View {
        Group {
            if store.unsupported {
                unsupportedState
            } else {
                dashboard
            }
        }
        .padding(16)
        .onAppear { onScreen = true }
        // The popover can be dismissed mid-hover without the charts seeing the pointer
        // leave; without this it would reopen pinned to a stale moment.
        .onDisappear { hovered = nil; onScreen = false }
    }

    /// Bucketing walks the whole retained history, and both charts draw the same bars.
    /// Computing it here rather than inside each chart keeps it to one pass per redraw.
    private var dashboard: some View {
        let samples = rangeSamples
        let bars = bucket(samples)
        // Spans come from the full-resolution window, not from a downsample. Thinning
        // the trace to ~600 points puts more than `maxGap` between neighbours at the
        // long ranges, which reads as a sleep gap: every span shatters into fragments
        // shorter than `minSpan` and the bands and lane silently disappear.
        let spans = samples.chargeSpans()
        return VStack(alignment: .leading, spacing: 0) {
            header
            metrics
                .padding(.bottom, 14)
            powerChart(bars)
            batteryChart(bars, spans)
                .padding(.top, 12)
            footer
        }
    }

    private var unsupportedState: some View {
        VStack(spacing: 8) {
            VStack(spacing: 8) {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.ptFaint)
                Text("No power telemetry available")
                    .font(.system(size: 13, weight: .semibold))
                Text("Power Telemetry needs a Mac with battery telemetry — an Apple Silicon MacBook.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ptDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .accessibilityElement(children: .combine)
            // The app is LSUIElement, so this popover is the only place to quit from —
            // without this button an unsupported Mac can only kill it from Activity Monitor.
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 7) {
                Image(systemName: "bolt")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ptAdapter)
                Text("Power Telemetry")
                    .font(.system(size: 13, weight: .semibold))
                Text(shown?.onAC == true ? "on AC" : "on battery")
                    .font(.ptDetail)
                    .foregroundStyle(Color.ptFaint)
            }
            Spacer()
            if let hovered {
                Text(hovered.date, format: .dateTime.hour().minute().second())
                    .font(.ptDetail)
                    .foregroundStyle(Color.ptDim)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color.ptOk)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Live telemetry")
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: Metrics

    private var metrics: some View {
        let s = shown
        return Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            GridRow {
                metricCell(
                    label: "Adapter output", color: .ptAdapter,
                    value: s?.totalInW ?? 0, unit: "W",
                    detail: adapterDetail(s)
                )
                metricCell(
                    label: "Battery power", color: .ptCharge,
                    value: s?.batteryW ?? 0, unit: "W", signed: true,
                    detail: batteryDetail(s)
                )
            }
            GridRow {
                metricCell(
                    label: "System load", color: .ptLoad,
                    value: s?.loadW ?? 0, unit: "W",
                    detail: "CPU · GPU · ANE · platform"
                )
                metricCell(
                    label: "Battery level", color: .ptOk,
                    value: s?.pct ?? 0, unit: "%",
                    detail: batteryEta(s)
                )
            }
        }
        .background(Color.ptBorder)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.ptBorder, lineWidth: 1))
    }

    private func metricCell(label: String, color: Color, value: Double,
                            unit: String, signed: Bool = false, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 8, height: 2)
                Text(label.uppercased())
                    .font(.ptLabel).tracking(0.7)
                    .foregroundStyle(Color.ptFaint)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(signed && value < -0.5 ? "−\(Int(abs(value)))" : "\(Int(value))")
                    .font(.ptValue)
                    .foregroundStyle(signed && abs(value) > 0.5 ? color : Color.ptText)
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ptFaint)
            }
            Text(detail)
                .font(.ptDetail)
                .foregroundStyle(Color.ptDim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.ptSurface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(signed && value < -0.5 ? "minus " : "")\(Int(abs(value))) \(unit)")
        .accessibilityValue(detail)
    }

    private func adapterDetail(_ s: PowerSample?) -> String {
        guard let s, s.onAC else { return "no adapter connected" }
        guard s.adapterWatts > 0 else { return "adapter ceiling unknown" }
        return "\(Int(s.totalInW / Double(s.adapterWatts) * 100))% of \(s.adapterWatts) W negotiated"
    }

    private func batteryDetail(_ s: PowerSample?) -> String {
        guard let s else { return "—" }
        if s.batteryW < -0.5 {
            if s.onAC { return "discharging — supplementing adapter" }
            return abs(s.amps) > 0.05 ? String(format: "%.1f A from cells", abs(s.amps)) : "powering the Mac"
        }
        if s.isCharging {
            return abs(s.amps) > 0.05 ? String(format: "%.1f A into cells", s.amps) : "charging"
        }
        return s.onAC ? "holding" : "on battery"
    }

    private func batteryEta(_ s: PowerSample?) -> String {
        guard let s else { return "—" }
        // The estimate is anchored to the end of the history, so it says nothing about
        // a point being scrubbed; report that sample's state instead.
        if hovered != nil {
            if s.isCharging { return "charging" }
            return s.onAC ? "holding" : "discharging"
        }
        if s.pct >= 100 { return "fully charged" }
        if s.onAC, s.pct >= 79, s.pct <= 81, !s.isCharging { return "holding at 80% — optimized charging" }
        guard store.samples.count > 120, let s120 = store.samples.dropLast(120).last else {
            return s.isCharging ? "estimating…" : "discharging"
        }
        let rate = (s.pct - s120.pct) / 2.0 // % per minute over last 120 samples
        if rate > 0.01 {
            let mins = Int((100 - s.pct) / rate)
            return "≈ \(mins / 60) h \(mins % 60) min to full"
        }
        if rate < -0.01 {
            let mins = Int(s.pct / -rate)
            return "≈ \(mins / 60) h \(mins % 60) min remaining"
        }
        return s.onAC ? "holding" : "steady"
    }

    // MARK: Charts

    private func powerChart(_ bars: [PowerBucket]) -> some View {
        let domain = yDomain(for: bars)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Power flow").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ptText)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 232)
                Button {
                    NSApp.activate()
                    openWindow(id: "main")
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.ptFaint)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Enlarge power flow chart")
            }
            TimelineView(timeline) { context in
                let xd = xDomain(endingAt: context.date)
                Chart { powerMarks(bars, domain: domain, window: xd) }
                    .chartYScale(domain: domain)
                    .chartXScale(domain: xd)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            scrubber(proxy, geo, in: bars)
                            readout(powerHoverLabel, proxy, geo)
                        }
                    }
                    .chartXAxis { timeAxis }
                    .chartYAxis { wattAxis }
                    .frame(minHeight: 190, maxHeight: .infinity)
                    .animation(.easeOut(duration: 0.3), value: range)
                    .accessibilityLabel("Power flow chart")
                    .accessibilityValue(powerSummary)
            }
            legend([
                ("Powering the Mac", Color.ptAdapter),
                ("Charging the battery", Color.ptOk),
                ("From the battery", Color.ptCharge),
            ])
        }
        .panelStyle()
    }

    /// Split out of the `Chart` builder: as one expression the type-checker gives up.
    /// Continuous opacity ramp at the window edges: a bar spends its whole last
    /// slot-width fading out as it slides toward the left edge, and the newest bar
    /// fades in over its first. Recomputed from position on every redraw rather than
    /// animated, so the ramp advances with the sliding window itself — nothing ever
    /// pops in or out at full brightness, and nothing disappears before the edge.
    private func edgeFade(_ b: PowerBucket, in window: ClosedRange<Date>) -> Double {
        let w = b.end.timeIntervalSince(b.start)
        guard w > 0 else { return 1 }
        // The ramp is aligned to the bar's DRAWN edges, not its slot: the drawn bar is
        // inset by `PowerBucket.inset` on each side, so the fade must reach zero while
        // the slot still overlaps the window — exactly when the bar's last drawn pixel
        // touches the edge. Aligned to the slot instead, a clipped ~20%-alpha remnant
        // would slide off, which is the "disappears too soon" pop.
        let inset = PowerBucket.inset
        let t = b.end.timeIntervalSince(window.lowerBound) / w
        let u = window.upperBound.timeIntervalSince(b.start) / w
        let fadeOut = min(1, max(0, (t - inset) / (1 - inset)))
        let fadeIn = min(1, max(0, (u - inset) / (1 - inset)))
        return fadeOut * fadeIn
    }

    @ChartContentBuilder
    private func powerMarks(_ bars: [PowerBucket], domain: ClosedRange<Double>,
                            window: ClosedRange<Date>) -> some ChartContent {
        ForEach(bars) { b in
            let fade = edgeFade(b, in: window)
            // Solid = system load, split by who is supplying it.
            bar(b, 0, b.fromAdapter, Color.ptAdapter, fade: fade)
            bar(b, b.fromAdapter, b.fromAdapter + b.fromBattery, Color.ptCharge, fade: fade)
            // Charge gets its own solid colour rather than a wash of the adapter hue:
            // as a tint it was the largest area on the chart and the hardest to see.
            // Green matches the ⚡ band and the level bars below — green means battery.
            bar(b, b.top - b.intoBattery, b.top, Color.ptOk, fade: fade)
        }
        if let ceiling = adapterCeiling, ceiling <= domain.upperBound {
            // Label only when idle: it lives in the same top strip as the scrub readout,
            // and the readout clamps to the left edge once the cursor gets there.
            ceilingRule(ceiling, labelled: hovered == nil)
        }
        if let h = hovered {
            crosshair(at: h.date, to: domain.upperBound)
        }
    }

    private func batteryChart(_ bars: [PowerBucket], _ spans: [ChargeSpan]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle("Battery level")
            TimelineView(timeline) { context in
                let xd = xDomain(endingAt: context.date)
                Chart { batteryMarks(spans, bars, window: xd) }
                    // The domain reaches below zero to make room for the power lane.
                    // Drawing the lane inside the chart rather than as a view beneath it
                    // is what keeps it aligned with the bars for free, at every range.
                    .chartYScale(domain: Self.laneFloor...100)
                    .chartXScale(domain: xd)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            scrubber(proxy, geo, in: bars)
                            readout(batteryHoverLabel, proxy, geo)
                        }
                    }
                    .chartXAxis { timeAxis }
                    .chartYAxis { levelAxis }
                    .frame(height: 112)
                    .animation(.easeOut(duration: 0.3), value: range)
                    .accessibilityLabel("Battery level chart")
                    .accessibilityValue(batterySummary)
            }
            glyphLegend([
                ("bolt.fill", "Charging", Color.ptOk),
                ("capsule.fill", "Plugged in, not charging", Color.ptOk.opacity(0.35)),
            ])
        }
        .panelStyle()
    }

    @ChartContentBuilder
    private func batteryMarks(_ spans: [ChargeSpan], _ bars: [PowerBucket],
                              window: ClosedRange<Date>) -> some ChartContent {
        // Bands first, so the level bars draw over them.
        ForEach(spans) { span in
            band(span)
        }
        ForEach(bars) { b in
            // Red in the warning zone, the way the system marks a low battery. It is
            // the one level worth spotting without reading the axis.
            bar(b, 0, b.levelPct, b.levelPct < 20 ? Color.ptLow : Color.ptOk,
                fade: edgeFade(b, in: window))
        }
        // The power lane, under the level: a bar means the adapter was connected, the
        // bolt marks where it was actually charging. Discharge needs no mark of its own
        // — it is the stretch where the lane is empty and the level walks down.
        ForEach(spans) { span in
            powerLane(span)
        }
        if let h = hovered {
            crosshair(at: h.date, to: 100)
        }
    }

    /// The lane hangs below 0% so it never collides with a 0% bar. Its thickness is
    /// fixed in points rather than in domain units, so it stays a lane and doesn't
    /// grow with the plot when the window is resized.
    private static let laneFloor: Double = -20
    private static let laneY: Double = -12
    private static let laneThickness: CGFloat = 8

    /// One stretch on the adapter, drawn in the lane beneath the level bars.
    ///
    /// The glyph is dropped on short spans: below a few percent of the visible span the
    /// bolt is wider than the bar it labels, and a row of glyphs with no bars under them
    /// reads as noise. The bar alone still carries "plugged in here".
    @ChartContentBuilder
    private func powerLane(_ span: ChargeSpan) -> some ChartContent {
        if span.kind == .charging, span.duration > visibleSpan * 0.05 {
            laneBar(span)
                .annotation(position: .overlay, alignment: .center, spacing: 0) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .black))
                        // Dark ink, not white: system green is light enough in both
                        // appearances that a white bolt on it fails contrast.
                        .foregroundStyle(Color.black.opacity(0.7))
                }
        } else {
            laneBar(span)
        }
    }

    private func laneBar(_ span: ChargeSpan) -> some ChartContent {
        let alpha: Double = span.kind == .charging ? 1 : 0.35
        // No `BarMark(xStart:xEnd:yStart:yEnd:)` exists — the x-range init takes a
        // centre line and a thickness instead.
        return BarMark(
            xStart: .value("from", span.start), xEnd: .value("to", span.end),
            y: .value("lane", Self.laneY), height: .fixed(Self.laneThickness)
        )
        .foregroundStyle(Color.ptOk.opacity(alpha))
        .cornerRadius(2)
    }

    private var powerHoverLabel: String {
        guard let h = hovered else { return "" }
        let w = Int(max(h.loadW, 0))
        return "\(w) W"
    }

    private var batteryHoverLabel: String {
        guard let h = hovered else { return "" }
        return "\(Int(h.pct))%"
    }

    private var powerSummary: String {
        guard let s = latest else { return "no data" }
        let direction = s.batteryW < -0.5 ? "discharging" : "charging"
        return "Adapter \(Int(s.totalInW)) watts, system load \(Int(s.loadW)) watts, battery \(direction) \(Int(abs(s.batteryW))) watts"
    }

    private var batterySummary: String {
        guard let s = latest else { return "no data" }
        let state = s.isCharging ? "charging" : (s.onAC ? "on adapter, not charging" : "on battery")
        return "\(Int(s.pct)) percent, \(state)"
    }

    /// Seconds the x-axis currently covers. "All" is its ladder window, so this
    /// can't come from the range alone.
    private var visibleSpan: TimeInterval {
        range.cutoff ?? allWindowSeconds
    }

    /// Ticks anchor to fixed absolute times (strides), not to `.automatic`: automatic
    /// ticks are regenerated for every window step, so their labels change content
    /// every step and — with the step glide animating the change — sit permanently
    /// mid-crossfade at "1 m". A strided tick's date never changes; the label glides
    /// with the bars and only fades once, when it enters or leaves the window.
    /// Seconds appear below a five-minute span, where the minute is no longer the
    /// part that changes (`11:51, 11:51, 11:51` otherwise).
    private var timeAxis: some AxisContent {
        let fine = visibleSpan < 300
        let now = Date()
        let stride: Double = fine ? 15 : max(60, (visibleSpan / 5 / 60).rounded() * 60)
        let anchored = Swift.stride(
            from: (now.timeIntervalSince1970 / stride).rounded(.down) * stride - visibleSpan,
            through: (now.timeIntervalSince1970 / stride).rounded(.up) * stride,
            by: stride
        ).map { Date(timeIntervalSince1970: $0) }
        return AxisMarks(values: anchored) { value in
            // A tick within a step of "now" sits on the plot's right edge, where the
            // label is centred on the boundary and its trailing half clips away.
            if let d = value.as(Date.self), now.timeIntervalSince(d) > visibleSpan * 0.04 {
                AxisValueLabel(format: fine ? .dateTime.hour().minute().second()
                                            : .dateTime.hour().minute())
                    .font(.ptDetail)
                    .foregroundStyle(Color.ptFaint)
            }
        }
    }

    private var wattAxis: some AxisContent {
        AxisMarks(position: .trailing) { _ in
            AxisGridLine().foregroundStyle(Color.ptBorder)
            AxisValueLabel().font(.ptDetail).foregroundStyle(Color.ptFaint)
        }
    }

    private var levelAxis: some AxisContent {
        AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
            AxisGridLine().foregroundStyle(Color.ptBorder)
            AxisValueLabel {
                if let pct = value.as(Double.self) {
                    Text("\(Int(pct))%")
                }
            }
            .font(.ptDetail)
            .foregroundStyle(Color.ptFaint)
        }
    }

    /// Neutral, not adapter-orange: once the load reaches the ceiling the line crosses
    /// solid orange bars, where an orange dash is invisible.
    @ChartContentBuilder
    private func ceilingRule(_ ceiling: Double, labelled: Bool) -> some ChartContent {
        if labelled {
            RuleMark(y: .value("ceiling", ceiling))
                .foregroundStyle(Color.ptText.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                // Leading, because the trailing edge is where the newest bars always
                // are: a label parked there is guaranteed to sit on data, while the
                // left end is empty whenever history is shorter than the range. It
                // also clears the watt axis, which moved to the trailing side.
                .annotation(position: .bottom, alignment: .leading, spacing: 2) {
                    Text("\(Int(ceiling)) W ceiling")
                        .font(.ptDetail)
                        // The line matters most exactly when the load approaches it —
                        // which is when a full-height bar is behind the label. A chip
                        // keeps it readable over solid orange or green instead of
                        // depending on what happens to be underneath.
                        .foregroundStyle(Color.ptDim)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.ptSurface.opacity(0.92),
                                    in: RoundedRectangle(cornerRadius: 3))
                        .padding(.leading, 2)
                }
        } else {
            RuleMark(y: .value("ceiling", ceiling))
                .foregroundStyle(Color.ptText.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    /// Just the line. The value rides in a view overlay rather than a chart annotation:
    /// `annotation(overflowResolution:)` isn't offered on `ChartContent` in this SDK, and
    /// without it a `.top` annotation clips against the plot edge.
    @ChartContentBuilder
    private func crosshair(at date: Date, to top: Double) -> some ChartContent {
        RuleMark(x: .value("t", date),
                 yStart: .value("lo", 0), yEnd: .value("hi", top))
            .foregroundStyle(Color.ptFaint)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    /// A charging / held stretch, drawn full height behind the level so it reads as a
    /// period of TIME rather than a value on the axis. It carries no glyph of its own:
    /// the lane underneath names the stretch, and a label in both places was two marks
    /// for one fact. Extracted for the same type-checker reason as `bar`.
    private func band(_ span: ChargeSpan) -> some ChartContent {
        RectangleMark(
            xStart: .value("from", span.start), xEnd: .value("to", span.end),
            yStart: .value("lo", 0), yEnd: .value("hi", 100)
        )
        .foregroundStyle(Color.ptOk.opacity(span.kind == .charging ? 0.16 : 0.09))
    }

    /// One block of a bar. Extracted because the inline form — three conditional
    /// segments inside a ForEach — makes the type-checker give up.
    private func bar(_ b: PowerBucket, _ lo: Double, _ hi: Double,
                     _ color: Color, faded: Bool = false, fade: Double = 1) -> some ChartContent {
        let alpha: Double = (faded ? (b.isPartial ? 0.18 : 0.4) : (b.isPartial ? 0.45 : 1)) * fade
        return RectangleMark(
            xStart: .value("from", b.barStart), xEnd: .value("to", b.barEnd),
            yStart: .value("lo", lo), yEnd: .value("hi", max(lo, hi))
        )
        .foregroundStyle(color.opacity(alpha))
        .opacity(hi > lo ? 1 : 0) // zero-height segments would still draw a hairline
    }

    /// The big value + time for the scrubbed bar, the way iOS labels a selected column.
    /// It tracks the crosshair rather than sitting in a corner — a number parked at the
    /// far end of the plot reads as unrelated to the bar it describes — and clamps to the
    /// plot so it stays whole at both edges. Nothing is drawn when not scrubbing.
    @ViewBuilder
    private func readout(_ value: String, _ proxy: ChartProxy, _ geo: GeometryProxy) -> some View {
        if let h = hovered, let plotFrame = proxy.plotFrame,
           let x = proxy.position(forX: h.date) {
            let plot = geo[plotFrame]
            let half: CGFloat = 34
            let cx = min(max(plot.minX + x, plot.minX + half), plot.maxX - half)
            readoutChip(value, h.date)
                .position(x: cx, y: plot.minY + 15)
                .allowsHitTesting(false) // must not steal hover from the scrubber beneath
        }
    }

    @ViewBuilder
    private func readoutChip(_ value: String, _ date: Date) -> some View {
        if true {
            VStack(spacing: -1) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Color.ptText)
                Text(date, format: .dateTime.hour().minute().second())
                    .font(.ptDetail)
                    .foregroundStyle(Color.ptDim)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.ptSurface.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .accessibilityHidden(true)
        }
    }

    /// Maps the pointer's x position onto a bar. Hover only — it never takes clicks,
    /// so the popover's buttons and picker keep working normally.
    private func scrubber(_ proxy: ChartProxy, _ geo: GeometryProxy, in bars: [PowerBucket]) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case let .active(point) = phase, let plotFrame = proxy.plotFrame else {
                    hovered = nil
                    return
                }
                let frame = geo[plotFrame]
                // Only a bar under the pointer counts. The window spans the whole selected
                // range even when a minute of history exists, so "nearest bar" would pin
                // the crosshair to the data while the pointer sat an hour away.
                guard frame.contains(point),
                      let date: Date = proxy.value(atX: point.x - frame.minX),
                      let hit = bars.first(where: { $0.contains(date) })
                else {
                    hovered = nil
                    return
                }
                hovered = hit.sample
            }
    }

    private func panelTitle(_ title: String, detail: String = "") -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ptText)
            Spacer()
            Text(detail).font(.ptDetail).foregroundStyle(Color.ptFaint)
        }
    }

    private func legend(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 14) {
            Spacer()
            ForEach(items, id: \.0) { name, color in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 2)
                    Text(name).font(.system(size: 10)).foregroundStyle(Color.ptDim)
                }
            }
        }
    }

    /// The band legend needs the glyph itself, not a colour swatch — the glyph is the
    /// part the reader has to recognise on the chart.
    private func glyphLegend(_ items: [(String, String, Color)]) -> some View {
        HStack(spacing: 14) {
            Spacer()
            ForEach(items, id: \.1) { symbol, name, color in
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color)
                    Text(name).font(.system(size: 10)).foregroundStyle(Color.ptDim)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Negative battery power means the battery is supplying the Mac.")
                .font(.system(size: 10))
                .foregroundStyle(Color.ptFaint)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.top, 10)
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(12)
            .background(Color.ptSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.ptBorder, lineWidth: 1))
    }
}
