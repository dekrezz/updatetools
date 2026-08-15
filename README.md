# updatetools

One command to update **everything updatable** on your Mac — Homebrew, language
package managers, global CLIs, editor extensions, and (optionally) macOS itself —
plus an animated full-screen dashboard to watch while it runs. It's a **single
script** with no companion files.

```
  U P D A T E T O O L S   keeping your Mac fresh                      ⏱ 03:41
  ────────────────────────────────────────────────────────────────────────────

  ██████────────────────────  23%  4/17    ✓ 3   · 1   ✗ 0

  ╭ ✓  Homebrew          update index                                     1s
  │ ✓  Report            scan versions                                    3s
  │ ✓  Homebrew          upgrade formulae                                42s
  ┃ ⢿  Homebrew          upgrade casks                                 01:13
  │    ╰ ==> Fetching downloads for: android-studio
  │ ○  npm               global packages
  ╰ ○  Report            save to Desktop
```

## What it does

`updatetools` walks through every package manager and tool it can find and
upgrades it. Every step is **guarded** — if a tool isn't installed, the step is
skipped, so the same script is safe to run on any Mac.

Covered today:

| Area | Tools |
|------|-------|
| Homebrew | `brew update`, formula & cask upgrades (greedy), autoremove, cleanup, `brew doctor` |
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

```bash
git clone https://github.com/dekrezz/updatetools.git
cd updatetools

mkdir -p ~/.local/bin
install -m 755 updatetools ~/.local/bin/
# make sure ~/.local/bin is on your PATH in ~/.zshrc:
#   export PATH="$HOME/.local/bin:$PATH"
```

> One file, nothing else to copy: the dashboard, the plain run, the cask
> close logic and the HTML report generator all live inside `updatetools`.

## Usage

```bash
updatetools                 # animated dashboard (default, on a terminal)
updatetools --plain         # plain scrolling text output (no dashboard)
updatetools --macos         # ALSO install macOS + App Store updates (may reboot!)
updatetools --plain --macos
updatetools --no-greedy     # don't force-upgrade self-managing casks
updatetools --help
```

The **dashboard is the default** on an interactive terminal. When stdout isn't a
TTY (pipes, cron, CI) it automatically uses plain text — so scripting it is safe
without any flag.

### Flags

| Flag | Effect |
|------|--------|
| `--plain` | Force plain scrolling output instead of the dashboard. |
| `--dashboard` | Force the dashboard (default; useful only to override `PLAIN=1`). |
| `--macos`, `--all` | Install macOS **and** Mac App Store updates. Off by default. |
| `--no-greedy` | Skip `--greedy` so casks that self-update are left alone. |
| `--no-close` | Never close running apps — stage every cask upgrade with `--no-quit`. |
| `--no-report` | Don't write the HTML report to the Desktop. |
| `--no-open` | Write the report but don't open it in a browser. |

### Environment toggles

| Var | Same as |
|-----|---------|
| `PLAIN=1` | `--plain` |
| `MACOS_UPDATES=1` | `--macos` |
| `GREEDY=0` | `--no-greedy` |
| `CLOSE_APPS=0` | `--no-close` |
| `MAKE_REPORT=0` | `--no-report` |
| `OPEN_REPORT=0` | `--no-open` |
| `UPDATETOOLS_CLOSE="a b"` | Force-close these cask apps to upgrade them now (space/comma list of tokens). |
| `UPDATETOOLS_PROTECT="a b"` | Never close these cask apps. |
| `BREW_CASK_SKIP="a b"` | Casks needing an interactive sudo password — kept out of the run and reported for manual upgrade (default `stats aldente`). |

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

## The Desktop report

After every run, `updatetools` writes a self-contained HTML report to
`~/Desktop/updatetools-report-<timestamp>.html` and (on a terminal) opens it. It
lists each tool that actually changed version this run as a card:

```
Vercel CLI      39.0.0  →  39.1.2      View changelog ↗
Claude Code      1.2.3  →  1.3.0       View changelog ↗
```

Versions come from a snapshot taken right after `brew update` (so `old → new` is
accurate) diffed against the post-run state; changelog links are a curated,
manually-maintained map. Disable with `--no-report`, or keep it but don't
auto-open with `--no-open`.

The page is dark/light aware, works offline, and shows each tool with its own
logo — bundled vector marks from [Simple Icons](https://simpleicons.org) (CC0),
falling back to the project's own site icon, cached under
`~/.cache/updatetools/icons`. Tool names use the vendor's spelling as recorded by
Homebrew (`ChatGPT`, `GitHub Copilot`), so the report reads like the products do.

## Why macOS updates are opt-in

`sudo softwareupdate -ia` can **reboot your machine mid-work** without warning, so
OS and App Store updates are never installed by default. A normal run only *lists*
available macOS updates; pass `--macos` (or `MACOS_UPDATES=1`) to actually install
them.

## The dashboard

- A timeline rail down the left edge, with the active step marked and washed.
- Sub-cell progress bar (⅛-cell resolution), percentage, counters, elapsed timer.
- Per-step durations, and the live tail of the running step's output beneath it.
- Status icons: `✓` done · `·` skipped · `✗` failed · `○` pending.
- Uses the alternate screen buffer (like `htop`/`vim`) and restores the terminal
  cleanly on exit or `Ctrl-C`.
- Every frame is sized to fit the window and auto-wrap is disabled, so the
  dashboard never scrolls itself into the scrollback (iTerm2 saves alternate-screen
  lines by default, which turns any stray scroll into an endless ribbon).
- Only one run at a time: a second launch refuses with the running PID, since two
  dashboards would paint over each other and collide on Homebrew's download lock.
- Closing the window ends the run and takes the current step's process tree with
  it, instead of leaving an orphan parked on a password prompt.
- Runs by default; uses plain text automatically when not attached to a TTY
  (pipes, cron, CI), or when you pass `--plain`.

When all steps finish, the **summary is shown inside the dashboard** (counts,
failed steps, log path) and it waits for you to **press `q`** to quit:

```
  ────────────────────────────────────────────────────────────────────────────

  all done  ·  12:34 elapsed

   ✓ 14 updated   · 2 skipped   ✗ 1 failed

  failed
    ✗ Homebrew · upgrade casks

  report  /Users/you/Desktop/updatetools-report-20260815.html
  log     /var/folders/.../updatetools-39499.log

   q  quit
```

The same summary is also echoed to the normal screen afterwards, so the log path
stays in your scrollback.

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

## License

MIT — see [LICENSE](LICENSE).
