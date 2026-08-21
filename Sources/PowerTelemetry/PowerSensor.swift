import Foundation
import IOKit

/// One power measurement, sampled from AppleSmartBattery via IOKit.
struct PowerSample: Identifiable {
    let id = UUID()
    let date: Date
    var pct: Double = 0        // battery level %
    var loadW: Double = 0      // total system consumption
    var batteryW: Double = 0   // + charging into battery, − discharging from battery
    var totalInW: Double = 0   // power delivered by the adapter
    var amps: Double = 0       // battery current, signed
    var isCharging = false
    var onAC = false
    var adapterWatts = 0       // negotiated adapter ceiling (e.g. 140)

    /// Largest magnitude among the tracked power flows. The adapter reads 0 W on
    /// battery, so a menu bar pinned to `totalInW` would hide all activity while
    /// unplugged; this always surfaces whatever is actually moving the most watts.
    var peakW: Double { max(totalInW, loadW, abs(batteryW)) }

    /// Which flow `peakW` came from — lets the UI label the number it shows.
    var peakSource: PowerFlow {
        if peakW == totalInW { return .adapter }
        if peakW == loadW { return .load }
        return batteryW < 0 ? .batteryDischarge : .batteryCharge
    }
}

enum PowerFlow {
    case adapter, load, batteryCharge, batteryDischarge
}

enum PowerSensor {
    /// Returns nil on Macs without battery telemetry (desktops, Intel).
    ///
    /// `previous` is the last sample the store kept. On battery the telemetry block
    /// lags the plug by ~14 s and momentarily reports a negative load; the previous
    /// sample's load stands in for that window. Passing it in rather than holding it
    /// keeps this a pure read of the hardware.
    static func read(previous: PowerSample? = nil) -> PowerSample? {
        var s = PowerSample(date: Date())
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        s.pct = num(d["CurrentCapacity"])
        s.isCharging = (d["IsCharging"] as? Bool) ?? false
        s.onAC = (d["ExternalConnected"] as? Bool) ?? false

        var rawLoadW = 0.0
        if let t = d["PowerTelemetryData"] as? [String: Any] {
            // Load and adapter output are flow magnitudes, not signed quantities — the
            // Mac cannot consume negative watts and an adapter cannot deliver them — so
            // both floor at zero. Battery power is the one genuinely signed flow
            // (+ charging, − discharging). `rawLoadW` keeps the unfloored SystemLoad,
            // because its sign is the tell for the stale window handled below.
            rawLoadW = num(t["SystemLoad"]) / 1000
            s.loadW = max(0, rawLoadW)
            s.batteryW = signed(t["BatteryPower"]) / 1000
            s.totalInW = watts(t["SystemPowerIn"])
        }
        s.amps = signed(d["InstantAmperage"]) / 1000

        // On battery there is exactly one source, so the adapter reads nothing and
        // battery power mirrors the load. But the telemetry block lags the plug by
        // ~14 s: at the instant of unplug SystemPowerIn drops to 0 while BatteryPower
        // still holds its on-AC *charging* value, and the firmware derives SystemLoad
        // as SystemPowerIn − BatteryPower — so load goes momentarily negative (observed
        // live: in=0, batt=+91.5, load=−91.5). A negative load is impossible; it is the
        // tell that the block hasn't refreshed, so the last good load stands in until it
        // does, rather than reporting 0 W for those seconds.
        if !s.onAC {
            s.totalInW = 0
            s.loadW = Self.settledLoad(rawLoadW: rawLoadW, lastGood: previous?.loadW)
            s.batteryW = -s.loadW
        }

        if let ad = d["AdapterDetails"] as? [String: Any] {
            s.adapterWatts = Int(num(ad["Watts"]))
        }
        return s
    }

    private static func num(_ v: Any?) -> Double {
        (v as? NSNumber)?.doubleValue ?? 0
    }

    /// The load to report on battery. A negative raw reading means the telemetry block
    /// has not refreshed since unplug — SystemLoad is derived from a stale, still-positive
    /// BatteryPower — so the last good load stands in until it does; any non-negative
    /// reading is taken as is. The result is always a real, non-negative draw.
    static func settledLoad(rawLoadW: Double, lastGood: Double?) -> Double {
        rawLoadW >= 0 ? rawLoadW : (lastGood ?? 0)
    }

    /// A one-directional flow, converted from milliwatts and floored at zero.
    ///
    /// Floored rather than passed through because a negative here is not a small
    /// reading, it is a wrong one, and every consumer would have to defend against it
    /// separately — the bar chart already did (`max(sample.loadW, 0)`) while the metric
    /// cell did not, which is exactly how "−50 W" reached the panel.
    static func watts(_ v: Any?) -> Double {
        max(0, num(v) / 1000)
    }

    /// IOKit reports negative power/current as wrapped uint64 (2^64 − n).
    private static func signed(_ v: Any?) -> Double {
        guard let n = v as? NSNumber else { return 0 }
        return Double(Int64(bitPattern: n.uint64Value))
    }
}
