# Power Telemetry

A native macOS menu bar utility for live power monitoring on Apple Silicon MacBooks.

It reads power data directly from IOKit — adapter output, system load, battery charge
and discharge, battery level. No admin privileges, kernel extensions, background
services, or network access.

## Features

- Menu bar wattage showing the highest active power flow, with the bolt tinted by source — meaningful on battery, not just on AC
- Power flow as bars, one bar carrying all three figures (see below)
- Battery level in the style of macOS Battery settings, with an adapter lane and a red warning zone
- Time ranges: 1 minute, 1 hour, 4 hours, or the whole session
- Hover to scrub history; a crosshair and readout pin any moment
- Negotiated adapter ceiling drawn as a reference line
- Resizable detail window, Light/Dark appearance, VoiceOver labels
- Up to 12 hours of in-memory history

## Installation

Download the latest zip from [Releases](https://github.com/Inselite/PowerTelemetry/releases),
extract, and move `PowerTelemetry.app` to Applications.

Builds are ad-hoc signed, not notarized: on first launch, right-click the app and
choose **Open**. The app lives in the menu bar and adds no Dock icon.

## Compatibility

Requires macOS 14 or later. Reads the `AppleSmartBattery` IOKit service
(`PowerTelemetryData`, `InstantAmperage`, `AdapterDetails`).

| System | Status |
|---|---|
| Apple Silicon MacBook Pro (development machine) | Tested |
| Other Apple Silicon MacBooks | Expected to work, not broadly verified |
| Intel MacBooks | Unknown; telemetry fields may differ |
| Desktop Macs without a battery | Not supported; shows an unavailable state |

Compatibility reports are welcome — include the Mac model, macOS version, and which
metrics are missing or wrong.

## Reading the charts

**Power flow.** The three figures are not independent:

```
adapter output = system load + battery charge
```

so one bar carries all three:

| Segment | Meaning |
|---|---|
| Orange | Load the adapter is supplying |
| Blue | Load the battery is supplying — the load outran the adapter, or nothing is plugged in |
| Green cap | Adapter surplus charging the battery |

The solid bar is always the system load; only its colour changes. Each bar keeps the
busiest sample of its slice, so bursts survive. Bars align to absolute time and never
move once drawn — new bars appear at the right. A dashed line marks the adapter
ceiling once the load approaches it.

**Battery level.**

| Mark | Meaning |
|---|---|
| Green bar | Battery level |
| Red bar | Below 20% |
| Lane beneath the chart | Adapter connected; a bolt marks actual charging |

Discharge has no mark of its own: it is the stretch where the lane is empty and the
level walks down, as in macOS's own battery chart.

## Metrics

| Metric | Meaning |
|---|---|
| Adapter output | Power entering the system from the adapter |
| System load | Power the Mac is consuming (CPU, GPU, ANE, display, platform) |
| Battery power | Positive: charging. Negative: the battery is supplying the Mac |
| Battery level | State of charge |

Values come from Apple's internal telemetry and can differ slightly from the wall
because of conversion losses. The app samples at 1 Hz, but the sensor itself refreshes
only every ~14 seconds — charts are honest staircases, and a change you cause can take
that long to appear.

## Privacy

Everything is read locally and kept in memory only. No network, no files, nothing
survives quitting the app.

## Build from source

Requires Xcode with the macOS SDK and Swift 5.9+.

```bash
git clone https://github.com/Inselite/PowerTelemetry.git
cd PowerTelemetry
./scripts/make_app.sh
open PowerTelemetry.app
```

For development: `swift run`, or open `Package.swift` in Xcode. Tests: `swift test`.
