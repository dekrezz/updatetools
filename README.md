<div align="center">
  <img src="assets/updatetools-mark.svg" width="112" alt="updatetools logo">

  <h1>updatetools</h1>

  <p><strong>One command to keep the tools on your Mac up to date.</strong></p>

  <p>
    Homebrew, global packages, developer CLIs and editor extensions — updated
    from a private live dashboard, without interrupting your work.
  </p>

  <p>
    <a href="https://github.com/dekrezz/updatetools/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/dekrezz/updatetools?style=flat-square&color=7AA2FF"></a>
    <a href="https://github.com/dekrezz/updatetools/commits/main"><img alt="Last commit" src="https://img.shields.io/github/last-commit/dekrezz/updatetools?style=flat-square&color=67E8C4"></a>
    <img alt="macOS" src="https://img.shields.io/badge/macOS-12%2B-11151D?logo=apple&logoColor=white">
    <img alt="Bash" src="https://img.shields.io/badge/Bash-3.2%2B-4EAA25?logo=gnubash&logoColor=white">
    <img alt="Homebrew" src="https://img.shields.io/badge/Homebrew-ready-FBB040?logo=homebrew&logoColor=11151D">
    <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/license-Apache_2.0-67E8C4?style=flat-square"></a>
  </p>

  <p>
    <a href="#what-it-does">What it does</a> ·
    <a href="#install">Install</a> ·
    <a href="#usage">Usage</a> ·
    <a href="#the-dashboard">Dashboard</a> ·
    <a href="#the-report">Report</a> ·
    <a href="CONTRIBUTING.md">Contributing</a> ·
    <a href="SECURITY.md">Security</a> ·
    <a href="#license">License</a>
  </p>
</div>

---

## What it does

`updatetools` walks through every package manager and tool it can find and
upgrades it. Every step is **guarded** — if a tool isn't installed, the step is
skipped, so the same script is safe to run on any Mac.

Covered today:

| Area | Tools |
|------|-------|
| Homebrew | `brew update`, formula & cask upgrades (greedy), autoremove, cleanup, `brew doctor` |
| Direct-download apps | Strictly matched drag-and-drop `.app` bundles from DMGs, staged without quitting running apps |
| Node ecosystem | `npm` globals, `pnpm`, `yarn`, `bun`, `deno` |
| Python | `pipx`, `uv` (self + tools), `conda` |
| Rust | `rustup`, `cargo install-update` |
| Ruby / PHP | system-`gem` aware, `composer` self + global |
| Version managers | `mise`, `asdf`, `pyenv`, `rbenv`, `nodenv`, `fnm`, `volta`, `tfenv` |
| Cloud / k8s | `gcloud`, `az`, `aws`, `helm`, `kubectl krew`, `flutter`, `dotnet` |
| CLIs | Codex (custom npm prefix aware), Claude Code (`claude update`), Supabase, Vercel, `gh` extensions |
| Editor / docs | VS Code extensions, `tldr` cache |
| App Store / OS | `mas`, macOS software updates (opt-in) |

Verbose output streams to a per-run log file; the dashboard only shows status.

## Install

### Homebrew (recommended)

This repo is a Homebrew tap (`Formula/updatetools.rb`). There is no release tag
yet, so the formula is **head-only** (tracks `main` via git — no rotting
`sha256`):

```bash
brew tap dekrezz/updatetools https://github.com/dekrezz/updatetools
brew install --HEAD updatetools
```

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

Update an installed copy in place (downloads `main` from GitHub and replaces
the running script atomically):

```bash
updatetools --self-update
updatetools --version   # short git revision (see below)
```

> One file, nothing else to copy: the dashboard, the plain run, the cask
> close logic and the HTML report generator all live inside `updatetools`.

## Usage

```bash
updatetools                 # live dashboard in your browser (default)
updatetools --plain         # plain scrolling text output, no browser
updatetools --only homebrew,npm   # this run: only these steps
updatetools --skip rust,astral    # this run: skip cargo + uv steps
updatetools --macos         # ALSO install macOS + App Store updates (may reboot!)
updatetools --plain --macos
updatetools --no-greedy     # don't force-upgrade self-managing casks
updatetools --no-manual-apps # skip apps installed manually from DMGs
updatetools --version       # short revision of this copy
updatetools --self-update   # replace this script with main from GitHub
updatetools --help
```

The **dashboard is the default** on an interactive terminal. When stdout isn't a
TTY (pipes, cron, CI) it automatically uses plain text — so scripting it is safe
without any flag.

`--version` prints a short revision string (not a semver — none is defined yet).
From a git checkout of this repo it uses `git describe`; installed copies use
the `UPDATETOOLS_REV` stamp written by `--self-update` or the Homebrew formula.

### Flags

| Flag | Effect |
|------|--------|
| `--plain` | Force plain scrolling output instead of the dashboard. |
| `--web` | Force the dashboard (default; useful only to override `PLAIN=1`). |
| `--only a,b` | This run only: enable these step keys (comma/space list). Does not rewrite the saved set unless you confirm Start in the dashboard. |
| `--skip a,b` | This run only: disable these step keys. |
| `--debug`, `--keep` | Keep the run log and write the HTML report to the Desktop. |
| `--macos`, `--all` | Install macOS **and** Mac App Store updates. Off by default. |
| `--no-greedy` | Skip `--greedy` so casks that self-update are left alone. |
| `--no-close` | Never close running apps — stage every cask upgrade with `--no-quit`. |
| `--no-manual-apps` | Skip discovery and safe staging of manually installed DMG apps. |
| `--version` | Print the short revision of this copy. |
| `--self-update` | Replace the running script with `main` from GitHub. |

### Which steps run

The dashboard lists every step with a toggle and waits for **Start update** before
any step command runs. Closing the tab still cancels the run. Your enabled set is
saved to `~/.config/updatetools/enabled` (one key per line) when you press Start.
A missing file means all steps are on; an unreadable file is a hard error.

Plain mode (`--plain` / non-TTY) does not wait for the browser: it applies the
saved file plus `--only` / `--skip` and runs immediately. A step you turned off
is reported as skipped (turned off), distinct from a missing tool (guard failed).

Step keys (stable slugs, same as the ribbon where possible):

`homebrew`, `applications`, `npm`, `pnpm`, `astral` (uv), `rust` (cargo),
`supabase`, `vercel`, `claude`, `codex`, `antigravity`, `github` (gh), `vscode`,
`report`.

### Environment toggles

| Var | Same as |
|-----|---------|
| `PLAIN=1` | `--plain` |
| `MACOS_UPDATES=1` | `--macos` |
| `GREEDY=0` | `--no-greedy` |
| `CLOSE_APPS=0` | `--no-close` |
| `QUIET_APPS=0` | `--no-manual-apps` |
| `DEBUG=1` | `--debug` |
| `UPDATETOOLS_ENABLED_FILE` | Override path for the saved enabled-step list. |
| `UPDATETOOLS_CLOSE="a b"` | Force-close these cask apps to upgrade them now (space/comma list of tokens). |
| `UPDATETOOLS_PROTECT="a b"` | Never close these cask apps. |
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

If the app is open, the verified bundle is staged beside it and a detached
one-shot helper waits for the user to close it naturally. The helper then uses
an APFS atomic directory swap and removes itself. It never sends Quit events,
relaunches applications, controls windows, or moves the pointer.

## Deciding which apps to close

Casks are the tricky part: `brew upgrade --cask` normally **quits** a running app
to swap its bundle (and never relaunches it), while `--no-quit` leaves the app
running the old version until its next launch. Instead of picking one blanket
behaviour, `updatetools` classifies every outdated cask that maps to an app and
acts per verdict:

| Verdict | When | Action |
|---------|------|--------|
| **upgrade** | app installed but **not running** | upgrade in place — nobody's using it |
| **close** | app running **and provably safe to quit** | graceful quit → upgrade → relaunch |
| **protect** | app running but unsafe to close | stage with `--no-quit`; applies on next launch |
| **skip (manual)** | needs an interactive sudo password (`BREW_CASK_SKIP`) | reported, not touched |

An app is **protected** (never closed) when it is any of:

- the **terminal running this script** (closing it would kill the run) — resolved
  by walking the process tree to the hosting GUI app;
- reporting **unsaved changes / open documents** (best-effort AppleScript probe —
  anything not provably clean is treated as unsaved, so it's protected);
- in a **risky category**: browsers, editors/IDEs, VMs & containers, meeting/
  recording apps, password managers, backup tools;
- listed in **`UPDATETOOLS_PROTECT`**.

Because the unsaved-changes probe fails safe, **`close` is deliberately rare** —
in practice it only fires for scriptable apps with a clean document model, or for
apps you explicitly force with **`UPDATETOOLS_CLOSE`**. Nothing is ever
force-killed: if a graceful quit doesn't complete (e.g. a save dialog appears),
the cask falls back to staging. Pass `--no-close` to disable closing entirely.

## The report

Every run diffs versions from before and after, and shows what actually changed
— with each tool's logo (bundled [Simple Icons](https://simpleicons.org), CC0,
falling back to the project's own site icon, cached under
`~/.cache/updatetools/icons`) and the vendor's spelling from Homebrew's metadata,
so it reads `ChatGPT`, not `chatgpt`. `--debug` also writes it to the Desktop as
a self-contained HTML file.


## Why macOS updates are opt-in

`sudo softwareupdate -ia` can **reboot your machine mid-work** without warning, so
OS and App Store updates are never installed by default. A normal run only *lists*
available macOS updates; pass `--macos` (or `MACOS_UPDATES=1`) to actually install
them.

## The dashboard

The run has no terminal UI. It serves a page on `127.0.0.1` (random port), opens
it in your default browser, and prints nothing. The page shows every step with a
toggle before the run, waits for you to press Start, then shows live progress with
per-step durations and the version diff at the end; hovering a step opens that
step's output. Passwords are asked for **in the page** — nothing is echoed as
you type — and the answer goes straight to `sudo`.

Access is locked down: loopback only, a random per-run token exchanged for an
`HttpOnly` cookie (everything else is `403`), a `Host` check against DNS
rebinding, and the token handed to the server through a `0600` file rather than
argv. Closing the tab ends the run's server, and with it the run.

The log and HTML report live in a temp dir that goes away when the run ends.
A deferred DMG update temporarily leaves its verified staged app and one-shot
helper on disk; both are removed after the natural app exit and atomic swap.
Pass `--debug` to keep the log and report.


## Notes & gotchas

- **Codex CLI** is detected by resolving its binary symlink, so it updates
  correctly even when installed into a non-default npm prefix (e.g. an iCloud
  `~/.local`). The `codex-app` desktop cask is upgraded separately.
- **System Ruby** (`/usr/bin/gem`) is SIP-protected and intentionally skipped —
  use a Homebrew/`rbenv` Ruby if you want gems managed.
- **Homebrew Python** is externally managed, so global `pip` upgrades are skipped
  on purpose; use `pipx`/`uv` for tools.
- A UTF-8 locale is forced internally so the dashboard always aligns.
- The report needs `jq` (ships with macOS) for vendor names and site icons;
  without it, names fall back to the package token and logos to a monogram.

## Requirements

- macOS (Apple Silicon or Intel)
- `bash` (the system `/bin/bash` is fine)
- Homebrew recommended (most steps build on it)
- Xcode Command Line Tools (already required by Homebrew; builds the tiny atomic-swap helper)

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
