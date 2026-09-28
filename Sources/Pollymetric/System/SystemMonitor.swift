import AppKit
import Foundation
import Observation

/// Owns the sampling cadence. While the menu is closed it samples every 10 seconds,
/// using timer tolerance so macOS can batch the wakeups with other work. While you're
/// looking at the panel or dashboard it samples every 2 seconds and adds the process list.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var snapshot: SystemSnapshot?
    private(set) var cpuHistory: [Double] = []
    private(set) var processes: [ProcessRow] = []

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private let processSampler = ProcessSampler()
    @ObservationIgnored private let processQueue = DispatchQueue(label: "pollymetric.processes", qos: .utility)
    @ObservationIgnored private var processPending = false
    @ObservationIgnored private var lastSystemRecord = Date.distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var live = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    var health: Health? { snapshot.map { HealthScore.compute($0, sustained: false) } }
    var menuBarHealth: Health? { snapshot.map { HealthScore.compute($0, sustained: true) } }

    func start() {
        _ = sampler.sample() // prime the CPU baseline
        schedule()
        // First real reading one second later, so CPU is a true delta, not a since-boot average.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sampleNow() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleNow() }
        }
    }

    func setLive(_ on: Bool) {
        guard on != live else { return }
        live = on
        schedule()
        if on { sampleNow() }
    }

    func sampleNow() {
        let next = sampler.sample()
        snapshot = next
        cpuHistory.append(next.cpuUsage)
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
        sampleProcesses(systemBusyCores: next.cpuUsage / 100 * Double(ProcessInfo.processInfo.activeProcessorCount))

        if next.date.timeIntervalSince(lastSystemRecord) >= 60 {
            lastSystemRecord = next.date
            if !DataDirectory.isSnapshot { HistoryStore.shared.recordSystem(next, score: HealthScore.compute(next, sustained: true).score) }
        }
    }

    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = live ? 2 : 10
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleNow() }
        }
        timer.tolerance = live ? 0.25 : 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Process sampling runs on every tick, open or closed, because history needs it.
    /// Names and attribution are resolved only for the top rows and notable processes.
    private func sampleProcesses(systemBusyCores: Double) {
        guard !processPending else { return }
        processPending = true
        let topCount = live ? 8 : 3
        processQueue.async { [processSampler] in
            let sample = processSampler.sample(systemBusyCores: systemBusyCores, topCount: topCount)
            if !sample.records.isEmpty {
                if !DataDirectory.isSnapshot { HistoryStore.shared.record(sample.records, duration: sample.recordDuration) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.processPending = false
                if !sample.top.isEmpty { self.processes = sample.top }
            }
        }
    }
}

enum ProcessList {
    /// Asks an app to quit the normal way; falls back to SIGTERM for plain processes.
    static func quit(_ row: ProcessRow) {
        if let app = NSRunningApplication(processIdentifier: row.pid) {
            app.terminate()
        } else {
            kill(row.pid, SIGTERM)
        }
    }
}
