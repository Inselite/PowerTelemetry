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
                Image(systemName: "bolt.fill")
                Text(store.latest.map { "\(Int($0.totalInW)) W" } ?? "—")
                    .monospacedDigit()
            }
            .onAppear { store.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Power Telemetry", id: "main") {
            DashboardView()
                .environmentObject(store)
                .frame(minWidth: 520, idealWidth: 760, minHeight: 520, idealHeight: 680)
        }
        .defaultSize(width: 760, height: 680)
    }
}
