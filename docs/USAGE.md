# updatetools — full reference

Flags, step keys, scheduling, and how updates stay safe. For the short version see the [README](../README.md).

## What it does

`updatetools` walks through every package manager and tool it can find and
upgrades it. Every step is **guarded** — if a tool isn't installed, the step is
skipped, so the same script is safe to run on any Mac.

Covered today (matches the script's step table):

| Area | Tools |
|------|-------|
| macOS | `softwareupdate`: updates that need no restart (Safari, XProtect, Command Line Tools) are installed; restart-required updates and major upgrades are listed, never installed or restarted |
| App Store | `mas update`; an open app is restarted if it is safe to restart, otherwise left for the next run |
| Homebrew | `brew update`, formula & cask upgrades (greedy), autoremove, cleanup |
| Direct-download apps | Strictly matched drag-and-drop `.app` bundles from DMGs; open apps are restarted only when safe to restart, otherwise staged until they quit |
| Node | `npm` globals, `pnpm` |
| Python | `uv` (self + tools) |
| Rust | `cargo install-update` |
| CLIs | Supabase, Vercel, Claude Code (`claude update`), Codex (npm-only), Antigravity (`agy update`), `gh` extensions |
| Editor | VS Code extensions |
| Report | Version diff of what actually changed this run |

Verbose output streams to a per-run log file; the dashboard only shows status.

## Install

### Homebrew (recommended)

This repo is a Homebrew tap (`Formula/updatetools.rb`). The stable formula pins
release [`2026.10.20.2`](https://github.com/dekrezz/updatetools/releases/tag/2026.10.20.2).
`--HEAD` tracks `main` via git.

```bash
brew tap dekrezz/updatetools https://github.com/dekrezz/updatetools
brew trust --formula dekrezz/updatetools/updatetools
brew install updatetools
brew install --HEAD updatetools   # track main
```

Homebrew 7 will not load a third-party formula until you trust it.
`brew trust` is local and has to be run once per machine; the formula cannot
skip it.

(`brew tap user/repo` without a URL expects a `homebrew-updatetools` repo; the
explicit URL is required for this project name.)

### From git

```bash
git clone https://github.com/dekrezz/updatetools.git
cd updatetools

mkdir -p ~/.local/bin
install -m 755 updatetools ~/.local/bin/
# make sure ~/.local/bin is on your PATH in ~/.zshrc:
#   export PATH="$HOME/.local/bin:$PATH"
```

Update an installed copy in place. It installs the release that the Homebrew
formula pins, only if the tarball matches the formula's sha256, and replaces
the running script atomically:

```bash
updatetools --self-update
updatetools --version   # release tag, or git describe in a checkout (see below)
```

> One file, nothing else to copy: the dashboard, the plain run, the cask
> close logic and the HTML report generator all live inside `updatetools`.

## Usage

```bash
updatetools                 # live dashboard in your browser (default)
updatetools --plain         # plain scrolling text output, no browser
updatetools --only homebrew,npm   # this run: only these steps
updatetools --skip rust,astral    # this run: skip cargo + uv steps
updatetools --no-greedy     # don't force-upgrade self-managing casks
updatetools --no-manual-apps # skip apps installed manually from DMGs
updatetools --version       # release tag, or git describe in a checkout
updatetools --self-update   # install the latest release (sha256-checked)
updatetools --schedule      # LaunchAgent: run --plain every 24h
updatetools --schedule 12h  # every 12 hours (also: seconds, 30m, 1d, 1w, or HH:MM)
updatetools --unschedule    # remove the LaunchAgent
updatetools --help
```

The **dashboard is the default** on an interactive terminal. When stdout isn't a
TTY (pipes, cron, CI) it automatically uses plain text — so scripting it is safe
without any flag.

`--version` prints the release tag for a copy installed from one (`2026.10.20.2`),
or `git describe` when run from a checkout of this repo. Other installed copies
use the `UPDATETOOLS_REV` stamp written by `--self-update` or the Homebrew
formula. `--self-update` stamps the release tag it installed.

### Flags

| Flag | Effect |
|------|--------|
| `--plain` | Force plain scrolling output instead of the dashboard. |
| `--web` | Force the dashboard (default; useful only to override `PLAIN=1`). |
| `--yes`, `-y` | Open the dashboard and start at once with the saved selection (plus `--only` / `--skip`), without waiting for **Start update**. Does not rewrite the saved set. |
| `--only a,b` | This run only: enable these step keys (comma/space list). Does not rewrite the saved set unless you press Start update in the dashboard. |
| `--skip a,b` | This run only: disable these step keys. |
| `--debug`, `--keep` | Keep the run log and write the HTML report to the Desktop. |
| `--no-greedy` | Skip `--greedy` so casks that self-update are left alone. |
| `--no-close` | Never close running apps — stage every cask upgrade with `--no-quit`. |
| `--no-manual-apps` | Skip discovery and safe staging of manually installed DMG apps. |
| `--version` | Print the release tag, or `git describe` from a checkout. |
| `--self-update` | Replace the running script with the release pinned by `Formula/updatetools.rb`, verified against its sha256. Unreleased commits on `main` are never installed. |
| `--schedule [interval]` | Install a per-user LaunchAgent (`com.dekrezz.updatetools`) that runs `updatetools --plain`. Default interval: 24h. Replaces an existing agent. Interval: bare seconds, `30m` / `12h` / `1d` / `1w`, or `HH:MM` for a daily wall-clock time. Does not run an update at install time. |
| `--unschedule` | Boot out and delete that LaunchAgent. |
| `--no-notify` | Never show a desktop notification when a run ends. |
| `--notify-on-error` | Notify only when at least one step failed (conflicts with `--no-notify`). |

Default is to notify at the end of every run (dashboard and `--plain`, including the scheduled job) with text that says whether the run finished cleanly or had failures.

### Which steps run

The dashboard lists the sources installed on this Mac with a switch and waits
for **Start update** (or <kbd>⌘</kbd><kbd>↩</kbd>) before any step command runs. Tools
that are not installed do not appear on the dashboard at all, and their saved
switch is kept for when you install them. Closing the tab
still cancels the run. Your enabled set is saved to
`~/.config/updatetools/enabled` (one key per line) when you press Start update; the
internal `report` step always runs. With `--yes` the run starts immediately.
A missing file means all steps are on; an unreadable file is a hard error.

Plain mode (`--plain` / non-TTY) does not wait for the browser: it applies the
saved file plus `--only` / `--skip` and runs immediately. A step you turned off
is reported as skipped (turned off), distinct from a missing tool (guard failed).

Step keys (stable slugs, same as the ribbon where possible):

`homebrew`, `applications`, `appstore` (mas), `macos` (softwareupdate), `npm`, `pnpm`, `astral` (uv), `rust` (cargo),
`supabase`, `vercel`, `claude`, `codex`, `antigravity`, `github` (gh), `vscode`,
`report`.

Steps that may need `sudo` run first, one at a time: Homebrew, DMG apps,
App Store, macOS. Then sudo is dropped (`sudo -k`, and the dashboard forgets the
password), and the package-manager and CLI steps run as a parallel wave.
The password is asked for only if one of those privileged steps is enabled.
The report step stays last.

### Environment toggles

| Var | Same as |
|-----|---------|
| `PLAIN=1` | `--plain` |
| `GREEDY=0` | `--no-greedy` |
| `CLOSE_APPS=0` | `--no-close` |
| `QUIET_APPS=0` | `--no-manual-apps` |
| `DEBUG=1` | `--debug` |
| `UPDATETOOLS_ENABLED_FILE` | Override path for the saved enabled-step list. |
| `AUTO_START=1` | `--yes` |
| `UPDATETOOLS_DURATIONS_FILE` | Override `~/.config/updatetools/durations`, where each step's last run time is kept for the dashboard's time estimate. |
| `UPDATETOOLS_HISTORY_FILE` | Override `~/.config/updatetools/history`, where the [run history](#run-history) is kept. |
| `HISTORY_KEEP` | How many runs the history keeps (default `200`). |
| `STALL_TIMEOUT` | Seconds a step may show no progress before it is stopped (default `300`, `0` turns it off). A Homebrew download that is still arriving counts as progress, though Homebrew prints nothing while it downloads. |
| `NET_TIMEOUT` | Seconds without a network connection before the run stops (default `30`, `0` turns the network watch off). |
| `STOP_GRACE` | Seconds a tool that is asked to stop gets to exit before it is killed (default `30`). |
| `WEB_IDLE` | Seconds the dashboard's server waits for a closed (or reloading) tab to come back before it ends, outside a run (default `75`). |
| `WEB_AWAY` | Seconds the dashboard's server waits for a quiet tab before it ends, outside a run (default `28800`, a working day). |
| `DIAG_DIR` | Where a run that stopped or failed keeps its log and report (default `~/Library/Logs/updatetools`). |
| `DIAG_KEEP` | How many of those runs are kept (default `20`). |
| `NOTIFY_MODE=never` | `--no-notify` |
| `NOTIFY_MODE=on_error` | `--notify-on-error` |
| `UPDATETOOLS_CLOSE="a b"` | Force-close these cask apps to upgrade them now (space/comma list of tokens). |
| `UPDATETOOLS_PROTECT="a b"` | Never close these apps (cask tokens or bundle ids). |
| `UPDATETOOLS_SAFE_RESTART="a b"` | Extra known-safe utilities (cask tokens or bundle ids) that may be restarted even with a regular window. Never overrides the terminal, risky-category or hosted-work checks. |
| `BREW_CASK_SKIP="a b"` | Casks needing an interactive sudo password — kept out of the run and reported for manual upgrade (default `stats aldente`). |

## Apps installed from DMGs

`updatetools` also scans `/Applications` and `~/Applications` for apps that were
dragged from a downloaded DMG and are not managed by Homebrew or the App Store.
It uses Homebrew Cask only as a download catalogue; it does not adopt the app or
change package-manager ownership.

The match must be unique and the replacement must be newer, have the expected
SHA-256, keep the same bundle ID and Developer Team ID, and pass both `codesign`
and Gatekeeper. An app is touched only when macOS still records a `.dmg`
download source. Apps that update themselves (Sparkle, Mozilla/Tor) or have no
DMG provenance are left alone. If nothing needs a DMG update, the step reports
that everything is already up to date.

If the app is open and [safe to restart](#safe-to-restart), it is quit
gracefully, swapped atomically and reopened in the background. Any other open
app is never quit: the verified bundle is staged beside it and a detached
one-shot helper waits for the user to close it naturally. The helper then uses
an APFS atomic directory swap and removes itself. That case is reported as
**staged** (not done) until the swap applies.

## Deciding which apps to close

Casks are the tricky part: `brew upgrade --cask` normally **quits** a running app
to swap its bundle (and never relaunches it), while `--no-quit` leaves the app
running the old version until its next launch. Instead of picking one blanket
behaviour, `updatetools` classifies every outdated cask that maps to an app and
acts per verdict:

| Verdict | When | Action |
|---------|------|--------|
| **upgrade** | app installed but **not running** | upgrade in place — nobody's using it |
| **close** | app running **and safe to restart** (see below) | graceful quit → upgrade → relaunch in the background |
| **protect** | app running but unsafe to close | stage with `--no-quit`; applies on next launch |
| **skip (manual)** | needs an interactive sudo password (`BREW_CASK_SKIP`) | reported, not touched |
| **broken** | app missing from `/Applications` and an interrupted upgrade left its backup in the Caskroom (every `brew upgrade` fails) | `brew reinstall --cask` |

An app is **protected** (never closed) when it is any of:

- the **terminal running this script** (closing it would kill the run) — resolved
  by walking the process tree to the hosting GUI app;
- reporting **unsaved changes / open documents** (best-effort AppleScript probe —
  anything not provably clean is treated as unsaved, so it's protected);
- in a **risky category**: browsers, editors/IDEs, VMs & containers, meeting/
  recording apps, password managers, backup tools;
- listed in **`UPDATETOOLS_PROTECT`**.

### Safe to restart

Some apps hold nothing that a restart could lose, but cannot answer the
unsaved-changes probe (menu-bar utilities have no documents, so the probe fails
and would protect them forever). `updatetools` detects these itself. A running
app is **restarted** when all of these hold:

- it is not the hosting terminal, not in `UPDATETOOLS_PROTECT`, and not in a
  risky category — matched by cask token **and** bundle id (terminals, password
  managers, VPN/network clients, backup/sync, meeting/recording apps, browsers,
  editors, VMs, Apple apps);
- it hosts no work: every child process runs from inside its own bundle (an
  agent running a shell, a script or a VM stays protected);
- it is a **menu-bar or background agent** (`LSUIElement` / `LSBackgroundOnly`,
  or LaunchServices type `UIElement` / `BackgroundOnly`) **with no document
  model** that declares no microphone or camera use (`NSMicrophoneUsageDescription`
  / `NSCameraUsageDescription`: dictation, recording and capture tools can be
  mid-capture) — or it is on the curated list of known-safe utilities (Rectangle,
  Raycast, Alfred, Hidden Bar, Ice, Bartender, AltTab, Stats, MonitorControl,
  Maccy, AlDente) or in `UPDATETOOLS_SAFE_RESTART`.

Ordinary windowed apps are never restarted by this rule. The restart is a
standard Quit request, the update, then `open -g` from the app's own path
(`-j` too for menu-bar agents, so nothing comes to the front). The tool then
waits up to ten seconds for the app to be running again; if it is not, the step
fails with "relaunch failed" instead of counting a restart. The same rule
applies to open App Store apps and to DMG apps.

Apps that pass neither the safe-restart rule nor the unsaved-changes probe stay
protected. **`UPDATETOOLS_CLOSE`** forces a close for anything except the
hosting terminal. Nothing is ever force-killed: if a graceful quit doesn't
complete (e.g. a save dialog appears), the app keeps running and the update is
staged. Pass `--no-close` to disable closing entirely. Protected / deferred
updates show as **staged** in the step status and report; restarted ones are
marked **restarted**, because the running app is already on the new version.

An auto-updating app often installs its own update before Homebrew sees it, so
brew still lists the cask as outdated. When the installed bundle already reports
the cask's latest version, the cask counts as **upgraded**, never staged, even if
the app is running: brew only re-syncs its own record.

## The report

Every run diffs versions from before and after, and shows what actually changed
— with each tool's logo (bundled [Simple Icons](https://simpleicons.org), CC0,
falling back to the project's own site icon, cached under
`~/.cache/updatetools/icons`) and the vendor's spelling from Homebrew's metadata,
so it reads `ChatGPT`, not `chatgpt`. Staged cask upgrades (installed, but the running
process is still on the old build) stay in that list with an **i** mark next to
the version; hover or focus it to see that the change applies on next launch. `--debug` also writes the
report to the Desktop as a self-contained HTML file.

## The dashboard

The run has no terminal UI. It serves a page on `127.0.0.1` (random port), opens
it in your default browser, and prints one summary line in the terminal when the
run is over. The page speaks Antigravity's design language (Google Sans Flex,
near-black ink on white or the reverse, 24px cards, pill buttons). Its main
column has a headline with its one action, then the sources, then the plan; on
a window 1200px or wider the [History](#run-history) panel sits beside it, and
on a narrower one below it.

- **Before the run** it checks, read-only and in the background, what Homebrew
  (and `mas`, when installed) would update, and lists each item with its old and
  new version and its plan: **Restarts** (an open app that is safe to restart),
  **Checks first** (open; restarted only if it reports no unsaved work),
  **Waits for quit** (open and protected, with the reason), **Installs**,
  **Record only** (the app already updated itself) or **Manual**. The check
  never asks an app anything, so it cannot raise an Automation prompt. Sources
  without a cheap check are named as "checked as they run". Each item shows its
  logo: an app's own icon from its bundle, a formula's mark or its project's
  site icon. Each source has a switch; the selection is remembered.
- **During the run** a timer, a ribbon with one segment per source and its
  legend lead the page. The headline says what is running, how many sources are
  done and, from the durations of earlier runs, about how long is left. A
  running source shows its newest output line in its row; hover a source to
  preview its output and click it to keep it open (a running source's output
  follows live). The plan stays under the list for sources still running or
  to run, and each Homebrew item says where it is, read from Homebrew's own
  output: **Downloading** (with how far it is), **Downloaded**, **Installing**,
  **Updated**, **Restarted**, **Next launch** or **Failed**.
- **After the run** the page leads with what needs attention: each failed
  step's own error line (steps that failed for the same reason are grouped),
  with **Retry failed** to run only those steps again while every other result
  stays. Then the apps that wait for you to quit, then a card that opens every
  version that moved, with release notes where known. A clean run opens that
  list on its own.

Light, dark or system appearance is a switch in the top-right corner. Passwords are asked for **in the page** — nothing is echoed as
you type — and the answer goes straight to `sudo`. If the keyboard is not the
language that password was accepted in (English until one succeeds), the reveal
control closes and the sheet says which language is on instead. If a required
password is rejected (three tries, or the prompt is cancelled), no step starts
and nothing is changed; the page offers **Try again**, which asks for it once
more without restarting the tool. If the password is rejected when you press
**Retry failed**, nothing runs again and the page says so.

Access is locked down: loopback only, a random per-run token exchanged for an
`HttpOnly` cookie (everything else is `403`), a `Host` check against DNS
rebinding, and the token handed to the server through a `0600` file rather than
argv. The page's lifetime ends the run's server, and with it the run, but a
quiet page is not taken for a closed one: a browser stops the timers of a hidden
tab (its window behind the terminal, another tab in front). So:

- While the run is going, the server never ends because the page is quiet. Come
  back to the tab at any time and it picks up where the run is.
- Once the run is over, closing the tab ends the server at once.
- Closing the tab before or during the run tells the server too; it waits
  `WEB_IDLE` seconds for the page to come back (a reload does), and while the run
  is going it waits for the run to end first. On the chooser this cancels the run.
- A page that is only quiet after the run (the tab is hidden, or the browser
  crashed) is waited for `WEB_AWAY` seconds, counted from the end of the run if
  it was quiet through it. Time the Mac sleeps does not count.

The log and HTML report live in a temp dir that goes away when the run ends.
A deferred DMG update temporarily leaves its verified staged app and one-shot
helper on disk; both are removed after the natural app exit and atomic swap.
Pass `--debug` to keep the log and report.

### Run history

Every run in which at least one step ran is recorded for the dashboard's
**History** panel, whether it ran from the dashboard or without it (`--plain`,
a scheduled run). The record says when its steps started, how long it took and
how it ended: finished, with a failed step, or stopped and why (network lost,
or Ctrl+C / `kill` / a closed terminal). It lists each step that ran with its
outcome and time, and each update the report found, with the old and new
version and the release-notes link. A **Retry failed** or **Continue** round
rewrites the same run's record instead of adding one.

The records are JSON lines in `~/.config/updatetools/history`, oldest first.
After every write only the newest `HISTORY_KEEP` runs (default `200`) remain.

Not recorded:

- a run in which no step ran, or only Report: the password was rejected, the
  tab was closed before **Start update**, there was no network when the steps
  were about to start, or no step was selected;
- a run killed with `kill -9`, which gives it no chance to write anything.

If the file cannot be written, the run goes on and the terminal says
`updatetools: could not record this run in <file>: <reason>`. A line in the
file that is not a valid run record (after a hand edit, say) is never repaired
or dropped: the History panel shows the file and the line number instead of the
history, the terminal says the same when the dashboard opens, and new runs are
still added. Fix or delete that line to see the history again.


## When a run is interrupted

A run never ends by leaving its tools running. Whatever stops it, every tool
still running is sent `SIGTERM`, the polite request to stop, and gets
`STOP_GRACE` seconds to exit on its own (Homebrew cleans up an unfinished
install when it gets it). Only a tool still running after that is killed, and
the message names it, with `brew doctor` as the check for Homebrew. No step
starts after a stop, so the next run (or the next step) never collides with a
tool that is still finishing.

- **Network lost.** While the steps run, the connection is checked every few
  seconds (a default route, then Apple's connectivity check or GitHub). The
  dashboard warns as soon as it is gone; after `NET_TIMEOUT` seconds in a row
  the run stops. A shorter drop, such as Wi-Fi switching networks, changes
  nothing. With no connection at all when the steps are about to start, none
  starts. `--plain` exits with code `75` so a scheduled run can tell this from a
  failure.
- **Ctrl+C, `kill`, or the terminal closed.** The same stop. The terminal
  prints what was stopped, what never ran and where the diagnostics are; a
  closed terminal gets a desktop notification instead. Press Ctrl+C a second
  time to kill at once instead of waiting. Exit codes: `130` (Ctrl+C), `143`
  (`kill`), `129` (closed terminal). Once the run has finished, Ctrl+C just
  closes it.
- **`kill -9` or a crash.** Nothing can catch that, so the dashboard's local
  server, which outlives the run, stops what the run left running and says so in
  the terminal and on the page. The next `updatetools` run finds the run that
  did not finish, saves its log and warns in the terminal and on the dashboard.

After a stop, the dashboard's **Continue** runs the stopped steps and the ones
that never ran.

A run that stops or has a failed step keeps `run.log` (every step's output
plus timestamped events: steps starting and ending with their exit codes,
network drops, stall and stop actions, signals) and `diagnostics.txt` (the
outcome, each step's result, the network and Homebrew lock state, free disk
space and the last output of each failed step) in a folder of
`~/Library/Logs/updatetools`. The path is shown on the dashboard and in the
terminal. A clean run still leaves nothing behind.

## Notes & gotchas

- **Codex CLI** is detected by resolving its binary symlink, so it updates
  correctly even when installed into a non-default npm prefix (e.g. an iCloud
  `~/.local`). The `codex-app` desktop cask is upgraded separately.
- **App Store** updates need [`mas`](https://github.com/mas-cli/mas)
  (`brew install mas`) and an Apple Account signed in to the App Store.
- **macOS** updates that need a restart leave the step **staged** and print the
  command to install them when you are ready: `sudo softwareupdate -i -a -R`.
- A UTF-8 locale is forced internally so the dashboard always aligns.
- The report needs `jq` (ships with macOS) for vendor names and site icons;
  without it, names fall back to the package token and logos to a package glyph.

## Requirements

- macOS (Apple Silicon or Intel)
- `bash` (the system `/bin/bash` is fine)
- Homebrew recommended (most steps build on it)
- Xcode Command Line Tools (already required by Homebrew; builds the tiny atomic-swap helper)

