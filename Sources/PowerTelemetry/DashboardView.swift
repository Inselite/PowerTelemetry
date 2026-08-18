import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject private var store: PowerStore
    @Environment(\.openWindow) private var openWindow
    @State private var range: TimeRange = .hour

    private enum TimeRange: String, CaseIterable {
        case hour = "1 h", fourHours = "4 h", all = "All"
        var cutoff: TimeInterval? {
            switch self {
            case .hour: return 3600
            case .fourHours: return 14400
            case .all: return nil
            }
        }
    }

    private var latest: PowerSample? { store.latest }
    /// Falls back to 140 W when unplugged (AdapterDetails absent) so the chart domain stays sane.
    private var adapterMax: Double {
        let w = latest?.adapterWatts ?? 0
        return w > 0 ? Double(w) : 140
    }
    /// Samples inside the selected time range, downsampled to ≤600 points for rendering.
    private var displaySamples: [PowerSample] {
        var s = store.samples
        if let cutoff = range.cutoff {
            let since = Date().addingTimeInterval(-cutoff)
            s = s.filter { $0.date >= since }
        }
        guard s.count > 600 else { return s }
        let step = s.count / 600
        return stride(from: 0, to: s.count, by: step).map { s[$0] }
    }

    /// Dynamic y-domain: data peak + 15% headroom, snapped to 5 W, floored at 10 W.
    /// Extends below zero when the battery discharges (negative battery power).
    private var yDomain: ClosedRange<Double> {
        let peak = displaySamples.map { max($0.totalInW, $0.loadW, $0.batteryW, 0) }.max() ?? 0
        let trough = displaySamples.map { $0.batteryW }.min() ?? 0
        var top = max((peak * 1.15 / 5).rounded(.up) * 5, 10)
        if latest?.onAC == true { top = max(top, adapterMax + 5) } // keep ceiling visible on AC
        let bottom = trough < 0 ? (trough * 1.15 / 5).rounded(.down) * 5 : 0
        return bottom...top
    }

    var body: some View {
        Group {
            if store.unsupported {
                unsupportedState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    metrics
                        .padding(.bottom, 14)
                    powerChart
                    batteryChart
                        .padding(.top, 12)
                    footer
                }
            }
        }
        .padding(16)
    }

    private var unsupportedState: some View {
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityElement(children: .combine)
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
                Text(latest?.onAC == true ? "on AC" : "on battery")
                    .font(.ptDetail)
                    .foregroundStyle(Color.ptFaint)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Color.ptOk).frame(width: 6, height: 6)
                Text(latest?.date.formatted(date: .omitted, time: .standard) ?? "—")
                    .font(.ptDetail)
                    .foregroundStyle(Color.ptDim)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: Metrics

    private var metrics: some View {
        let s = latest
        return Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            GridRow {
                metricCell(
                    label: "Adapter output", color: .ptAdapter,
                    value: s?.totalInW ?? 0, unit: "W",
                    detail: s.map { "\(Int($0.totalInW / adapterMax * 100))% of \(Int(adapterMax)) W negotiated" } ?? "—"
                )
                metricCell(
                    label: "Battery charge power", color: .ptCharge,
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
                    .foregroundStyle(signed && value < -0.5 ? Color.ptAdapter : Color.ptText)
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

    private func batteryDetail(_ s: PowerSample?) -> String {
        guard let s else { return "—" }
        if s.batteryW < -0.5 { return "discharging — supplementing adapter" }
        if s.isCharging {
            return abs(s.amps) > 0.05 ? String(format: "%.1f A into cells", s.amps) : "charging"
        }
        return s.onAC ? "holding" : "on battery"
    }

    private func batteryEta(_ s: PowerSample?) -> String {
        guard let s else { return "—" }
        if s.pct >= 100 { return "fully charged" }
        if s.pct >= 79, s.pct <= 81, !s.isCharging { return "holding at 80% — optimized charging" }
        guard store.samples.count > 120, let s120 = store.samples.dropLast(120).last else {
            return s.isCharging ? "estimating…" : "discharging"
        }
        let rate = (s.pct - s120.pct) / 2.0 // % per minute over last 120 samples
        guard rate > 0.01 else { return "on hold" }
        let mins = Int((100 - s.pct) / rate)
        return "≈ \(mins / 60) h \(mins % 60) min to full"
    }

    // MARK: Charts

    private var powerChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Power flow").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ptText)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
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
            Chart {
                ForEach(displaySamples) { s in
                LineMark(x: .value("t", s.date), y: .value("w", max(s.totalInW, 0)))
                    .foregroundStyle(Color.ptAdapter)
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("t", s.date), y: .value("w", max(s.totalInW, 0)))
                    .foregroundStyle(Color.ptAdapter.opacity(0.08))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.date), y: .value("w", s.batteryW))
                    .foregroundStyle(Color.ptCharge)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.date), y: .value("w", max(s.loadW, 0)))
                    .foregroundStyle(Color.ptLoad)
                    .interpolationMethod(.monotone)
                }
                if yDomain.lowerBound < 0 {
                    RuleMark(y: .value("zero", 0))
                        .foregroundStyle(Color.ptBorder)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                if latest?.onAC == true {
                    RuleMark(y: .value("ceiling", adapterMax))
                        .foregroundStyle(Color.ptAdapter.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("\(Int(adapterMax)) W ceiling")
                                .font(.ptDetail)
                                .foregroundStyle(Color.ptAdapter.opacity(0.7))
                        }
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.ptDetail)
                        .foregroundStyle(Color.ptFaint)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Color.ptBorder)
                    AxisValueLabel().font(.ptDetail).foregroundStyle(Color.ptFaint)
                }
            }
            .frame(minHeight: 190, maxHeight: .infinity)
            // tween the per-second slide so the window scrolls continuously
            .animation(.linear(duration: 1), value: displaySamples.last?.date)
            .animation(.easeOut(duration: 0.3), value: range)
            .accessibilityLabel("Power flow chart")
            .accessibilityValue(latest.map {
                "Adapter \(Int($0.totalInW)) watts, system load \(Int($0.loadW)) watts, battery \($0.batteryW < -0.5 ? "discharging" : "charging") \(Int(abs($0.batteryW))) watts"
            } ?? "no data")
            legend([
                ("Adapter output", Color.ptAdapter),
                ("Battery +charge / −discharge", Color.ptCharge),
                ("System load", Color.ptLoad),
            ])
        }
        .panelStyle()
    }

    private var batteryChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle("Battery level", detail: "percent")
            Chart(displaySamples) { s in
                LineMark(x: .value("t", s.date), y: .value("p", s.pct))
                    .foregroundStyle(Color.ptOk)
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("t", s.date), y: .value("p", s.pct))
                    .foregroundStyle(Color.ptOk.opacity(0.08))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.ptDetail)
                        .foregroundStyle(Color.ptFaint)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                    AxisGridLine().foregroundStyle(Color.ptBorder)
                    AxisValueLabel().font(.ptDetail).foregroundStyle(Color.ptFaint)
                }
            }
            .frame(height: 90)
            .animation(.linear(duration: 1), value: displaySamples.last?.date)
            .animation(.easeOut(duration: 0.3), value: range)
            .accessibilityLabel("Battery level chart")
            .accessibilityValue(latest.map { "\(Int($0.pct)) percent" } ?? "no data")
        }
        .panelStyle()
    }

    private func panelTitle(_ title: String, detail: String) -> some View {
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

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Negative battery power means the Mac is supplementing the adapter.")
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
