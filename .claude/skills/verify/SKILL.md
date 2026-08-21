---
name: verify
description: Build, launch and drive Power Telemetry to observe UI changes at runtime.
---

# Verifying Power Telemetry

Menu bar app (`LSUIElement`, no Dock icon). The surface is pixels: the menu bar
item, the popover, and the main window.

## Build and launch

```bash
swift build -c release            # compile check
./scripts/make_app.sh             # assemble + ad-hoc sign PowerTelemetry.app
pkill -x PowerTelemetry; sleep 1
open -a "$PWD/PowerTelemetry.app" # `open -a ./PowerTelemetry.app` fails — needs an absolute path
```

## Driving it

Build the input/capture helper once (`scratchpad/drive.swift` pattern):
`drive click X Y`, `drive move X Y` post real `CGEvent`s.

```bash
# menu bar item geometry (its AX name is the app's accessibility label —
# a readable proxy for what the menu bar is currently showing)
osascript -e 'tell application "System Events" to tell process "PowerTelemetry" \
  to get {name, position, size} of menu bar item 1 of menu bar 2'

drive click $((X + W/2)) 14        # opens the popover
drive click 2014 288               # expand button (right of "Power flow"), opens the main window
osascript -e 'tell application "System Events" to tell process "PowerTelemetry" \
  to get {position, size} of window 1'   # 1 = popover, 2 = main window
screencapture -x -R<x>,<y>,<w>,<h> shot.png
```

Hover/scrub: `drive move X Y` inside a chart's plot area, then capture. The header
swaps its green live dot for the scrubbed timestamp — that's the tell that hover is active.

## Gotchas

- **Open the popover with `CGEvent` clicks, not System Events.** A System Events
  click activates that process and the popover dismisses before you can capture.
- **`CGWindowListCreateImage` is unavailable** (macOS 15+, use ScreenCaptureKit).
  `screencapture -l<id>` / `-R` still work. `CGWindowListCopyWindowInfo` does not
  list this app's windows at all — get geometry from System Events AX instead.
- **Raise the window with `set frontmost to true`, not `AXRaise`.** On a machine the
  user is actively working on, other windows cover the app between steps and every
  capture silently grabs the wrong pixels. `perform action "AXRaise"` returns
  `missing value` and does nothing here. Re-raise immediately before each
  click/hover/capture, and sanity-check the capture actually shows the app.
- **Wake the display first.** A sleeping display makes `screencapture -R` fail with
  "could not create image from rect". Prefix with `caffeinate -u -t 2`.
- **The sensor updates every ~13-14 s, not 1 Hz.** `AppleSmartBattery`'s
  `PowerTelemetryData` holds a value for ~14 identical 1 Hz samples, so real charts
  are stair-steps. Don't mistake a plateau for a frozen UI — sample for 40s+ before
  concluding anything is stuck.
- **Ground truth is IOKit**, read independently of the app (see `scratchpad/probe.swift`:
  `SystemPowerIn`, `SystemLoad`, `BatteryPower`, all /1000; negatives arrive as
  wrapped uint64).
- **On-battery paths cannot be driven programmatically.** No supported way to fake
  AC state; the adapter here is 140 W and CPU-only load peaks near 82 W, so the
  battery-supplementing path is unreachable while plugged in. Ask the user to unplug.

## Cost baseline

Idling with no window open the app sits at ~1.2% CPU / 19 MB. Opening the popover
once takes it to ~9% CPU / 240 MB **and it stays there after the popover closes**
(~20% with the main window open). That is pre-existing, measured identical on
`32f2375`; if you are attributing a CPU change, A/B against a worktree build rather
than trusting a single reading:

```bash
git worktree add /tmp/pt-head HEAD && cd /tmp/pt-head && ./scripts/make_app.sh
/tmp/pt-head/PowerTelemetry.app/Contents/MacOS/PowerTelemetry &   # runs alongside
top -l 4 -s 2 -pid $(pgrep -x PowerTelemetry) -stats pid,cpu,mem
```

`ps -o %cpu` is a lifetime average and will mislead you — use `top -l`.

## Rendering states without hardware

`scratchpad/harness/` compiles the real `DashboardView.swift`/`Theme.swift` against a
stub `PowerStore` with a `seed()` hook, hosted in a plain `NSWindow`. Use it for states
the hardware won't produce (on battery, supplementing, unsupported, light appearance).
Note it is *not* a substitute for driving the real app — `ImageRenderer` silently fails
to rasterize AppKit controls (the segmented picker renders as a blank box).
