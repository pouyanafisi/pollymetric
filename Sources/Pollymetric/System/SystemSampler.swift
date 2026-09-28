import Darwin
import Foundation
import IOKit
import IOKit.ps

struct BatteryInfo: Equatable, Sendable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var cycleCount: Int
    /// Full-charge capacity as a percentage of design capacity (battery health).
    var healthPercent: Int
}

enum MemoryPressure: String, Sendable {
    case normal, warn, critical
}

struct SystemSnapshot: Equatable, Sendable {
    var date: Date
    /// CPU busy % over the last sampling interval.
    var cpuUsage: Double
    /// CPU busy % over roughly the last 30 seconds. Drives the menu bar score, so a
    /// one-second spike doesn't flip the icon.
    var cpuSustained: Double
    var memoryUsedPercent: Double
    var memoryUsedBytes: UInt64
    var memoryTotalBytes: UInt64
    var memoryPressure: MemoryPressure
    var diskUsedPercent: Double
    var diskFreeBytes: Int64
    var diskTotalBytes: Int64
    var diskIOMBps: Double
    var battery: BatteryInfo?
    var uptime: TimeInterval
}

/// Reads system metrics straight from the kernel: Mach host statistics, sysctl,
/// statfs and IOKit. One sample takes well under a millisecond, versus several
/// seconds of CPU for `mo status --json`, which is why the menu bar never shells out.
final class SystemSampler {
    // mach_host_self() hands out a new port right on every call; ask once.
    private let host = mach_host_self()
    private var cpuWindow: [(date: Date, busy: UInt64, total: UInt64)] = []
    private var lastIO: (date: Date, bytes: UInt64)?
    private var batteryHealthCache: (date: Date, cycles: Int, health: Int)?

    func sample(now: Date = .now) -> SystemSnapshot {
        let (cpuNow, cpuSustained) = sampleCPU(now: now)
        let memory = sampleMemory()
        let disk = sampleDisk()
        return SystemSnapshot(
            date: now,
            cpuUsage: cpuNow,
            cpuSustained: cpuSustained,
            memoryUsedPercent: memory.percent,
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            memoryPressure: memoryPressure(),
            diskUsedPercent: disk.usedPercent,
            diskFreeBytes: disk.free,
            diskTotalBytes: disk.total,
            diskIOMBps: sampleDiskIO(now: now),
            battery: sampleBattery(now: now),
            uptime: uptime(now: now)
        )
    }

    // MARK: CPU

    private func sampleCPU(now: Date) -> (Double, Double) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        func usage(since start: (date: Date, busy: UInt64, total: UInt64)?) -> Double {
            guard let start, total > start.total else { return 0 }
            return Double(busy - start.busy) / Double(total - start.total) * 100
        }

        let instant = usage(since: cpuWindow.last)
        cpuWindow.append((now, busy, total))
        cpuWindow.removeAll { now.timeIntervalSince($0.date) > 90 }
        let anchor = cpuWindow.last { now.timeIntervalSince($0.date) >= 30 } ?? cpuWindow.first
        let sustained = anchor.map { $0.total == total ? instant : usage(since: $0) } ?? instant
        return (instant, sustained)
    }

    // MARK: Memory

    /// Matches gopsutil, which mole uses: available = free + inactive pages.
    private func sampleMemory() -> (used: UInt64, total: UInt64, percent: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS, total > 0 else { return (0, total, 0) }
        let page = UInt64(vm_kernel_page_size)
        let available = min(UInt64(stats.free_count + stats.inactive_count) * page, total)
        let used = total - available
        return (used, total, Double(used) / Double(total) * 100)
    }

    private func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warn
        default: return .normal
        }
    }

    // MARK: Disk

    private func sampleDisk() -> (usedPercent: Double, free: Int64, total: Int64) {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return (0, 0, 0) }
        let block = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * block
        let free = UInt64(fs.f_bavail) * block
        let used = (UInt64(fs.f_blocks) - UInt64(fs.f_bfree)) * block
        let percent = used + free > 0 ? Double(used) / Double(used + free) * 100 : 0
        return (percent, Int64(free), Int64(total))
    }

    private func sampleDiskIO(now: Date) -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }

        var bytes: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                bytes += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                bytes += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        defer { lastIO = (now, bytes) }
        guard let last = lastIO, bytes >= last.bytes else { return 0 }
        let seconds = now.timeIntervalSince(last.date)
        return seconds > 0 ? Double(bytes - last.bytes) / seconds / 1_048_576 : 0
    }

    // MARK: Battery

    private func sampleBattery(now: Date) -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery"
            else { continue }
            let current = description["Current Capacity"] as? Int ?? 0
            let max = description["Max Capacity"] as? Int ?? 100
            let health = batteryHealth(now: now)
            return BatteryInfo(
                percent: max > 0 ? current * 100 / max : current,
                isCharging: description["Is Charging"] as? Bool ?? false,
                onAC: description["Power Source State"] as? String == "AC Power",
                cycleCount: health.cycles,
                healthPercent: health.health
            )
        }
        return nil
    }

    /// Cycle count and capacity change over months, so read them every 10 minutes at most.
    private func batteryHealth(now: Date) -> (cycles: Int, health: Int) {
        if let cached = batteryHealthCache, now.timeIntervalSince(cached.date) < 600 {
            return (cached.cycles, cached.health)
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (0, 0) }
        defer { IOObjectRelease(service) }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let cycles = (property("CycleCount") as? NSNumber)?.intValue ?? 0
        let data = property("BatteryData") as? [String: Any] ?? [:]
        let full = (data["FullChargeCapacity"] as? NSNumber)?.intValue
            ?? (property("AppleRawMaxCapacity") as? NSNumber)?.intValue ?? 0
        let design = (data["DesignCapacity"] as? NSNumber)?.intValue
            ?? (property("DesignCapacity") as? NSNumber)?.intValue ?? 0
        let health = design > 0 ? min(100, full * 100 / design) : 0
        batteryHealthCache = (now, cycles, health)
        return (cycles, health)
    }

    // MARK: Uptime

    private func uptime(now: Date) -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return now.timeIntervalSince1970 - Double(boot.tv_sec)
    }
}
