<p align="center">
  <img src="design/logo.svg" width="84" alt="Pollymetric">
</p>

<h1 align="center">Pollymetric</h1>

<p align="center"><strong>Is your Mac OK, and is there anything you should do?</strong><br>
One glance at your menu bar tells you.</p>

<p align="center">
  <a href="https://github.com/pouyanafisi/pollymetric/releases/latest"><img src="https://img.shields.io/github/v/release/pouyanafisi/pollymetric?label=download&color=2ea44f" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon%20%26%20Intel-lightgrey?logo=apple" alt="macOS 14 or later, Apple silicon and Intel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  <a href="https://github.com/pouyanafisi/pollymetric/actions/workflows/tests.yml"><img src="https://github.com/pouyanafisi/pollymetric/actions/workflows/tests.yml/badge.svg" alt="Tests"></a>
</p>

<p align="center">
  <img src="docs/screenshots/menu-bar-panel.png" width="380" alt="The Pollymetric panel: a health score, anything that needs you, and what's using your Mac">
</p>

## What it does for you

**Know at a glance whether your Mac is OK.**
A score in your menu bar, and one line saying why it isn't perfect. It stays quietly gray while all
is well and only turns amber or red when something needs you.

**See what's actually slowing it down.**
Not "node" or a wall of cryptic process names: *"next dev in storefront, started by Claude Code in
iTerm2."* Everything is grouped by the app that started it, so you know what to close.

**Catch the problem that keeps coming back.**
Pollymetric remembers the last two weeks. Something that spikes for twenty seconds and vanishes is
still on the record, and anything that keeps flaring up gets flagged, with how often and how much.

<p align="center">
  <img src="docs/screenshots/processes.png" width="860" alt="Processes: a day of CPU history, what you check most, and a process that keeps flaring up">
</p>

**Get it explained, and fixed.**
Click **Explain** or **Find a Fix** on anything that's misbehaving. Your AI agent (Claude Code,
Codex and others) gets the full story, investigates, and tells you what's going on and how to fix it,
right beside the process. It can't change anything without your okay.

<p align="center">
  <img src="docs/screenshots/explain.png" width="860" alt="An agent explaining why a build watcher keeps using CPU, with the fix">
</p>

**Free up space safely.**
See how much space caches and old projects are holding, exactly what would go, and get it back in one
click. Nothing is removed until you confirm.

**Spot what sneaks into startup.**
See everything that starts by itself when you log in, with anything from an unknown developer
flagged.

**Know how secure your Mac is.**
One click checks how well your Mac is protected and lists what to tighten, most important first.

**Let your AI agents check on your Mac too.**
Connect an agent and it can ask Pollymetric how your Mac is doing. You approve each agent with
Touch ID, see what it has looked at, and can revoke it any time. Anything that would change your
Mac asks you first, every time.

**Keep every answer.**
Every question you've asked an agent about your Mac is saved, so the fix you found last week is one
click away.

## Private by design

Everything Pollymetric records stays on your Mac. There's no account, no cloud and no tracking. It
uses almost no battery or CPU while it watches.

## Install

1. [**Download Pollymetric.dmg**](https://github.com/pouyanafisi/pollymetric/releases/latest/download/Pollymetric.dmg) (or browse [all releases](https://github.com/pouyanafisi/pollymetric/releases)).
2. Open it and drag Pollymetric into **Applications**.
3. Open Pollymetric. A short setup gets it running the way you want: start at login, the one
   permission that lets it check your whole Mac, the extra cleanup and security tools (installed for
   you), and any AI agents it found.

<p align="center">
  <img src="docs/screenshots/setup.png" width="440" alt="The setup window">
</p>

Works on macOS 14 Sonoma or later, on Apple silicon and Intel Macs.

To remove it: **Settings → General → Uninstall**, with the option to delete everything it recorded.

---

Building Pollymetric yourself? See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
