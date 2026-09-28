import XCTest
@testable import Pollymetric

@MainActor
final class UsagePatternsTests: XCTestCase {
    func testRecordingWindowsRankingRetentionAndClear() async throws {
        let root = URL(fileURLWithPath: "/tmp/pm-pattern-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = HistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let now = Date()
        for _ in 0..<9 { db.recordInteraction(.processInspect, target: "|tsup|storefront", context: "/Users/test/Sites/storefront", at: now.addingTimeInterval(-3600)) }
        for _ in 0..<3 { db.recordInteraction(.processInspect, target: "|node|shop", context: "/tmp/shop", at: now.addingTimeInterval(-600)) }
        db.recordInteraction(.processInspect, target: "old", context: nil, at: now.addingTimeInterval(-15 * 86_400))
        db.recordInteraction(.processInspect, target: "expired", context: nil, at: now.addingTimeInterval(-91 * 86_400))
        db.recordInteraction(.toolOpen, target: "btop", context: nil)
        let recent = await db.inspectionPatterns(since: now.addingTimeInterval(-14 * 86_400))
        XCTAssertEqual(recent.map(\.target), ["|tsup|storefront", "|node|shop"])
        XCTAssertEqual(recent.first?.count, 9)
        XCTAssertEqual(recent.first?.title, "tsup in storefront")
        XCTAssertEqual(recent.first?.lastInspected.timeIntervalSince1970 ?? 0, now.addingTimeInterval(-3600).timeIntervalSince1970, accuracy: 0.001)
        let count = await db.interactionCount()
        XCTAssertEqual(count, 14)
        let all = await db.inspectionPatterns(since: .distantPast)
        XCTAssertEqual(all.count, 3)
        await db.clearInteractions()
        let cleared = await db.interactionCount()
        XCTAssertEqual(cleared, 0)
    }

    func testTogglePersistsAndStopsRecordingAndPersonalization() async throws {
        let root = URL(fileURLWithPath: "/tmp/pm-toggle-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = HistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let file = root.appendingPathComponent("preferences.plist")
        let model = UsagePatterns(history: db, preferences: LocalPreferences(file: file))
        XCTAssertTrue(model.enabled)
        for _ in 0..<5 { model.record(.processInspect, target: "|tsup|storefront", context: "/Users/test/Sites/storefront") }
        // Await queued recording refreshes before asserting the latest view.
        try await Task.sleep(for: .milliseconds(30))
        await model.refresh()
        XCTAssertEqual(model.clearPattern?.count, 5)
        model.enabled = false
        model.record(.processInspect, target: "blocked")
        XCTAssertNil(model.clearPattern)
        XCTAssertTrue(model.frequent.isEmpty)
        XCTAssertFalse(UsagePatterns(history: db, preferences: LocalPreferences(file: file)).enabled)
        let count = await db.interactionCount()
        XCTAssertEqual(count, 5)
        await model.clear()
        let cleared = await db.interactionCount()
        XCTAssertEqual(cleared, 0)
    }

    func testRankingChangesOnlyDisplayedCPUTiesAndWeakPatternIsHidden() async throws {
        let root = URL(fileURLWithPath: "/tmp/pm-rank-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = HistoryStore(url: root.appendingPathComponent("history.sqlite"))
        let model = UsagePatterns(history: db, preferences: LocalPreferences(file: root.appendingPathComponent("preferences.plist")))
        let identity = ProcessIdentity(key: "test", pid: 2, startedAt: .now, name: "tsup", label: "tsup", context: "storefront", via: nil, app: nil, appPath: nil, executable: nil, command: "tsup", cwd: "/Users/test/Sites/storefront", chain: [])
        db.recordInteraction(.processInspect, target: identity.groupKey, context: identity.cwd)
        await model.refresh()
        let rows = [ProcessRow(pid: 3, name: "heavy", cpu: 11, memoryBytes: 10),
                    ProcessRow(pid: 4, name: "other", cpu: 10.8, memoryBytes: 10),
                    ProcessRow(pid: 2, name: "tsup", cpu: 10.1, memoryBytes: 10, identity: identity)]
        XCTAssertEqual(model.ranked(rows).map(\.pid), [3, 2, 4])
        XCTAssertNil(model.clearPattern)
        model.enabled = false
        XCTAssertEqual(model.ranked(rows).map(\.pid), [3, 4, 2])
    }
}
