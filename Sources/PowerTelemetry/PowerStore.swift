import Foundation

/// Samples the sensor at 1 Hz and keeps a rolling history.
@MainActor
final class PowerStore: ObservableObject {
    @Published private(set) var samples: [PowerSample] = []
    @Published private(set) var unsupported = false

    private var timer: Timer?
    private let maxSamples = 43200 // 12 hours at 1 Hz (~4 MB)

    var latest: PowerSample? { samples.last }

    func start() {
        guard timer == nil else { return } // label onAppear can fire repeatedly
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let sample = PowerSensor.read() else {
            unsupported = true
            return
        }
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
}
