import Foundation

enum DataDirectory {
    static var isSnapshot: Bool { CommandLine.arguments.contains("--snapshot") }
    static let preferences = LocalPreferences()
    static func override(in environment: [String: String]) -> URL? {
        guard let path = environment["POLLYMETRIC_DATA_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The data folder to use instead of the real one, if any. Tests always get a
    /// throwaway folder even when nobody set POLLYMETRIC_DATA_DIR: a plain `swift test`
    /// once wrote a stub process into the owner's real history database.
    static func override() -> URL? {
        override(in: ProcessInfo.processInfo.environment) ?? (isRunningTests ? testDirectory : nil)
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.processName == "xctest" || NSClassFromString("XCTestCase") != nil
    }

    private static let testDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pollymetric-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// Tests and snapshots keep preferences in their data folder too.
final class LocalPreferences {
    private var values: [String: Any] = [:]
    private let file: URL?
    init(file: URL? = DataDirectory.override()?.appendingPathComponent("preferences.plist")) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { values = decoded }
    }
    func string(forKey key: String) -> String? { file == nil ? UserDefaults.standard.string(forKey: key) : values[key] as? String }
    func object(forKey key: String) -> Any? { file == nil ? UserDefaults.standard.object(forKey: key) : values[key] }
    func set(_ value: Any, forKey key: String) {
        guard let file else { UserDefaults.standard.set(value, forKey: key); return }
        values[key] = value
        if let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) { try? data.write(to: file, options: .atomic) }
    }
}
