import Foundation

struct CleanPreview: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable, Identifiable {
        var id: String { path }
        var path: String
        var bytes: Int64
    }

    struct Section: Codable, Sendable, Equatable, Identifiable {
        var id: String { name }
        var name: String
        var items: [Item]
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    var totalBytes: Int64
    var itemCount: Int
    var sections: [Section]

    /// Parses `~/.config/mole/clean-list.txt`, which `mo clean --dry-run` writes, plus
    /// the summary line on stdout. Lines marked "counted under <parent>" are children
    /// of an entry already listed and are skipped so sizes aren't double-counted.
    static func parse(list: String, output: String) -> CleanPreview {
        var sections: [Section] = []
        var current: Section?

        for raw in list.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("===") {
                if let current { sections.append(current) }
                current = Section(name: line.trimmingCharacters(in: CharacterSet(charactersIn: "= ")), items: [])
                continue
            }
            guard !line.hasPrefix("#"), !line.contains(", counted under "),
                  let marker = line.range(of: "  # ", options: .backwards),
                  let bytes = Bytes.parse(line[marker.upperBound...])
            else { continue }
            current?.items.append(Item(path: String(line[..<marker.lowerBound]), bytes: bytes))
        }
        if let current { sections.append(current) }

        sections = sections
            .map { Section(name: $0.name, items: $0.items.sorted { $0.bytes > $1.bytes }) }
            .filter { !$0.items.isEmpty }
            .sorted { $0.bytes > $1.bytes }

        let summed = sections.reduce(0) { $0 + $1.bytes }
        let total = output.firstMatch(of: #/Potential space:\s*([0-9.]+\s*[KMGTP]?B)/#).flatMap { Bytes.parse($0.1) }
        let count = output.firstMatch(of: #/Items:\s*([0-9]+)/#).flatMap { Int($0.1) }
        return CleanPreview(
            totalBytes: total ?? summed,
            itemCount: count ?? sections.reduce(0) { $0 + $1.items.count },
            sections: sections
        )
    }
}

struct PurgePreview: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable, Identifiable {
        var id: String { path }
        var path: String
        var bytes: Int64
        /// The project folder, i.e. the parent of node_modules, .next, .venv and so on.
        var project: String { (path as NSString).deletingLastPathComponent }
        var artifact: String { (path as NSString).lastPathComponent }
    }

    var totalBytes: Int64
    var items: [Item]

    /// Parses `mo purge --dry-run` lines such as `✓ [DRY RUN] ~/ai/shop/.next, 52.8MB`.
    static func parse(_ output: String) -> PurgePreview {
        var items: [Item] = []
        for line in output.split(separator: "\n") {
            guard let marker = line.range(of: "[DRY RUN] ") else { continue }
            let rest = line[marker.upperBound...]
            guard let comma = rest.range(of: ", ", options: .backwards),
                  let bytes = Bytes.parse(rest[comma.upperBound...])
            else { continue }
            items.append(Item(path: Paths.expand(String(rest[..<comma.lowerBound])), bytes: bytes))
        }
        items.sort { $0.bytes > $1.bytes }
        let total = output.firstMatch(of: #/Would free approximately:\s*([0-9.]+\s*[KMGTP]?B)/#).flatMap { Bytes.parse($0.1) }
        return PurgePreview(totalBytes: total ?? items.reduce(0) { $0 + $1.bytes }, items: items)
    }
}

struct MoleSession: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(command ?? "")-\(startedAt ?? "")" }
    var command: String?
    var startedAt: String?
    var endedAt: String?
    var items: Int?
    var size: String?
    var operationCount: Int?
    var failedTasks: Int?
    var actions: Actions?

    struct Actions: Codable, Sendable, Equatable {
        var removed: Int?
        var trashed: Int?
        var rebuilt: Int?
    }

    /// Dry runs are logged too, with every operation "skipped". Only count sessions
    /// that actually removed something.
    var didWork: Bool {
        guard let a = actions else { return (items ?? 0) > 0 }
        return (a.removed ?? 0) + (a.trashed ?? 0) + (a.rebuilt ?? 0) > 0
    }
}

enum Mole {
    static let cleanList = URL(fileURLWithPath: Paths.home + "/.config/mole/clean-list.txt")
    static let whitelist = URL(fileURLWithPath: Paths.home + "/.config/mole/whitelist")

    static func cleanPreview() async throws -> CleanPreview {
        let result = try await Shell.run("mo", ["clean", "--dry-run"], background: true, timeout: 1_200)
        let list = (try? String(contentsOf: cleanList, encoding: .utf8)) ?? ""
        return CleanPreview.parse(list: list, output: result.stdout)
    }

    static func purgePreview() async throws -> PurgePreview {
        let result = try await Shell.run("mo", ["purge", "--dry-run"], background: true, timeout: 1_200)
        return PurgePreview.parse(result.stdout)
    }

    static func history() async throws -> [MoleSession] {
        struct Payload: Decodable { var sessions: [MoleSession] }
        let result = try await Shell.run("mo", ["history", "--json"], timeout: 30)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Payload.self, from: Data(result.stdout.utf8)).sessions
    }

    /// Protects a path from future cleans the same way `mo clean --whitelist` does.
    static func protect(_ path: String) throws {
        let existing = (try? String(contentsOf: whitelist, encoding: .utf8)) ?? ""
        guard !existing.split(separator: "\n").contains(where: { $0 == path }) else { return }
        let updated = existing.isEmpty || existing.hasSuffix("\n") ? existing + path + "\n" : existing + "\n" + path + "\n"
        try FileManager.default.createDirectory(at: whitelist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: whitelist, atomically: true, encoding: .utf8)
    }
}
