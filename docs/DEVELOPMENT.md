# Pollymetric: development notes

How Pollymetric works, how to build and release it, and the decisions behind it. For what it does
for you, see the [README](../README.md).

A macOS menu bar app that answers one question at a glance, "is my Mac OK, and is there anything I
should do?" The health score, process history and agent pane are built in. Cleanup, launch items, the
security audit and the terminal shortcuts use these open-source tools. The first-run setup checks for
them and installs any that are missing with one click through Homebrew (if Homebrew itself is
missing, it links to brew.sh):

| Tool | What Pollymetric uses it for |
| --- | --- |
| [mole](https://github.com/tw93/Mole) (`mo`) | Cache cleanup preview and run, build-folder purge, cleanup history. Its health score formula is ported natively. |
| [KnockKnock](https://objective-see.org/products/knockknock.html) | Everything set to launch itself, with unsigned items flagged |
| [Lynis](https://cisofy.com/lynis/) | Security audit: hardening index, warnings, suggestions |
| [btop](https://github.com/aristocratsoftware/btop), [dua](https://github.com/Byron/dua-cli), [kondo](https://github.com/tbillington/kondo) | Deeper interactive work, opened in a new iTerm2 tab |

## What you see

**Menu bar:** an ECG glyph and a 0–100 health score. It stays monochrome while things are fine and
turns amber (Fair) or red (Needs attention) only when something needs you.

**Panel (click the icon):**
1. Score ring and one line saying why it isn't 100 ("High CPU — node")
2. **Needs attention:** only things you can act on, ranked by severity, each with one button
3. CPU, memory, disk and battery tiles
4. Top processes, named by what they're doing ("next dev · shop · claude › iTerm2", not "node").
   Click one for its full story.
5. Tool launchers, and the dashboard

**Dashboard (⌘D from the panel):** Overview, Processes, Caches, Build Folders, Launch Items,
Security Audit, History. Destructive actions always show exactly what will be removed and ask for
confirmation first.

## Agent activity

Three pages under **Agent Activity**, plus local-model naming, cover what agents leave behind.

- **Local Servers** (`Footprint/LocalServers.swift`): listening TCP sockets read natively with libproc
  (`PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`, `TSI_S_LISTEN`), deduped across IPv4/IPv6 and forked
  workers, attributed with the same `IdentityResolver` as Processes. Wildcard or non-loopback binds are
  "open to your network". When a server's live parent chain has no agent (the agent quit and it was
  re-parented to launchd), its recorded identity for the same pid + start time is looked up in history
  (`HistoryStore.chains(forKeys:)`) and it's flagged "Left running". To make that possible the sampler
  records every process an agent started once, when first seen, even when idle.
- **Worktrees** (`Footprint/Worktrees.swift`): discovery reads git's own files (`.git/worktrees/*`,
  `.git` files with `gitdir:`), never runs git to find them, across `ProjectFolders.roots` and known agent
  locations (`<repo>/.claude/worktrees`, `<repo>/.worktrees`, `~/.codex/worktrees`, …). Sizes come from
  `fts` under `SerialGate.heavy`. "Unsaved changes" and removal use `git` through the disclaimed launcher
  with `-c trace2.eventTarget=0 -c core.fsmonitor=false`; removal is `git worktree remove` (forced only
  after a second confirmation), stale entries use `git worktree prune`.
- **Plugins & Skills** (`Footprint/AgentExtensions.swift`): read-only parsing of each agent's MCP and
  skill configs (Claude Code incl. extra accounts, Codex TOML via a small subset parser, Cursor, Claude
  Desktop, OpenCode, VS Code, Windsurf). Command lines are redacted, only env var *names* are kept, and
  values are looked at only long enough to flag a plain-text key. Not exposed over MCP.
- **Local models** (`System/LocalModels.swift`): Ollama runners are named from Ollama's manifests (the
  weights blob digest → `model:tag`); llama.cpp, LM Studio, MLX and vLLM from the model they loaded.

Agent leftovers lead "Needs attention": servers left running, keys stored in plain text, and unused
worktrees holding 5 GB or more.

## Process history

Things like a `node` that pins the CPU for 20 seconds and disappears are hard to diagnose after the
fact, so Pollymetric keeps a local record in SQLite (`~/Library/Application Support/Pollymetric/history.sqlite`):

- **Attribution.** For each busy process Pollymetric reads its arguments, working directory and parent
  chain once, and names it by what it runs: `next dev` in `shop`, started by `claude` in iTerm2;
  `typescript tsserver` under Visual Studio Code; an MCP server under the agent that launched it.
  Versioned binaries (`…/claude/versions/2.1.283`) and iTerm2's out-of-bundle `iTermServer` are
  resolved to their real names. Secret-looking arguments are masked before anything is stored.
- **What's kept:** processes above 20% CPU (every 10 s) or 2 GB of memory (every minute), and one
  system sample per minute. Restarts of the same thing share a group, so history accumulates across
  PIDs. 14-day retention.
- **Dashboard → Processes:** system CPU over 1 h / 24 h / 7 d, usage grouped by app, and an inspector
  per group with a plain-English explanation, CPU history, recent runs (command, folder, parent
  chain) and actions.
- **Needs attention** adds a single "keeps spiking" item only when something flared above 50% CPU in
  4 or more separate 15-minute windows in the last day.

Process sampling uses libproc (`proc_pid_rusage`), about 4 ms for ~1,500 processes with no
subprocess. Root-owned processes aren't visible to libproc, so when system CPU exceeds what your
own processes explain by a full core, Pollymetric asks `ps` once so Spotlight or WindowServer still shows up.

## Agents (HarnessKit)

The process inspector’s **Explain** and **Find a Fix** buttons open a conversation beside the process
for Claude Code and Codex, using their ACP adapters (`claude-agent-acp` and `codex-acp`). The
selected account is preserved. OpenCode (`opencode acp` advertises no read-only mode), Grok and
Cursor use the iTerm2 handoff.

## Agent pane

The pane streams answers, a collapsed Thinking disclosure, tool progress and a plan checklist. It
starts only in a read-only mode (`ask`, `plan` or Codex’s `read-only`); an adapter without one is
refused and offered the iTerm2 handoff instead. Claude sessions load only the user’s own settings,
never the inspected project’s `.claude/` settings or hooks. Tool permission requests appear inline
with one-time options only (“Always allow” is dropped, “Don’t allow” comes first); Pollymetric never
approves one automatically. Links in answers open only if they are web URLs. Process names, command
lines and paths in briefs are flattened to one line, fenced, and labelled as untrusted data. Stop and close cancel
outstanding requests. Follow-up questions stay in the session. Saved answers and transcripts live
in SQLite and reopen read-only under **Agent answers** in the process inspector.

**Continue in iTerm** starts the existing terminal handoff with the original process brief; it does
not migrate the ACP session. Briefs live under the Pollymetric data folder. Adapter stderr is discarded,
the environment is scrubbed, and no client filesystem or terminal capabilities are advertised.
Claude sessions also disable inherited MCP servers. Enforcement of native agent tool permissions
still depends on the adapter; live adapter behavior needs owner verification.

Harnesses come from **HarnessKit** (`Sources/HarnessKit`, a library product usable on its own), which
works from one declarative descriptor per harness:

```json
{
  "id": "claude-code", "name": "Claude Code", "vendor": "Anthropic",
  "executables": ["claude"],
  "accounts": { "env": "CLAUDE_CONFIG_DIR", "default": "~/.claude", "glob": "~/.claude-*" },
  "auth": { "command": ["claude", "auth", "status"], "signedIn": { "jsonKey": "loggedIn" }, "identity": { "jsonKey": "email" } },
  "login": ["claude", "auth", "login"], "logout": ["claude", "auth", "logout"],
  "launch": ["claude", "--permission-mode", "plan", "--add-dir", "{briefDir}", "{prompt}"],
  "acp": ["claude-agent-acp"],
  "readOnly": true
}
```

- **Built in:** Claude Code, Codex, OpenCode, Grok and Cursor Agent, with every flag checked against
  the CLI's own `--help`.
- **Add or override** harnesses in `~/.config/pollymetric/harnesses.json` (Dashboard → Agents →
  Open harnesses.json). A matching `id` replaces a built-in; `"disabled": true` hides one.
- **Launch placeholders:** `{prompt}`, `{briefFile}`, `{briefDir}`, `{cwd}`.
- **Accounts:** every config home is found (`~/.claude`, `~/.claude-work`, …) and selected through
  its environment variable. The default account runs with that variable explicitly unset.
- **Sign-in state:** checked by reading a credentials file, or by a status command that must never
  start a login. `cursor-agent status` does start one when you're signed out, so Cursor's state shows
  as unknown. Some CLIs write status to stderr (Codex does); `"matchStderr": true` matches against it
  without keeping it.
- **Sign in and out:** the harness’s command runs headlessly with stdin closed and output discarded.
  The account row asks you to finish in your browser while Pollymetric rechecks status for up to five
  minutes. The account’s ⋯ menu retains terminal fallbacks for CLIs that need interactive input.
- **Environment:** GUI apps don't get your shell's PATH, so HarnessKit asks your login shell once.
  Status probes run with only HOME, USER, LOGNAME and PATH, no stdin, and a timeout.
- **Usage** (Dashboard → Agents): Claude accounts are read by running Claude Code's own `/usage`
  (`claude -p /usage`, a local command: no model turn, no cost). Claude Code reads its own
  credentials, so Pollymetric never touches the keychain or a token and there are no prompts. Codex
  accounts are read through `codex app-server`'s `account/rateLimits/read`. Both are read on demand
  and cached for five minutes. `Pollymetric --usage <harness-id>` prints them.
- `Pollymetric --harnesses` prints what's detected, then quits.

## Footprint

- Menu bar readings come straight from the kernel (Mach host statistics, sysctl, statfs, IOKit).
  A sample costs well under a millisecond. `mo status --json` takes about 8 s of CPU per snapshot,
  so Pollymetric never shells out for the menu bar.
- Sampling runs every 10 s while closed, with timer tolerance so macOS can batch the wakeups, and
  every 2 s while you're looking.
- Heavy scans (`mo clean --dry-run`, `mo purge --dry-run`, the KnockKnock scan) use a small
  stale-while-revalidate cache (`Core/Query.swift`, the TanStack Query model in native Swift):
  results persist to disk, requests are deduplicated, scans run one at a time under
  `taskpolicy -c utility` (below your apps, throttled I/O), and a scan only runs when you open the
  panel and the cached result has gone stale. The footer names the running scan and how long it's
  been going; click it to see that page. (The stricter `-b` background clamp starved scans
  completely on a busy Mac.)
- Event-driven where possible: kqueue watchers on the LaunchAgents/LaunchDaemons folders trigger a
  launch-item rescan when something installs itself.
- Measured cost (release build, this Mac): about 0.4% of one core with the menu closed and no window
  open, and about 3% with the dashboard open. Metrics update every 2 seconds **without animation**:
  animating them re-laid out the whole window at the display's refresh rate for half a second
  on every tick, which cost 24% with the dashboard open. Streamed agent text is applied in batches
  (about 12 times a second) instead of per chunk, and parsed Markdown is cached.
  `Pollymetric --open-dashboard` opens the dashboard on launch for measuring this.

## Install

Open `Pollymetric-<version>.dmg` and drag Pollymetric into Applications. On first launch:

- **Move to Applications:** if it's opened from the disk image or Downloads (including macOS's
  randomized "App Translocation" path for downloaded apps), it offers to move itself into
  Applications, relaunches from there and ejects the disk image.
- **Setup window:** start at login, Full Disk Access (the step turns green by itself when granted),
  the command-line tools with a one-click Homebrew install for any that are missing, and which AI
  agents were found. Everything is optional; reopen it any time from Settings → General.
- **Uninstall:** Settings → General → Uninstall removes the login item, optionally deletes history
  and settings, and moves the app to the Trash.

## Build, install and release

```sh
scripts/build-app.sh          # dev: build, sign, install to /Applications, relaunch
scripts/release.sh            # universal DMG, Developer ID signed + notarized + stapled
scripts/release.sh --local    # universal DMG signed with Pollymetric Local (this Mac only)
swift test
```

`scripts/assemble-app.sh` builds and signs the bundle for both. It signs with
`POLLYMETRIC_SIGN_IDENTITY`, else a **Developer ID Application** certificate when one is in the
keychain, else the local identity in `.sign-identity`. It uses the hardened runtime and
`Support/Pollymetric.entitlements` (Apple events, for opening tools in iTerm2). Version:
`VERSION`. Build number: the git commit count.

A distributable release needs, once per Mac:

1. **Developer ID Application certificate:** Xcode → Settings → Accounts → (your team) → Manage
   Certificates → + → Developer ID Application.
2. **Notarization credentials** saved as a keychain profile named `pollymetric`:
   `xcrun notarytool store-credentials pollymetric --apple-id <Apple ID> --team-id <Team ID>`
   (it asks for an app-specific password from account.apple.com).

`release.sh` then notarizes and staples the app, builds the DMG with `dmgbuild` (hash-locked in
`Support/dmgbuild-requirements.txt` and installed into a fresh venv; window layout in
`Support/dmg-settings.py`, artwork drawn by `Pollymetric --make-dmg-background`), signs, notarizes
and staples the DMG, and checks it with `spctl`. Without a Developer ID it refuses unless you pass
`--local`, so a build that other Macs would block is never mistaken for a release.

Switching signing identity (Pollymetric Local → Developer ID) means granting Full Disk Access and
Automation once more, because macOS ties those permissions to the signature.

`Pollymetric --snapshot <dir>` renders the panel and every dashboard page (light and dark) plus captures
of its own real windows (including the setup window) to PNGs, then quits.

## Permissions

- **Full Disk Access (one switch):** System Settings → Privacy & Security → Full Disk Access →
  Pollymetric, then reopen Pollymetric. The mole and KnockKnock scans read Downloads, iCloud Drive, project
  folders and so on, and macOS attributes a child process's access to the app that launched it.
  Without Full Disk Access you get a prompt per folder, so Pollymetric doesn't run automatic scans until
  it's on, and shows a "Give Pollymetric Full Disk Access" item with a button to that settings pane.
- **Automation → iTerm2:** asked once, the first time you open a tool.
- **Stable signing:** macOS ties these grants to the code signature, and ad-hoc signatures change on
  every build. `scripts/build-app.sh` signs with `POLLYMETRIC_SIGN_IDENTITY` or the identity hash in
  `.sign-identity` (not committed). On this Mac that's a self-signed **Pollymetric Local** code-signing
  certificate in the login keychain. It needs no trust setting; the designated requirement pins its
  leaf hash, so grants survive rebuilds.

`Pollymetric --snapshot <dir>` renders the panel and every dashboard page (light and dark) plus captures
of its own real windows to PNGs, then quits. It's useful for checking UI changes without Screen
Recording permission.

## Full Disk Access and child processes

macOS attributes a child process's file access to the app that launched it, so a normal child of
Pollymetric inherits its Full Disk Access. Anything that runs code you (or software running as you)
can edit is therefore launched *disclaimed* (`ChildProcess` in HarnessKit, via
`responsibility_spawnattrs_setdisclaim`, as terminals and editors do): agent adapters, sign-in,
status and usage probes, the login-shell PATH lookup, and Homebrew installs. They get only the
access they'd have if you ran them yourself. If a Mac can't disclaim, those launches fail rather
than fall back.

Mole and KnockKnock scans keep Pollymetric's access: seeing caches and startup items across the
whole Mac is what it's granted for. They come from Homebrew, so those scans trust that installation.

## Security audit

Lynis needs root. **Audit** uses macOS’s native administrator prompt and shows “Running security
audit…” while it runs. As root, Lynis writes only into a fresh root-owned temp folder; the report
comes back on stdout, the folder is removed, and the app saves the report into its data folder.
Nothing running as root writes to a path you can write to. The app itself does not run as root.
Lynis itself comes from Homebrew, which your user account can modify, so the audit trusts that
installation.

## MCP and Connections

Dashboard → Settings → **Connections** pairs each agent explicitly. Choose a name and `read` (the
default) or `read+act`, then confirm with macOS LocalAuthentication using Touch ID or the system’s
password fallback. The random token is shown once with copyable Claude Code, Codex and generic JSON
configuration. Only its SHA-256 hash is stored in SQLite; keep the raw token in the agent’s environment
as `POLLYMETRIC_MCP_TOKEN`. Copying the configuration keeps it on this Mac (no Universal Clipboard) and
marks it concealed for clipboard managers.

Pairing keeps agents from connecting by accident. It is not a boundary against software already
running as you, which can edit the database directly; the per-action Touch ID confirmation is what
guards anything that changes your Mac. Before a valid token, a connection gets one line of at most
2 KB within 10 seconds.

`Pollymetric --mcp` is a stdio MCP relay to the running app over `<data dir>/mcp.sock`, an owner-only
Unix socket (0600). Nothing listens on a network port. The app must already be running. Unknown and
revoked tokens are rejected, including requests on already-open connections. Launching `--mcp` does
not open the UI or perform agent detection.

Read tools expose health and issues, attention items, attributed top processes, 24-hour process
history, investigation briefs, cached agent usage, cleanup previews, flagged launch items and the
latest loaded Lynis report. Cached results include their measurement time and staleness; these tools
do not trigger a fresh scan, sign-in or usage probe.

Action tools request process quit, Mole cache cleanup or build-folder purge. Each requires `read+act`,
a separate in-app confirmation with Touch ID, and an unrevoked connection at execution. Each agent
can have one request open at a time, and the window comes forward only for the first. Requests
expire as denied after 60 seconds. Quit requests include the process lifetime key to guard against
PID reuse. Cleanup and purge start the existing app jobs; their result means “started,” with progress
in Pollymetric. Mole’s current rules determine the affected files; previews are estimates.

Connections lists scope, creation time, last use, lifetime call count and the last 30 days of calls
(up to 200 recent calls across clients). **Revoke** asks for confirmation and invalidates the token.
No server registration or real agent configuration is changed by Pollymetric.

The implementation uses [ACP v1](https://agentclientprotocol.com/protocol/v1/initialization) and
[MCP stdio](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports). MCP negotiates
2025-06-18, 2025-03-26 or 2024-11-05; no third-party Swift dependency is required.

## Usage patterns

Pollymetric counts local interactions: panel opens, section views, process inspections, agent asks,
quits, cleanups, purges, tool opens and MCP calls. It stores event time, kind, target and the project
folder when known, with 90-day retention. There is no model or network analytics.

- Processes shows up to four **You check these most** links from inspections in the last 14 days.
- Overview shows at most one weekly pattern, after at least five inspections and when its count is
  at least twice the runner-up’s count. Clicking it opens that process.
- The panel breaks ties in displayed integer CPU percentages using inspection counts, preserving
  the existing order when counts tie.

The panel’s ⋯ menu has **Learn from how I use Pollymetric**, on by default. Turning it off stops
recording and hides personalization. **Clear usage patterns** deletes interaction rows; process
history, conversations and connection audit logs are separate.

## Isolated development checks

Set `POLLYMETRIC_DATA_DIR` to a fresh temporary directory for tests and snapshots. This redirects
SQLite, briefs, Lynis reports, query caches and preferences; the normal data location stays unchanged.

```sh
export POLLYMETRIC_DATA_DIR="$(mktemp -d /tmp/pollymetric-test.XXXXXX)"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swift build --disable-sandbox
swift test --disable-sandbox
.build/debug/Pollymetric --snapshot /tmp/pollymetric-snapshots
```

Tests use a stub ACP adapter and temporary paired clients. The socket test needs permission to bind a
local Unix socket. With an overridden data folder, snapshot mode adds synthetic conversation,
connection and inspection fixtures, while real harness detection, usage probes and MCP serving are
disabled. It still samples local system/process metrics. No real agent sessions, sign-ins, Lynis
administrator prompts or Touch ID prompts are exercised by these checks.

## Layout

```
Sources/Pollymetric/
  App/           AppKit shell: status item, panel, dashboard window
  Core/          Shell runner, Query cache, formatting, file watchers, iTerm2 launcher
  System/        Native sampler, ported health score, process list
  Integrations/  mole, KnockKnock, Lynis parsers and commands
  Model/         AppStore, the Needs-attention rules, tools
  UI/            Panel and dashboard views
```
