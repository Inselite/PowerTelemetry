import SwiftUI

@main
struct PowerTelemetryApp: App {
    @StateObject private var store = PowerStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(store)
                .frame(width: 460)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            HStack(spacing: 3) {
                menuBarBolt
                Text(store.latest.map { "\(Int($0.peakW)) W" } ?? "—")
                    .monospacedDigit()
            }
            .onAppear { store.start() }
            .accessibilityLabel(store.latest.map { "\(menuBarSourceName($0)) \(Int($0.peakW)) watts" } ?? "No power telemetry")
        }
        .menuBarExtraStyle(.window)

        Window("Power Telemetry", id: "main") {
            DashboardView()
                .environmentObject(store)
                .frame(minWidth: 520, idealWidth: 760, minHeight: 700, idealHeight: 740)
        }
        .defaultSize(width: 760, height: 740)
    }

    /// Tints the menu bar bolt with the same series color the popover uses for that
    /// flow, so the number's source reads at a glance. Color is the visible cue and
    /// `menuBarSourceName` carries it in words for VoiceOver — color alone would
    /// leave the source unreadable to anyone who can't distinguish these hues.
    ///
    /// System load keeps the plain template symbol: its series color is neutral gray,
    /// and a template inverts with the menu bar the way a baked-in color cannot.
    private var menuBarBolt: Image {
        switch store.latest?.peakSource {
        case .adapter: return Self.adapterBolt
        case .batteryCharge, .batteryDischarge: return Self.batteryBolt
        case .load, nil: return Image(systemName: "bolt.fill")
        }
    }

    private static let adapterBolt = tintedBolt(.systemOrange) // matches Color.ptAdapter
    private static let batteryBolt = tintedBolt(.systemBlue)   // matches Color.ptCharge

    /// A `MenuBarExtra` label draws SF Symbols as monochrome templates and discards
    /// `foregroundStyle`, so the tint has to be baked into a non-template image that
    /// asks for `.original` rendering.
    private static func tintedBolt(_ color: NSColor) -> Image {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil),
              let tinted = symbol.withSymbolConfiguration(config) else {
            return Image(systemName: "bolt.fill")
        }
        tinted.isTemplate = false
        return Image(nsImage: tinted).renderingMode(.original)
    }

    /// The menu bar shows the largest power flow, which changes as the Mac plugs
    /// in, charges, or runs on battery — name it so the number is unambiguous.
    private func menuBarSourceName(_ s: PowerSample) -> String {
        switch s.peakSource {
        case .adapter: return "Adapter output"
        case .load: return "System load"
        case .batteryCharge: return "Battery charge"
        case .batteryDischarge: return "Battery discharge"
        }
    }
}
