import Foundation

enum HealthBand: String, Sendable {
    case excellent, good, fair, poor

    init(score: Int) {
        switch score {
        case 85...: self = .excellent
        case 65...: self = .good
        case 45...: self = .fair
        default: self = .poor
        }
    }

    var title: String {
        switch self {
        case .excellent: "Excellent"
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Needs attention"
        }
    }

    /// The menu bar is monochrome unless something actually needs you.
    var wantsAttention: Bool { self == .fair || self == .poor }
}

struct Health: Equatable, Sendable {
    var score: Int
    var band: HealthBand
    var issues: [String]
}

/// A port of mole's `calculateHealthScore` (cmd/status/metrics_health.go), so the
/// number in the menu bar means the same thing as the one `mo status` shows.
/// Thermal is skipped: mole reports no CPU temperature on Apple Silicon, so it never
/// contributes a penalty there either.
enum HealthScore {
    static func compute(_ s: SystemSnapshot, sustained: Bool) -> Health {
        var score = 100.0
        var issues: [String] = []
        let cpu = sustained ? s.cpuSustained : s.cpuUsage

        func penalty(_ value: Double, normal: Double, high: Double, weight: Double) -> Double {
            guard value > normal else { return 0 }
            if value > high { return weight * (value - normal) / (100 - normal) }
            return (weight / 2) * (value - normal) / (high - normal)
        }

        score -= penalty(cpu, normal: 50, high: 85, weight: 30)
        if cpu > 85 { issues.append("High CPU") }

        score -= penalty(s.memoryUsedPercent, normal: 70, high: 88, weight: 25)
        if s.memoryUsedPercent > 88 { issues.append("High Memory") }
        switch s.memoryPressure {
        case .warn: score -= 5; issues.append("Memory Pressure")
        case .critical: score -= 15; issues.append("Critical Memory")
        case .normal: break
        }

        score -= penalty(s.diskUsedPercent, normal: 80, high: 93, weight: 20)
        if s.diskUsedPercent > 93 { issues.append("Disk Almost Full") }

        if s.diskIOMBps > 150 {
            score -= 10
            issues.append("Heavy Disk IO")
        } else if s.diskIOMBps > 50 {
            score -= 10 * (s.diskIOMBps - 50) / 100
        }

        if let battery = s.battery {
            switch batterySeverity(cycles: battery.cycleCount, health: battery.healthPercent) {
            case .danger: score -= 5; issues.append("Battery Service Soon")
            case .warn: score -= 2
            case .ok: break
            }
        }

        if s.uptime > 14 * 86_400 {
            score -= 3
            issues.append("Restart Recommended")
        } else if s.uptime > 7 * 86_400 {
            score -= 1
        }

        let clamped = Int(min(100, max(0, score)))
        return Health(score: clamped, band: HealthBand(score: clamped), issues: issues)
    }

    enum Severity { case ok, warn, danger }

    static func batterySeverity(cycles: Int, health: Int) -> Severity {
        if cycles > 900 || (health > 0 && health < 60) { return .danger }
        if cycles > 800 || (health > 0 && health < 80) { return .warn }
        return .ok
    }
}
