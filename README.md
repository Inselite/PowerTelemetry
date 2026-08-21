# Power Telemetry

Power Telemetry is a native macOS menu bar utility for monitoring live power flow on supported MacBooks.

It reads power data directly from IOKit and displays adapter output, system load, battery charge or discharge power, and battery level. No administrator privileges, kernel extensions, background service, or network connection are required.

## Features

- Live wattage in the macOS menu bar, always showing the highest active power flow — adapter output, system load, or battery power — so the reading stays meaningful on battery
- Adapter output, system load, and signed battery power at 1 Hz
- Power drawn as bars per time slice, encoding all three flows in one shape (see [Reading the power chart](#reading-the-power-chart))
- Battery level as bars, with charging and holding periods marked as bands
- Dynamic chart scale with a negotiated adapter-ceiling reference
- Time ranges for the last 1 minute, 1 hour, 4 hours, or the current session
- Hover any chart to scrub history: a crosshair pins that moment, a readout follows it, and the metric cells report its values
- Smooth, continuously moving time axis
- Resizable detailed window in addition to the menu bar popover
- Native macOS controls and semantic system colors for Light and Dark appearances
- VoiceOver labels for metrics and charts
- Up to 12 hours of in-memory history

## Installation

Download the latest zip from [Releases](https://github.com/Inselite/PowerTelemetry/releases), extract it, and move `PowerTelemetry.app` to Applications.

Current builds are ad-hoc signed and are not notarized by Apple. On first launch, macOS may require:

1. Right-click `PowerTelemetry.app`
2. Select **Open**
3. Confirm **Open**

The app runs in the menu bar and does not add a Dock icon.

## Compatibility

Power Telemetry requires macOS 14 or later.

The current implementation reads the `AppleSmartBattery` IOKit service and its `PowerTelemetryData`, `InstantAmperage`, and `AdapterDetails` fields.

| System | Status |
|---|---|
| Apple Silicon MacBook Pro used for development | Tested |
| Other Apple Silicon MacBooks exposing the same IOKit fields | Expected to work, not yet broadly verified |
| Intel MacBooks | Unknown; telemetry fields may differ |
| Desktop Macs without a battery | Not supported; the app displays an unavailable state |

Compatibility reports are welcome. Include the Mac model, macOS version, and which metrics are missing or incorrect.

## Reading the power chart

Each bar is one slice of time. The three figures are not independent — the adapter's
output splits into what the Mac is using and what is going into the battery:

```
adapter output = system load + battery charge
```

so a single bar carries all three without stacking unrelated quantities:

| Segment | Meaning |
|---|---|
| Orange | The part of the system load the adapter is supplying |
| Blue | The part the battery is supplying — the load has outrun the adapter, or nothing is plugged in |
| Green (cap on top) | Adapter output above the load: surplus charging the battery |

**The solid bar is always the system load**, whatever the state; only its colour changes
to show who is paying for it. The green cap only appears while charging, so the full
silhouette is adapter output when charging and system load otherwise. Direction is
carried by colour rather than by sign, so the axis never needs to go below zero.

Each bar takes the busiest sample in its slice rather than an average, so bursts survive.
Slices align to absolute time, so a bar's edges never move once drawn — new bars appear
at the right instead of every bar shifting. The newest bar is dimmed while it is still
filling.

## Metrics

| Metric | Meaning |
|---|---|
| Adapter output | Power currently entering the system from the connected adapter |
| Adapter ceiling | Negotiated maximum adapter power, such as 140 W |
| System load | Power consumed by the Mac, including CPU, GPU, ANE, memory, storage, display, and platform components |
| Battery power | Positive values mean charging; negative values mean the battery is supplementing the adapter or powering the Mac |
| Battery level | Current state of charge, including optimized-charging hold states when detectable |

The values come from Apple's internal power telemetry and may differ slightly from measurements taken at the wall because of adapter conversion losses and sampling time.

Power Telemetry samples at 1 Hz, but on the hardware tested `AppleSmartBattery` only
refreshes its telemetry roughly every 14 seconds, holding each value in between. Charts
are therefore honest staircases rather than smooth curves, and a change you cause can
take up to ~14 seconds to appear.

## Privacy

All telemetry is read locally. Power Telemetry does not use the network and does not write measurement history to disk. Samples remain in memory and are discarded when the app exits.

## Build from source

Requirements:

- Xcode with the macOS SDK
- Swift 5.9 or later

```bash
git clone https://github.com/Inselite/PowerTelemetry.git
cd PowerTelemetry
./scripts/make_app.sh
open PowerTelemetry.app
```

For development, open `Package.swift` in Xcode or run:

```bash
swift run
```

The icon can be regenerated from source with:

```bash
swift scripts/make_icon.swift .
iconutil -c icns AppIcon.iconset
```

## Technical notes

- Sampling interval: 1 second
- Visual chart refresh: 5 Hz
- Maximum retained history: 12 hours
- Runtime dependencies: none
- Elevated privileges: not required
