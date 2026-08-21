# Power Telemetry

Power Telemetry is a native macOS menu bar utility for monitoring live power flow on supported MacBooks.

It reads power data directly from IOKit and displays adapter output, system load, battery charge or discharge power, and battery level. No administrator privileges, kernel extensions, background service, or network connection are required.

## Features

- Live wattage in the macOS menu bar, always showing the highest active power flow — adapter output, system load, or battery power — so the reading stays meaningful on battery
- Adapter output, system load, and signed battery power at 1 Hz
- Power drawn as bars per time slice: the solid bar is system load, coloured by whether the adapter or the battery is supplying it, and the faded cap above it is surplus charging the battery
- Battery level as bars with charging / holding periods marked as bands
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

## Metrics

| Metric | Meaning |
|---|---|
| Adapter output | Power currently entering the system from the connected adapter |
| Adapter ceiling | Negotiated maximum adapter power, such as 140 W |
| System load | Power consumed by the Mac, including CPU, GPU, ANE, memory, storage, display, and platform components |
| Battery power | Positive values mean charging; negative values mean the battery is supplementing the adapter or powering the Mac |
| Battery level | Current state of charge, including optimized-charging hold states when detectable |

The values come from Apple's internal power telemetry and may differ slightly from measurements taken at the wall because of adapter conversion losses and sampling time.

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
