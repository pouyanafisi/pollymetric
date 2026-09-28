import XCTest
@testable import Pollymetric

final class ParserTests: XCTestCase {
    func testBytesParseUsesMoleUnits() {
        XCTAssertEqual(Bytes.parse("0B"), 0)
        XCTAssertEqual(Bytes.parse("12KB"), 12 * 1024)
        XCTAssertEqual(Bytes.parse("818.1MB"), Int64(818.1 * 1_048_576))
        XCTAssertEqual(Bytes.parse("37.52GB"), Int64(37.52 * 1_073_741_824))
        XCTAssertNil(Bytes.parse("unknown"))
        XCTAssertEqual(Bytes.format(Int64(37.52 * 1_073_741_824)), "37.5 GB")
        XCTAssertEqual(Bytes.format(Int64(3.97 * 1_073_741_824)), "3.97 GB")
    }

    func testCleanPreviewSkipsChildrenAndSorts() {
        let list = """
        # Mole Cleanup Preview
        #   /Users/*/Library/Caches/com.example.app

        === User essentials ===
        /Users/me/Library/Caches/Small  # 12KB
        /Users/me/Library/Caches/Google  # 818.1MB
        /Users/me/Library/Caches/Google/Chrome/Default  # 818.1MB, counted under /Users/me/Library/Caches/Google
        === Developer tools ===
        /Library/Developer/CoreSimulator/Caches/dyld  # 34.02GB
        === Empty ===
        # Potential cleanup: 37.52GB
        """
        let output = "Potential space: 37.52GB | Items: 330 | Categories: 6"
        let preview = CleanPreview.parse(list: list, output: output)

        XCTAssertEqual(preview.itemCount, 330)
        XCTAssertEqual(preview.totalBytes, Bytes.parse("37.52GB"))
        XCTAssertEqual(preview.sections.map(\.name), ["Developer tools", "User essentials"])
        XCTAssertEqual(preview.sections[1].items.map(\.path), ["/Users/me/Library/Caches/Google", "/Users/me/Library/Caches/Small"])
    }

    func testPurgePreview() {
        let output = """
        ✓ [DRY RUN] ~/ai/shop/.next, 52.8MB
        ✓ [DRY RUN] ~/ai/integration, builder/node_modules, 67.5MB
        Would free approximately: 3.97GB | Items: 22 | Free: 3075.35GB
        """
        let preview = PurgePreview.parse(output)
        XCTAssertEqual(preview.items.count, 2)
        XCTAssertEqual(preview.items[0].artifact, "node_modules")
        XCTAssertEqual(preview.items[0].path, Paths.home + "/ai/integration, builder/node_modules")
        XCTAssertEqual(preview.totalBytes, Bytes.parse("3.97GB"))
    }

    func testLynisReport() {
        let text = """
        lynis_version=3.1.4
        hardening_index=64
        warning[]=FIRE-4590|Firewall not enabled|-|-|
        suggestion[]=SSH-7408|Consider hardening SSH configuration|AllowTcpForwarding (set YES to NO)|-|
        suggestion[]=BOOT-5139|Set a password on the boot loader|-|-|
        """
        let report = LynisReport.parse(text, date: .distantPast)
        XCTAssertEqual(report.hardeningIndex, 64)
        XCTAssertEqual(report.version, "3.1.4")
        XCTAssertEqual(report.warnings.map(\.testID), ["FIRE-4590"])
        XCTAssertNil(report.warnings[0].details)
        XCTAssertEqual(report.suggestions[0].details, "AllowTcpForwarding (set YES to NO)")
    }

    func testKnockKnockFlagsOnlyMeaningfulUnsignedItems() throws {
        let json = """
        {"Launch Items":[
          {"path":"/Users/me/Library/Application Support/Vendor/daemon","name":"daemon","plist":"/Users/me/Library/LaunchAgents/com.vendor.plist","hashes":"unknown","signature(s)":{"signatureStatus":-67062}},
          {"path":"/usr/sbin/cupsd","name":"cupsd","plist":"/System/Library/LaunchDaemons/org.cups.cupsd.plist","hashes":"unknown","signature(s)":{"signatureStatus":100013}}
        ],
        "Background Managed Tasks":[
          {"path":"/Users/me/Library/Application Support/Vendor/daemon","name":"daemon","plist":"n/a","signature(s)":{"signatureStatus":-67062}},
          {"path":"/Applications/Good.app/Contents/MacOS/Good","name":"Good","plist":"n/a","signature(s)":{"signatureStatus":0,"notarized":true,"signatureAuthorities":["Developer ID Application: Good Inc"]}},
          {"path":"/Applications/Old.app/Contents/MacOS/Old","name":"Old","plist":"n/a","signature(s)":{"signatureStatus":0,"signatureAuthorities":["Developer ID Application: Old Inc"]}},
          {"path":"/Applications/Store.app/Contents/MacOS/Store","name":"Store","plist":"n/a","signature(s)":{"signatureStatus":0,"signatureAuthorities":["Apple Mac OS Application Signing"]}}
        ],
        "Shell Configuration Files":[
          {"path":"/Users/me/.zshrc","name":".zshrc","plist":"n/a","signature(s)":{"signatureStatus":-67062}}
        ]}
        """
        let report = try LaunchItemsReport.parse(Data(json.utf8))
        XCTAssertEqual(report.items.count, 7)
        // The same unsigned daemon registered twice counts once; cupsd and .zshrc aren't flagged.
        XCTAssertEqual(report.flaggedPaths, ["/Users/me/Library/Application Support/Vendor/daemon"])
        XCTAssertEqual(report.items.first { $0.name == "Old" }?.trust, .notNotarized)
        XCTAssertEqual(report.items.first { $0.name == "Store" }?.trust, .trusted)
        XCTAssertEqual(report.items.first { $0.name == "daemon" && $0.category == "Launch Items" }?.plist,
                       "/Users/me/Library/LaunchAgents/com.vendor.plist")
    }

    func testDescriberNamesNodeByWhatItRuns() {
        let home = Paths.home
        let next = ProcessDescriber.describe(
            name: "node",
            arguments: ["node", "\(home)/Sites/shop/node_modules/.bin/next", "dev", "--turbo"],
            cwd: "\(home)/Sites/shop"
        )
        XCTAssertEqual(next.label, "next dev")
        XCTAssertEqual(next.context, "shop")

        let tsserver = ProcessDescriber.describe(
            name: "node",
            arguments: ["node", "--max-old-space-size=3072", "\(home)/Sites/app/node_modules/typescript/lib/tsserver.js", "--useInferredProjectPerProjectRoot"],
            cwd: "/"
        )
        XCTAssertEqual(tsserver.label, "typescript tsserver")
        XCTAssertEqual(tsserver.context, "app")

        let npx = ProcessDescriber.describe(
            name: "node",
            arguments: ["node", "\(home)/.npm/_npx/9f3a/node_modules/@modelcontextprotocol/server-github/dist/index.js"],
            cwd: "\(home)/Sites/pollymetric"
        )
        XCTAssertEqual(npx.label, "server-github")
        XCTAssertEqual(npx.context, "pollymetric") // hidden npx cache isn't a project; fall back to cwd

        let python = ProcessDescriber.describe(name: "python3.12", arguments: ["python3", "-m", "uvicorn", "main:app"], cwd: nil)
        XCTAssertEqual(python.label, "uvicorn main:app")

        let plain = ProcessDescriber.describe(name: "claude", arguments: ["claude"], cwd: "\(home)/Sites/pollymetric")
        XCTAssertEqual(plain.label, "claude")
        XCTAssertEqual(plain.context, "pollymetric")
    }

    func testRelativeTimeHandlesFutureDates() {
        let now = Date()
        XCTAssertEqual(Relative.string(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertTrue(Relative.string(now.addingTimeInterval(6 * 86_400), now: now).hasPrefix("in "))
        XCTAssertTrue(Relative.string(now.addingTimeInterval(-3 * 3_600), now: now).hasSuffix("ago"))
    }

    func testRedactsSecretsFromCommandLines() {
        let redacted = ProcessDescriber.redact(["tool", "--api-key", "sk-123", "TOKEN=abc", "--port", "3000"])
        XCTAssertEqual(redacted, ["tool", "--api-key", "••••", "TOKEN=••••", "--port", "3000"])
        XCTAssertEqual(ProcessDescriber.redact(["curl", "-H", "Authorization: Bearer abc.def.ghi", "-H", "Accept: json"]),
                       ["curl", "-H", "Authorization: ••••", "-H", "Accept: json"])
        XCTAssertEqual(ProcessDescriber.redact(["/usr/local/bin/mysql", "-uroot", "-phunter22", "-P", "3306"]),
                       ["/usr/local/bin/mysql", "-uroot", "-p••••", "-P", "3306"])
        XCTAssertEqual(ProcessDescriber.redact(["psql", "postgres://me:s3cret@db:5432/app"]), ["psql", "postgres://me:••••@db:5432/app"])
        XCTAssertEqual(ProcessDescriber.redact(["git", "clone", "https://x-access-token:ghs_abc@github.com/o/r"]),
                       ["git", "clone", "https://x-access-token:••••@github.com/o/r"])
        XCTAssertEqual(ProcessDescriber.redact(["tool", "--cookie", "sid=1", "run", "sk-ant-api03-abcdefghijklmnopqrstuv"]),
                       ["tool", "--cookie", "••••", "run", "••••"])
        XCTAssertEqual(ProcessDescriber.redact(["node", "server.js", "--port", "3000", "-p", "8080"]),
                       ["node", "server.js", "--port", "3000", "-p", "8080"])
    }
}

final class HealthScoreTests: XCTestCase {
    private func snapshot(cpu: Double, memory: Double = 50, disk: Double = 20, battery: BatteryInfo? = nil,
                          uptime: TimeInterval = 3_600, pressure: MemoryPressure = .normal) -> SystemSnapshot {
        SystemSnapshot(
            date: .now, cpuUsage: cpu, cpuSustained: cpu, memoryUsedPercent: memory, memoryUsedBytes: 0,
            memoryTotalBytes: 0, memoryPressure: pressure, diskUsedPercent: disk, diskFreeBytes: 0,
            diskTotalBytes: 0, diskIOMBps: 0, battery: battery, uptime: uptime
        )
    }

    /// The real reading mole reported on this Mac: `"health_score": 69`, "Good: High CPU".
    func testMatchesMoleOnRecordedSample() {
        let battery = BatteryInfo(percent: 100, isCharging: false, onAC: true, cycleCount: 190, healthPercent: 79)
        let health = HealthScore.compute(snapshot(cpu: 97.98, memory: 69.37, disk: 23.05, battery: battery, uptime: 124_749), sustained: true)
        XCTAssertEqual(health.score, 69)
        XCTAssertEqual(health.band, .good)
        XCTAssertEqual(health.issues, ["High CPU"])
    }

    func testIdleMacIsExcellent() {
        let health = HealthScore.compute(snapshot(cpu: 5), sustained: false)
        XCTAssertEqual(health.score, 100)
        XCTAssertEqual(health.band, .excellent)
        XCTAssertFalse(health.band.wantsAttention)
    }

    func testFullDiskAndPressureNeedAttention() {
        let health = HealthScore.compute(snapshot(cpu: 90, memory: 95, disk: 97, pressure: .critical), sustained: false)
        XCTAssertEqual(health.band, .poor)
        XCTAssertTrue(health.issues.contains("Disk Almost Full"))
        XCTAssertTrue(health.issues.contains("Critical Memory"))
    }
}
