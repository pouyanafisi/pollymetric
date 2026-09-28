import Foundation

/// Built-in descriptors merged with your own. A user descriptor with the same `id`
/// replaces the built-in entirely, which keeps the rules simple; new ids are added after
/// the built-ins. `"disabled": true` hides a harness.
public enum HarnessRegistry {
    public static let userFile = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/pollymetric/harnesses.json")

    public struct Loaded: Sendable {
        public var descriptors: [HarnessDescriptor]
        /// Set when the user file exists but couldn't be read; built-ins still load.
        public var userFileError: String?
    }

    public static func load(userFile url: URL = userFile) -> Loaded {
        var byID = Dictionary(uniqueKeysWithValues: HarnessDescriptor.builtIns.map { ($0.id, $0) })
        var order = HarnessDescriptor.builtIns.map(\.id)
        var problem: String?

        if let data = try? Data(contentsOf: url) {
            do {
                for descriptor in try JSONDecoder().decode([HarnessDescriptor].self, from: data) {
                    if byID[descriptor.id] == nil { order.append(descriptor.id) }
                    byID[descriptor.id] = descriptor
                }
            } catch {
                problem = "\(url.path): \(error.localizedDescription)"
            }
        }
        let descriptors = order.compactMap { byID[$0] }.filter { $0.disabled != true }
        return Loaded(descriptors: descriptors, userFileError: problem)
    }

    /// Writes a starter file, if none exists yet, with one example shaped like a real
    /// entry. It's disabled: Gemini CLI wasn't installed to verify its flags against, so
    /// check them with `gemini --help` before enabling it.
    public static func createUserFileIfMissing(at url: URL = userFile) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let example = #"""
        [
          {
            "id": "gemini",
            "name": "Gemini CLI",
            "vendor": "Google",
            "executables": ["gemini"],
            "auth": { "file": "~/.gemini/oauth_creds.json" },
            "login": ["gemini"],
            "launch": ["gemini", "--approval-mode", "plan", "--prompt-interactive", "{prompt}"],
            "readOnly": true,
            "disabled": true
          }
        ]
        """#
        try example.write(to: url, atomically: true, encoding: .utf8)
    }
}
