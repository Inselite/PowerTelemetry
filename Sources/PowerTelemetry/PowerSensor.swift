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
}

enum PowerSensor {
    /// Returns nil on Macs without battery telemetry (desktops, Intel).
    static func read() -> PowerSample? {
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

        if let t = d["PowerTelemetryData"] as? [String: Any] {
            s.loadW = num(t["SystemLoad"]) / 1000
            s.batteryW = signed(t["BatteryPower"]) / 1000
            s.totalInW = num(t["SystemPowerIn"]) / 1000
        }
        s.amps = signed(d["InstantAmperage"]) / 1000

        if let ad = d["AdapterDetails"] as? [String: Any] {
            s.adapterWatts = Int(num(ad["Watts"]))
        }
        return s
    }

    private static func num(_ v: Any?) -> Double {
        (v as? NSNumber)?.doubleValue ?? 0
    }

    /// IOKit reports negative power/current as wrapped uint64 (2^64 − n).
    private static func signed(_ v: Any?) -> Double {
        guard let n = v as? NSNumber else { return 0 }
        return Double(Int64(bitPattern: n.uint64Value))
    }
}
