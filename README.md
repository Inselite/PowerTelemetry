# Power Telemetry

A native macOS menu bar app that shows real-time power telemetry for Apple Silicon
MacBooks: adapter output, battery charge/discharge power, system load, and charge
level — sampled at 1 Hz, no sudo, no dependencies.

## Build & run

```bash
swift run                # dev run
./scripts/make_app.sh    # produces PowerTelemetry.app
open PowerTelemetry.app
```

Or open `Package.swift` in Xcode and press Run.

The app lives in the menu bar (no Dock icon). Click the wattage readout to open
the dashboard popover.

## What the numbers mean

| Metric | Meaning |
|---|---|
| Adapter output | Power the charger is currently delivering (ceiling = negotiated watts, e.g. 140 W) |
| Battery charge power | Positive: charging. Negative (amber): battery is supplementing the adapter during load spikes |
| System load | What the Mac itself is consuming (CPU + GPU + ANE + platform) |
| Battery level | Charge %, with ETA or "holding at 80%" when optimized charging is active |

## Sharing with friends

The bundled `PowerTelemetry.app` is ad-hoc signed. Friends on Apple Silicon Macs
(macOS 14+) can run it, but Gatekeeper will warn on first launch:
**right-click → Open → Open**.

For a warning-free install you need a paid Apple Developer account ($99/yr), then:

```bash
codesign --force --deep --options runtime \
  --sign "Developer ID Application: Your Name (TEAMID)" PowerTelemetry.app
xcrun notarytool submit PowerTelemetry.zip --apple-id you@example.com --team-id TEAMID --wait
xcrun stapler staple PowerTelemetry.app
```

## Notes

- Data source: IOKit `AppleSmartBattery` registry (`PowerTelemetryData`,
  `InstantAmperage`, `AdapterDetails`). No elevated privileges required.
- Intel Macs expose different fields; this app targets Apple Silicon.
- History is kept for 1 hour (3,600 samples) in memory; nothing is written to disk.
