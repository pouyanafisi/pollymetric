<p align="center">
  <img src="design/logo.svg" width="84" alt="Pollymetric">
</p>

<h1 align="center">Pollymetric</h1>

<p align="center"><strong>See what your AI agents are doing to your Mac.</strong><br>
What's running, who started it, what it's costing you, and what got left behind. Right in your menu bar.</p>

<p align="center">
  <a href="https://github.com/pouyanafisi/pollymetric/releases/latest"><img src="https://img.shields.io/github/v/release/pouyanafisi/pollymetric?label=download&color=2ea44f" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon%20%26%20Intel-lightgrey?logo=apple" alt="macOS 14 or later, Apple silicon and Intel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  <a href="https://github.com/pouyanafisi/pollymetric/actions/workflows/tests.yml"><img src="https://github.com/pouyanafisi/pollymetric/actions/workflows/tests.yml/badge.svg" alt="Tests"></a>
</p>

<p align="center">
  <a href="https://pollymetric.com"><strong>pollymetric.com</strong></a>
</p>

<p align="center">
  <img src="docs/screenshots/menu-bar-panel.png" width="380" alt="The Pollymetric panel: a server left running by an agent, a key stored in plain text, and space held by unused worktrees">
</p>

## Why it exists

AI agents now do real work on your Mac: they start dev servers and watchers, make a fresh copy of your
project for each task, load local models and install plugins. They rarely clean up after themselves,
and your Mac pays for it in battery, memory and disk. None of it is labelled. Your Mac just says
"node".

Pollymetric shows you what's going on, and what got left behind.

## What it does for you

**Find the servers nobody stopped.**
Every server running on your Mac, which agent or app started it, how long it's been up, and whether
other machines on your network can reach it. When the agent that started one has quit, Pollymetric
remembers who it was and flags it as left running.

<p align="center">
  <img src="docs/screenshots/local-servers.png" width="860" alt="Local Servers: what's listening, who started it, and a dev server left running after Claude Code quit">
</p>

**Get your disk back from forgotten project copies.**
Agents make a copy of your project for each task, each with its own dependencies and builds. See
every copy, how much space it holds, when it was last touched and which agent made it, and remove the
ones you don't need. Your branches stay, and anything unsaved gets a clear warning first.

<p align="center">
  <img src="docs/screenshots/worktrees.png" width="860" alt="Worktrees: extra copies of projects that agents created, and the space they hold">
</p>

**Know what your agents have been given.**
The plugins and skills each agent can use, what each one runs, and anything worth a second look: tools
that run whatever a registry serves that day, and keys stored in plain text.

<p align="center">
  <img src="docs/screenshots/plugins-and-skills.png" width="860" alt="Plugins and Skills: what each agent can use, with anything worth a look flagged">
</p>

**See what's really using your memory.**
A local model holding gigabytes shows up by the model it has loaded, not "ollama". Every process is
named by what it is and who started it: *"next dev in storefront, started by Claude Code in iTerm2."*

**Catch the problem that keeps coming back.**
Pollymetric remembers the last two weeks. Something that spikes for twenty seconds and vanishes is
still on the record, and anything that keeps flaring up gets flagged, with how often and how much.

<p align="center">
  <img src="docs/screenshots/processes.png" width="860" alt="Processes: a day of CPU history, what you check most, and a process that keeps flaring up">
</p>

**Let an agent help clean up after agents.**
Click **Explain** or **Find a Fix** and your own AI agent (Claude Code, Codex and others) investigates
right beside the process and tells you what's going on and how to fix it. It can't change anything
without your okay, one step at a time. You don't need an agent for anything else.

<p align="center">
  <img src="docs/screenshots/explain.png" width="860" alt="An agent explaining why a build watcher keeps using CPU, with the fix">
</p>

**Everyday upkeep, too.**
Free up space from caches and old build folders, see everything that starts when you log in (with
unknown developers flagged), and check how well your Mac is protected. Nothing is removed until you
confirm.

**Let your agents check in, on your terms.**
Connect an agent and it can ask Pollymetric how your Mac is doing. You approve each agent with
Touch ID, see what it looked at, and can revoke it any time. Anything that would change your Mac asks
you first, every time.

## Private by design

Everything Pollymetric records is stored on your Mac. There's no account, no cloud and no tracking.
When you use Explain or Find a Fix, only the relevant context goes to the agent you chose. It uses less
than 1% CPU at idle.

## Install

1. [**Download Pollymetric.dmg**](https://github.com/pouyanafisi/pollymetric/releases/latest/download/Pollymetric.dmg) (or browse [all releases](https://github.com/pouyanafisi/pollymetric/releases)).
2. Open it and drag Pollymetric into **Applications**.
3. Open Pollymetric. A short setup lets you choose what to enable: start at login, the one permission
   that lets it check your whole Mac, the extra cleanup and security tools (installed for you), and any
   AI agents it found.

> **Early release:** this version isn't notarized by Apple yet, so the first time you open it macOS will
> say it can't verify the developer. Open **System Settings → Privacy & Security** and click
> **Open Anyway**.

<p align="center">
  <img src="docs/screenshots/setup.png" width="440" alt="The setup window">
</p>

Works on macOS 14 Sonoma or later, on Apple silicon and Intel Macs.

To remove it: **Settings → General → Uninstall**, with the option to delete everything it recorded.

## Why "Pollymetric"?

Polly, as in the parrot AI gets compared to. Metric, as in measure. Pollymetric keeps count of what the
parrots are doing to your machine.

---

Building Pollymetric yourself? See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
