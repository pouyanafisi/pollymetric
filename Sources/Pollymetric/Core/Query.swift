import Foundation
import Observation

/// A small, native take on TanStack Query's model: stale-while-revalidate.
///
/// - The last result is persisted to disk, so the UI renders instantly on launch with
///   the previous value and its age, then refreshes in the background if it's stale.
/// - Concurrent `refresh()` calls share one in-flight fetch (request deduplication).
/// - Nothing polls. Refreshes happen when you look (`refreshIfStale`) or when an
///   event says the data changed (`refresh`), such as a launch-agent folder changing.
@MainActor
@Observable
final class Query<Value: Codable & Sendable> {
    let key: String
    let staleAfter: TimeInterval

    private(set) var value: Value?
    private(set) var updatedAt: Date?
    private(set) var isFetching = false
    private(set) var fetchStartedAt: Date?
    private(set) var error: String?

    @ObservationIgnored private let fetcher: @Sendable () async throws -> Value
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    init(
        key: String,
        staleAfter: TimeInterval,
        persists: Bool = true,
        fetcher: @escaping @Sendable () async throws -> Value
    ) {
        self.key = key
        self.staleAfter = staleAfter
        self.persists = persists
        self.fetcher = fetcher
        if persists, let cached = QueryDiskCache.load(Value.self, key: key) {
            value = cached.value
            updatedAt = cached.updatedAt
        }
    }

    /// Screenshots only: show a known value without fetching.
    func seed(_ value: Value) {
        self.value = value
        updatedAt = .now
    }

    var isStale: Bool {
        guard let updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > staleAfter
    }

    func refreshIfStale() {
        if isStale { refresh() }
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        isFetching = true
        fetchStartedAt = .now
        let fetcher = fetcher
        let task = Task { [weak self] in
            do {
                let fresh = try await fetcher()
                guard let self else { return }
                let now = Date()
                self.value = fresh
                self.updatedAt = now
                self.error = nil
                if self.persists { QueryDiskCache.save(fresh, key: self.key, updatedAt: now) }
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isFetching = false
            self?.fetchStartedAt = nil
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }
}

/// Runs heavy scans one at a time, so opening the panel never triggers three
/// full-disk scans in parallel.
actor SerialGate {
    static let heavy = SerialGate()
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

enum QueryDiskCache {
    private struct Envelope<Value: Codable>: Codable {
        var updatedAt: Date
        var value: Value
    }

    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = DataDirectory.override()?.appendingPathComponent("cache", isDirectory: true)
            ?? base.appendingPathComponent("com.pouyanafisi.pollymetric", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let queue = DispatchQueue(label: "pollymetric.cache", qos: .utility)

    static func load<Value: Codable>(_ type: Value.Type, key: String) -> (value: Value, updatedAt: Date)? {
        guard let data = try? Data(contentsOf: url(key)),
              let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data)
        else { return nil }
        return (envelope.value, envelope.updatedAt)
    }

    static func save<Value: Codable & Sendable>(_ value: Value, key: String, updatedAt: Date) {
        queue.async {
            guard let data = try? JSONEncoder().encode(Envelope(updatedAt: updatedAt, value: value)) else { return }
            try? data.write(to: url(key), options: .atomic)
        }
    }

    private static func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }
}
