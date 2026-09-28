import Foundation

/// Everything needed to find, check, sign in to and launch one local agent harness,
/// in a single declarative record. Add a harness by adding a descriptor, either to the
/// built-ins below or to `~/.config/pollymetric/harnesses.json`. There's no code to
/// write and no per-harness switch statements anywhere else.
public struct HarnessDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var vendor: String?
    /// Binary names looked up on your login shell's PATH, first match wins.
    public var executables: [String]
    /// Where accounts live, for harnesses that support several (one config home each).
    public var accounts: Accounts?
    public var auth: Auth?
    /// Opens the harness's own sign-in flow (it opens the browser itself).
    public var login: [String]?
    public var logout: [String]?
    /// Interactive launch. Placeholders: {prompt}, {briefFile}, {briefDir}, {cwd}.
    public var acp: [String]? = nil
    public var launch: [String]
    /// True when `launch` keeps the agent read-only until you approve a plan.
    public var readOnly: Bool?
    /// A named usage reader (see `UsageReaders`), e.g. "claude-cli", "codex-app-server".
    public var usage: String?
    /// An SVG logo: a path (`~` allowed) for your own descriptors. Built-ins ship theirs.
    public var icon: String?
    /// Set in the user file to hide a built-in.
    public var disabled: Bool?

    public struct Accounts: Codable, Hashable, Sendable {
        /// Environment variable that selects the account's config home.
        public var env: String
        /// The home used when the variable is unset, e.g. `~/.claude`.
        public var `default`: String
        /// Extra homes, e.g. `~/.claude-*`. Only the last path component may contain `*`.
        public var glob: String?
    }

    public struct Auth: Codable, Hashable, Sendable {
        /// A status command. It must never start a sign-in flow when you're signed out.
        public var command: [String]?
        /// A credentials file, relative to the account home unless it starts with `/` or `~`.
        public var file: String?
        public var signedIn: Match?
        /// Where to read the signed-in identity (usually an email) from the JSON.
        public var identity: Match?
        /// Where to read the plan name ("max", "pro") from the JSON.
        public var plan: Match?
        /// Also match against stderr (Codex prints its status there). Stderr is only
        /// matched, never kept, since some CLIs print credentials to it.
        public var matchStderr: Bool?
    }

    /// How to read a result. `jsonKey` is a dot path into the JSON output or file.
    public struct Match: Codable, Hashable, Sendable {
        public var jsonKey: String?
        public var contains: String?
        public var exitCode: Int32?
    }
}

extension HarnessDescriptor {
    /// Verified against each CLI's own `--help` and status output. Status checks here
    /// are ones that don't start a login. That's why Cursor Agent has none: its
    /// `status` command begins a sign-in when you're signed out.
    public static let builtIns: [HarnessDescriptor] = {
        let json = #"""
        [
          {
            "id": "claude-code", "name": "Claude Code", "vendor": "Anthropic",
            "executables": ["claude"], "acp": ["claude-agent-acp"],
            "accounts": { "env": "CLAUDE_CONFIG_DIR", "default": "~/.claude", "glob": "~/.claude-*" },
            "auth": { "command": ["claude", "auth", "status"], "signedIn": { "jsonKey": "loggedIn" }, "identity": { "jsonKey": "email" }, "plan": { "jsonKey": "subscriptionType" } },
            "login": ["claude", "auth", "login"], "logout": ["claude", "auth", "logout"],
            "launch": ["claude", "--permission-mode", "plan", "--add-dir", "{briefDir}", "{prompt}"],
            "readOnly": true, "usage": "claude-cli"
          },
          {
            "id": "codex", "name": "Codex", "vendor": "OpenAI",
            "executables": ["codex"], "acp": ["codex-acp"],
            "accounts": { "env": "CODEX_HOME", "default": "~/.codex", "glob": "~/.codex-*" },
            "auth": { "command": ["codex", "login", "status"], "signedIn": { "contains": "Logged in" }, "matchStderr": true },
            "login": ["codex", "login"], "logout": ["codex", "logout"],
            "launch": ["codex", "--sandbox", "read-only", "--ask-for-approval", "on-request", "--add-dir", "{briefDir}", "{prompt}"],
            "readOnly": true, "usage": "codex-app-server"
          },
          {
            "id": "opencode", "name": "OpenCode", "vendor": "SST",
            "executables": ["opencode"],
            "auth": { "file": "~/.local/share/opencode/auth.json" },
            "login": ["opencode", "auth", "login"], "logout": ["opencode", "auth", "logout"],
            "launch": ["opencode", "--agent", "plan", "--prompt", "{prompt}"],
            "readOnly": true
          },
          {
            "id": "grok", "name": "Grok", "vendor": "xAI",
            "executables": ["grok"],
            "accounts": { "env": "GROK_HOME", "default": "~/.grok", "glob": "~/.grok-*" },
            "auth": { "file": "auth.json" },
            "login": ["grok", "login", "--oauth"], "logout": ["grok", "logout"],
            "launch": ["grok", "--permission-mode", "plan", "{prompt}"],
            "readOnly": true
          },
          {
            "id": "cursor-agent", "name": "Cursor Agent", "vendor": "Cursor",
            "executables": ["cursor-agent"],
            "login": ["cursor-agent", "login"], "logout": ["cursor-agent", "logout"],
            "launch": ["cursor-agent", "--plan", "{prompt}"],
            "readOnly": true
          }
        ]
        """#
        // A malformed built-in is a programming error; fail loudly in development.
        return try! JSONDecoder().decode([HarnessDescriptor].self, from: Data(json.utf8))
    }()
}
