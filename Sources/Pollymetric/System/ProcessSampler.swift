import Darwin
import Foundation

struct ProcessRow: Identifiable, Equatable, Sendable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var cpu: Double          // % of one core; can exceed 100 for multithreaded work
    var memoryBytes: Int64   // physical footprint, the same number Activity Monitor shows
    var identity: ProcessIdentity?

    var title: String { identity?.label ?? name }
    var subtitle: String? { identity?.subtitle }
}

/// One batch of notable processes for the history database.
struct ProcessRecord: Sendable {
    var identity: ProcessIdentity
    var cpu: Double
    var memory: Int64
}

struct ProcessSample: Sendable {
    var top: [ProcessRow]
    var records: [ProcessRecord]
    var recordDuration: TimeInterval
}

/// Samples every process you own through libproc (`proc_pid_rusage`). A full pass over
/// ~1,500 processes takes about 4 ms and spawns nothing. CPU is measured as the exact
/// delta of each process's CPU time, not ps's decaying average.
///
/// Root-owned processes (Spotlight, WindowServer, backupd) aren't readable this way. When
/// system CPU exceeds what your own processes account for by a full core or more, the
/// sampler asks `ps` once so the real culprit still shows up.
final class ProcessSampler {
    static let recordInterval: TimeInterval = 10
    static let notableCPU: Double = 20
    static let notableMemory: Int64 = 2 * 1_073_741_824

    private let nanosPerTick: Double
    private let resolver = IdentityResolver()
    private var previous: [Int32: (start: UInt64, cpu: UInt64)] = [:]
    private var previousAt: UInt64 = 0
    private var baseline: [Int32: (start: UInt64, cpu: UInt64)] = [:]
    private var baselineAt: UInt64 = 0
    private var lastFallbackAt: UInt64 = 0
    private var fallbackRows: [ProcessRow] = []
    private var lastMemoryRecord: [Int32: UInt64] = [:]

    init() {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        nanosPerTick = Double(timebase.numer) / Double(timebase.denom)
    }

    func sample(systemBusyCores: Double, topCount: Int) -> ProcessSample {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - previousAt) / 1e9
        let recordElapsed = Double(now - baselineAt) / 1e9
        let recordDue = baselineAt == 0 || recordElapsed >= Self.recordInterval * 0.95

        var current: [Int32: (start: UInt64, cpu: UInt64)] = [:]
        var live: [(pid: Int32, start: UInt64, cpu: Double, footprint: Int64, recordCPU: Double)] = []

        for pid in Self.allPIDs() where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let start = info.ri_proc_start_abstime
            let cpuTicks = info.ri_user_time + info.ri_system_time
            current[pid] = (start, cpuTicks)

            func percent(since reference: (start: UInt64, cpu: UInt64)?, seconds: Double) -> Double {
                guard let reference, reference.start == start, cpuTicks >= reference.cpu, seconds > 0 else { return 0 }
                return Double(cpuTicks - reference.cpu) * nanosPerTick / 1e9 / seconds * 100
            }
            live.append((
                pid, start,
                percent(since: previous[pid], seconds: elapsed),
                Int64(info.ri_phys_footprint),
                recordDue ? percent(since: baseline[pid], seconds: recordElapsed) : 0
            ))
        }

        let firstPass = previousAt == 0
        previous = current
        previousAt = now

        // Unexplained CPU → one `ps` call, at most every 30 seconds.
        let visibleCores = live.reduce(0) { $0 + $1.cpu } / 100
        if !firstPass, systemBusyCores - visibleCores >= 1, now - lastFallbackAt > 30_000_000_000 {
            lastFallbackAt = now
            fallbackRows = Self.otherUsersViaPS(excluding: Set(current.keys))
        } else if systemBusyCores - visibleCores < 0.5 {
            fallbackRows = []
        }

        var rows = live.map { ProcessRow(pid: $0.pid, name: "", cpu: $0.cpu, memoryBytes: $0.footprint) }
        rows.append(contentsOf: fallbackRows)
        rows.sort { $0.cpu > $1.cpu }
        let starts = Dictionary(uniqueKeysWithValues: live.map { ($0.pid, $0.start) })

        func resolve(_ row: ProcessRow) -> ProcessRow {
            guard row.identity == nil else { return row }
            var row = row
            let name = IdentityResolver.name(pid: row.pid) ?? "pid \(row.pid)"
            let identity = resolver.identity(pid: row.pid, start: starts[row.pid] ?? 0, name: name)
            row.name = identity.name
            row.identity = identity
            return row
        }
        let top = firstPass ? [] : rows.prefix(topCount).map(resolve)

        // History records: CPU averaged over the full ~10 s record window, so summing
        // cpu × duration gives exact CPU-seconds per process.
        var records: [ProcessRecord] = []
        if recordDue, !firstPass, baselineAt != 0 {
            for entry in live {
                let heavy = entry.footprint >= Self.notableMemory
                let memoryDue = heavy && now - (lastMemoryRecord[entry.pid] ?? 0) >= 60_000_000_000
                guard entry.recordCPU >= Self.notableCPU || memoryDue else { continue }
                if memoryDue { lastMemoryRecord[entry.pid] = now }
                let name = IdentityResolver.name(pid: entry.pid) ?? "pid \(entry.pid)"
                records.append(ProcessRecord(
                    identity: resolver.identity(pid: entry.pid, start: entry.start, name: name),
                    cpu: entry.recordCPU,
                    memory: entry.footprint
                ))
            }
            for row in fallbackRows where row.cpu >= Self.notableCPU {
                if let identity = row.identity { records.append(ProcessRecord(identity: identity, cpu: row.cpu, memory: row.memoryBytes)) }
            }
        }
        if recordDue {
            let duration = recordElapsed
            baseline = current
            baselineAt = now
            resolver.prune(keeping: Set(current.keys))
            lastMemoryRecord = lastMemoryRecord.filter { current[$0.key] != nil }
            return ProcessSample(top: top, records: records, recordDuration: duration)
        }
        return ProcessSample(top: top, records: [], recordDuration: 0)
    }

    /// Start time via sysctl, which (unlike libproc) works for root-owned processes too.
    private static func startTime(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }

    private static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(0, count))))
    }

    /// `ps` is setuid on macOS, so it can see root-owned processes that libproc can't.
    private static func otherUsersViaPS(excluding own: Set<Int32>) -> [ProcessRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aeo", "pid=,pcpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var rows: [ProcessRow] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let cpu = Double(fields[1]), let rss = Int64(fields[2]) else { continue }
            if cpu < 10 { break }
            guard !own.contains(pid) else { continue }
            let path = String(fields[3])
            let name = (path as NSString).lastPathComponent
            let identity = ProcessIdentity(
                key: "\(pid)-ps", pid: pid, startedAt: startTime(pid) ?? .now, name: name, label: name, context: nil, via: nil,
                app: path.range(of: ".app/").map { ((String(path[..<$0.lowerBound]) as NSString).lastPathComponent) },
                appPath: nil, executable: path, command: path, cwd: nil, chain: []
            )
            rows.append(ProcessRow(pid: pid, name: name, cpu: cpu, memoryBytes: rss * 1024, identity: identity))
            if rows.count == 5 { break }
        }
        return rows
    }
}
