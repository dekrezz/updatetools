#!/usr/bin/env bash
# updatetools-lib.sh — shared helpers for `updatetools` and `updatetools-tui`.
#
# Sourced by both front-ends (it must live next to them). Pure function
# definitions plus a couple of load-time constants; sourcing has no side effects
# beyond resolving which terminal hosts this shell. bash 3.2 compatible (the
# macOS system /bin/bash) — no associative arrays, no mapfile.
#
# It provides three capabilities:
#   1. classify_cask()          — decide per running app: close | protect | ...
#   2. ut_upgrade_casks_smart()  — upgrade outdated casks using that decision
#   3. version report to Desktop — ut_report_begin / ut_report_finish (HTML)

have() { command -v "$1" >/dev/null 2>&1; }

# ===========================================================================
# macOS app detection (researched & verified: macOS arm64, system bash 3.2)
# ===========================================================================

## Map a Homebrew cask token -> its .app bundle name(s)
# Uses `brew info --cask --json=v2` and jq. Prints one ".app" name per line
# (a cask can ship several apps). Fonts / CLI-only casks print nothing -> caller skips.
# Verified on this Mac: google-chrome -> "Google Chrome.app", utm -> "UTM.app",
# visual-studio-code -> "Visual Studio Code.app"; font-* / android-commandlinetools -> empty.
cask_to_apps() { # $1 = cask token
  local token="$1"
  brew info --cask --json=v2 "$token" 2>/dev/null \
    | jq -r '.casks[0].artifacts[]? | objects | .app[]? | select(type=="string")'
  # `.app` entries can be a bare string OR ["Name.app", {"target": "..."}] for
  # relocatable apps; `select(type=="string")` keeps only the real bundle name.
}

## Get an app's bundle identifier
# Reads CFBundleIdentifier from the bundle's Info.plist with PlistBuddy — most
# robust: no Spotlight dependency (mdls) and no Automation prompt (osascript).
# Verified all three methods agree on this Mac: Google Chrome->com.google.Chrome,
# Firefox->org.mozilla.firefox, VS Code->com.microsoft.VSCode,
# Cursor->com.todesktop.230313mzl4w4u92, UTM->com.utmapp.UTM.
app_to_bundleid() { # $1 = ".app" name (from cask_to_apps) or an absolute path
  local app="$1" p
  case "$app" in
    /*) p="$app" ;;
    *)  p="/Applications/${app%.app}.app" ;;
  esac
  [ -d "$p" ] || p="$HOME/Applications/${app##*/}"   # per-user install fallback
  [ -d "$p" ] || return 1                            # not installed
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$p/Contents/Info.plist" 2>/dev/null \
    || mdls -name kMDItemCFBundleIdentifier -raw "$p" 2>/dev/null
}

## Test whether an app is currently running — by bundle id, via lsappinfo
# `lsappinfo find bundleID=<id>` queries LaunchServices directly and prints an ASN
# (e.g. ASN:0x0-0xd00d-"Finder":) when a real app is registered under that bundle id,
# empty when not. Chosen over pgrep and System Events because:
#   * pgrep matches the process *name* and gives FALSE POSITIVES — verified on this
#     Mac: `pgrep -il chrome` matched "chrome_crashpad" while Google Chrome.app was
#     NOT running. Bundle-id matching has no such fuzz.
#   * System Events (`osascript ... application processes`) needs Automation
#     permission and can throw a TCC prompt/error; lsappinfo needs none.
# Verified: com.apple.finder / ru.keepcoder.Telegram -> ASN (running);
# com.google.Chrome -> empty (not running).
is_running() { # $1 = bundle id ; rc 0 if running
  [ -n "$(lsappinfo find "bundleID=$1" 2>/dev/null)" ]
}

## Detect the terminal / GUI app hosting THIS shell (so we never close it)
# Ground truth = walk the process tree (ps -o ppid=,comm=) up to the first ancestor
# that is a GUI app bundle, then read its bundle id from Info.plist. macOS `ps`
# prints the FULL executable path in `comm` (not truncated like Linux), so matching
# "*.app/Contents/MacOS/*" is reliable. $__CFBundleIdentifier / $TERM_PROGRAM are
# fast hints and the fallback when the tree has no .app ancestor (tmux/ssh/nested).
# Verified on this Mac (Apple Terminal host): tree walk climbed
#   zsh -> claude -> -zsh -> login -> Terminal.app  and resolved com.apple.Terminal;
# still resolved correctly with __CFBundleIdentifier unset.
controlling_terminal_bundleid() { # prints bundle id of the hosting GUI app
  local pid=$$ ppid comm appdir
  # 1) Ground truth: nearest GUI-app ancestor in the process tree.
  local n; for n in $(seq 1 16); do
    read -r ppid comm <<<"$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)"
    [ -z "${ppid:-}" ] && break
    case "$comm" in
      */*.app/Contents/MacOS/*)
        appdir="${comm%%.app/*}.app"
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
          "$appdir/Contents/Info.plist" 2>/dev/null && return 0 ;;
    esac
    [ "$ppid" = 1 ] && break
    pid="$ppid"
  done
  # 2) Fallbacks: the bundle id macOS stamped on the login session, then TERM_PROGRAM.
  if [ -n "${__CFBundleIdentifier:-}" ]; then printf '%s\n' "$__CFBundleIdentifier"; return 0; fi
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) echo com.apple.Terminal ;;
    iTerm.app)      echo com.googlecode.iterm2 ;;
    WezTerm)        echo com.github.wez.wezterm ;;
    ghostty)        echo com.mitchellh.ghostty ;;
    WarpTerminal)   echo dev.warp.Warp-Stable ;;
    Tabby)          echo org.tabby ;;
    Hyper)          echo co.zeit.hyper ;;
    vscode)         echo com.microsoft.VSCode ;;   # VS Code integrated terminal
    *) [ -n "${KITTY_WINDOW_ID:-}" ] && echo net.kovidgoyal.kitty \
       || { [ -n "${ALACRITTY_WINDOW_ID:-}" ] && echo org.alacritty || return 1; } ;;
  esac
}

## Map a terminal bundle id -> its Homebrew cask token ("" if none / Apple Terminal)
term_bundleid_to_cask() { # $1 = bundle id
  case "$1" in
    com.googlecode.iterm2)  echo iterm2 ;;
    com.github.wez.wezterm) echo wezterm ;;
    org.alacritty)          echo alacritty ;;
    net.kovidgoyal.kitty)   echo kitty ;;
    com.mitchellh.ghostty)  echo ghostty ;;
    dev.warp.Warp-Stable)   echo warp ;;
    org.tabby)              echo tabby ;;
    co.zeit.hyper)          echo hyper ;;
    com.apple.Terminal)     echo "" ;;   # Apple Terminal ships with macOS, not a cask
    *)                      echo "" ;;
  esac
}

## Best-effort unsaved-changes / open-documents probe — FAILS SAFE
# rc 0  = confidently CLEAN (running, scriptable, no modified documents)
# rc 1  = has unsaved docs OR unknown/unscriptable/timeout/Automation-denied
#          => caller MUST protect. Anything we cannot positively prove clean = unsaved.
# Uses an app-targeted AppleScript get-query wrapped in a self-imposed timeout
# because macOS ships no timeout(1) (verified: neither `timeout` nor `gtimeout`).
# Verified behaviour on this Mac:
#   * `return "CLEAN"` through osa_t -> rc 0 (happy path reachable).
#   * Apps with no AppleScript document suite (Finder, Telegram, and browsers)
#     raise -1728 "Can't get every document" -> osa_t rc != 0 -> PROTECT (fail-safe).
#   * A NOT-running bundle id returns clean WITHOUT launching the app
#     (lsappinfo before/after both empty) — the guard prevents osascript from
#     auto-launching a stopped target.
# NOTE: because unscriptable => protect, `close` is effectively reserved for apps
# that expose a clean document model plus the explicit UPDATETOOLS_CLOSE override —
# which is the intended conservative bias.
osa_t() { # $1 = timeout secs, $2.. = osascript args ; rc 124 on timeout
  local secs="$1"; shift
  local t; t="$(mktemp)"
  osascript "$@" >"$t" 2>/dev/null &
  local p=$! i=0
  while kill -0 "$p" 2>/dev/null; do
    if [ "$i" -ge "$((secs*10))" ]; then
      kill -TERM "$p" 2>/dev/null; wait "$p" 2>/dev/null
      cat "$t"; rm -f "$t"; return 124
    fi
    sleep 0.1; i=$((i+1))
  done
  wait "$p"; local rc=$?; cat "$t"; rm -f "$t"; return "$rc"
}

has_unsaved() { # $1 = bundle id ; rc 1 (protect) unless positively CLEAN
  is_running "$1" || return 0            # not running: nothing to lose, never launch
  local res
  res="$(osa_t 3 -e "tell application id \"$1\"
      set docs to documents
      repeat with d in docs
        if modified of d then return \"DIRTY\"
      end repeat
      return \"CLEAN\"
    end tell")"
  # $? here is osa_t's rc (separate statement, not a `local x=$(...)` — so command
  # substitution status is preserved). Only a clean, error-free run counts as safe.
  [ $? -eq 0 ] && [ "$res" = "CLEAN" ]
}

## Gracefully quit an app by bundle id, with a timeout — NEVER force-kills
# Sends the standard Quit Apple event, then polls LaunchServices until the app
# deregisters. Returns 0 ONLY if it truly exited; on timeout returns 1 and leaves
# the still-running app untouched (no kill/SIGKILL, ever). Call only after
# has_unsaved()==CLEAN so the Quit event won't stall on a save dialog.
# Verified SAFE path on this Mac: against not-running com.google.Chrome -> rc 0
# immediately, Chrome NOT launched (lsappinfo empty before & after). Running-quit
# path deliberately NOT exercised.
graceful_quit() { # $1 = bundle id, $2 = timeout secs (default 20)
  local bid="$1" secs="${2:-20}" i=0
  is_running "$bid" || return 0                 # already gone
  osascript -e "tell application id \"$bid\" to quit" >/dev/null 2>&1
  while [ "$i" -lt "$((secs*4))" ]; do          # poll every 0.25s
    is_running "$bid" || return 0
    sleep 0.25; i=$((i+1))
  done
  is_running "$bid" && return 1 || return 0     # timed out, still up => failure
}

## Relaunch an app by bundle id
# `open -b <id>` starts the app via LaunchServices from its bundle id alone (no path
# needed). `-g` keeps it in the background so the relaunch doesn't steal focus from
# the user's foreground work; drop -g if you want it to come forward.
# Verified on this Mac: /usr/bin/open exists and documents `-b <bundle identifier>`
# and `-g`. Not executed against a real app (would launch it; out of scope for this
# inspection-only pass).
relaunch_app() { # $1 = bundle id
  open -g -b "$1" 2>/dev/null
}

## classify_cask <token> -> prints exactly one of: skip | close | protect
# Depends on the helpers above: cask_to_apps, app_to_bundleid, is_running,
# controlling_terminal_bundleid, has_unsaved (+ osa_t), in_list.
#
# Precedence (highest first):
#   0.  unresolvable to an installed app (font / CLI-only cask / missing) -> skip
#   0b. resolvable but NOT running                                         -> upgrade
#   b.  bundle id == the terminal hosting THIS shell -> protect  (INVIOLABLE:
#       checked before the force-close list, so nothing can quit our terminal)
#   a.  token in UPDATETOOLS_CLOSE (force-close list) -> close (beats c/d/e)
#   c.  token in UPDATETOOLS_PROTECT                   -> protect
#   d.  unsaved / unknown / unscriptable document state -> protect  (fail-safe)
#   e.  token in a risky CATEGORY denylist            -> protect
#   f.  otherwise                                     -> close
#
# Verified on this Mac (Apple Terminal host, macOS 26.5.2, arm64):
#   font-jetbrains-mono, android-commandlinetools -> skip
#   google-chrome / utm / visual-studio-code (not running) -> upgrade
#   telegram (RUNNING): base -> protect (unscriptable for documents, -1728, so
#     the unsaved-unknown fail-safe fires); UPDATETOOLS_CLOSE=telegram -> close;
#     UPDATETOOLS_PROTECT=telegram -> protect. The host terminal stays `protect`
#     even if its own token is put in UPDATETOOLS_CLOSE.

in_list() { # $1 = needle, $2 = space/comma separated haystack
  local needle="$1" hay="$2" x
  for x in ${hay//,/ }; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

# ---- Curated risky-category cask denylists (running instances get protected) ----
UT_CAT_BROWSER="google-chrome google-chrome@canary google-chrome@beta chromium firefox firefox@developer-edition firefox@nightly librewolf waterfox brave-browser microsoft-edge microsoft-edge@beta arc vivaldi opera opera-gx tor-browser zen orion thorium min duckduckgo"
UT_CAT_EDITOR_IDE="visual-studio-code visual-studio-code@insiders vscodium cursor windsurf zed sublime-text bbedit textmate macvim neovide nova fleet positron atom android-studio jetbrains-toolbox intellij-idea intellij-idea-ce pycharm pycharm-ce webstorm goland clion rider phpstorm rubymine datagrip appcode dataspell rustrover xcode"
UT_CAT_VM_CONTAINER="docker docker-desktop orbstack rancher podman-desktop utm virtualbox vmware-fusion parallels multipass vagrant veertu-anka lima-desktop"
UT_CAT_MEETING_RECORDING="zoom microsoft-teams slack webex discord skype obs screenflow camtasia loom cleanshot kap screen-studio descript screencastify riverside"
UT_CAT_PASSWORD_MANAGER="1password 1password@beta 1password-cli bitwarden keepassxc keepassx dashlane enpass keeper-password-manager nordpass protonpass lastpass strongbox"
UT_CAT_BACKUP="carbon-copy-cloner superduper arq backblaze chronosync get-backup-pro resilio-sync duplicati restic-browser"

is_risky_token() { # $1 = cask token
  in_list "$1" "$UT_CAT_BROWSER"          || in_list "$1" "$UT_CAT_EDITOR_IDE"       || \
  in_list "$1" "$UT_CAT_VM_CONTAINER"     || in_list "$1" "$UT_CAT_MEETING_RECORDING" || \
  in_list "$1" "$UT_CAT_PASSWORD_MANAGER" || in_list "$1" "$UT_CAT_BACKUP"
}

# Resolve the hosting terminal once (used by branch b). Do it at load time so we
# never misclassify our own terminal because of a transient ps read.
UT_TERM_BID="$(controlling_terminal_bundleid 2>/dev/null)"

classify_cask() { # $1 = cask token -> echoes skip|close|protect
  local token="$1" app bid
  app="$(cask_to_apps "$token" | head -n1)"
  [ -n "$app" ] || { echo skip; return; }          # 0. no app artifact -> skip
  bid="$(app_to_bundleid "$app")"
  [ -n "$bid" ] || { echo skip; return; }          # 0. installed app not found -> skip

  is_running "$bid" || { echo upgrade;  return; }    # 0b. not running -> handled elsewhere

  # The terminal hosting THIS run is inviolable and checked FIRST: quitting it
  # would SIGHUP the script mid-run (and close the user's other tabs). Not even
  # UPDATETOOLS_CLOSE may select it — you cannot upgrade a terminal cask by
  # killing the shell doing the upgrade anyway.
  [ -n "$UT_TERM_BID" ] && [ "$bid" = "$UT_TERM_BID" ] && { echo protect; return; }  # b. our terminal (never seppuku)
  in_list "$token" "${UPDATETOOLS_CLOSE:-}"   && { echo close;   return; }  # a. force-close (beats every other protect rule)
  in_list "$token" "${UPDATETOOLS_PROTECT:-}" && { echo protect; return; }  # c. protect list
  has_unsaved "$bid"                          || { echo protect; return; }  # d. unsaved/unknown
  is_risky_token "$token"                     && { echo protect; return; }  # e. risky category
  echo close                                                                # f. safe to quit
}

# ===========================================================================
# Changelog lookup — curated, human-facing release-notes URLs.
# ===========================================================================

# Normalise a brew token / formula / cli name to a changelog key:
# lowercase and drop any "@version" suffix (node@22 -> node).
ut_normalize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/@.*$//'; }

# ut_changelog_lookup <normalized-key> -> prints "display<TAB>url" ("" url if none).
ut_changelog_lookup() {
  local d="" u=""
  case "$1" in
    1password) d="1Password"; u="https://releases.1password.com/mac/stable/" ;;
    agy) d="Google Antigravity CLI"; u="https://antigravity.google/changelog" ;;
    arc) d="Arc (The Browser Company)"; u="https://resources.arc.net/hc/en-us/articles/20498293324823-Arc-for-macOS-2024-2026-Release-Notes" ;;
    asdf) d="asdf"; u="https://github.com/asdf-vm/asdf/releases" ;;
    aws) d="AWS CLI v2"; u="https://github.com/aws/aws-cli/blob/v2/CHANGELOG.rst" ;;
    az) d="Azure CLI (az)"; u="https://learn.microsoft.com/en-us/cli/azure/release-notes-azure-cli" ;;
    brave-browser) d="Brave Browser"; u="https://brave.com/latest/" ;;
    brew) d="Homebrew (brew)"; u="https://github.com/Homebrew/brew/releases" ;;
    bun) d="Bun"; u="https://github.com/oven-sh/bun/releases" ;;
    cargo-update) d="cargo-update (cargo install-update)"; u="https://github.com/nabijaczleweli/cargo-update/releases" ;;
    claude) d="Claude Code"; u="https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md" ;;
    codex) d="OpenAI Codex CLI"; u="https://github.com/openai/codex/releases" ;;
    composer) d="Composer"; u="https://github.com/composer/composer/blob/main/CHANGELOG.md" ;;
    conda) d="conda"; u="https://docs.conda.io/projects/conda/en/latest/release-notes.html" ;;
    deno) d="Deno"; u="https://github.com/denoland/deno/releases" ;;
    discord) d="Discord"; u="https://discord.com/blog" ;;
    docker) d="Docker Desktop"; u="https://docs.docker.com/desktop/release-notes/" ;;
    dotnet) d=".NET SDK / runtime"; u="https://github.com/dotnet/core/tree/main/release-notes" ;;
    figma) d="Figma"; u="https://help.figma.com/hc/en-us/sections/40228515750039-Release-notes" ;;
    firefox) d="Mozilla Firefox"; u="https://www.mozilla.org/en-US/firefox/releases/" ;;
    flutter) d="Flutter"; u="https://docs.flutter.dev/release/release-notes" ;;
    fnm) d="fnm"; u="https://github.com/Schniz/fnm/releases" ;;
    gcloud) d="Google Cloud CLI (gcloud)"; u="https://cloud.google.com/sdk/docs/release-notes" ;;
    gem) d="RubyGems"; u="https://github.com/rubygems/rubygems/releases" ;;
    gh) d="GitHub CLI"; u="https://github.com/cli/cli/releases" ;;
    ghostty) d="Ghostty"; u="https://ghostty.org/docs/install/release-notes" ;;
    go) d="Go"; u="https://go.dev/doc/devel/release" ;;
    google-chrome) d="Google Chrome"; u="https://chromereleases.googleblog.com/" ;;
    helm) d="Helm"; u="https://github.com/helm/helm/releases" ;;
    iterm2) d="iTerm2"; u="https://iterm2.com/downloads.html" ;;
    krew) d="Krew (kubectl plugin manager)"; u="https://github.com/kubernetes-sigs/krew/releases" ;;
    kubectl) d="kubectl (Kubernetes)"; u="https://github.com/kubernetes/kubernetes/tree/master/CHANGELOG" ;;
    mas) d="mas (Mac App Store CLI)"; u="https://github.com/mas-cli/mas/releases" ;;
    mise) d="mise"; u="https://github.com/jdx/mise/releases" ;;
    node) d="Node.js"; u="https://github.com/nodejs/node/releases" ;;
    nodenv) d="nodenv"; u="https://github.com/nodenv/nodenv/releases" ;;
    notion) d="Notion"; u="https://www.notion.com/releases" ;;
    npm) d="npm"; u="https://github.com/npm/cli/releases" ;;
    npx) d="npx"; u="https://github.com/npm/cli/releases" ;;
    obsidian) d="Obsidian"; u="https://obsidian.md/changelog/" ;;
    orbstack) d="OrbStack"; u="https://docs.orbstack.dev/release-notes" ;;
    pipx) d="pipx"; u="https://github.com/pypa/pipx/blob/main/CHANGELOG.md" ;;
    pnpm) d="pnpm"; u="https://github.com/pnpm/pnpm/releases" ;;
    pyenv) d="pyenv"; u="https://github.com/pyenv/pyenv/releases" ;;
    raycast) d="Raycast"; u="https://www.raycast.com/changelog" ;;
    rbenv) d="rbenv"; u="https://github.com/rbenv/rbenv/releases" ;;
    rectangle) d="Rectangle"; u="https://github.com/rxhanson/Rectangle/releases" ;;
    rustup) d="rustup"; u="https://github.com/rust-lang/rustup/blob/master/CHANGELOG.md" ;;
    slack) d="Slack"; u="https://slack.com/release-notes/mac" ;;
    spotify) d="Spotify"; u="https://community.spotify.com/t5/Desktop-Windows/Changelog-Release-Notes/td-p/5084193" ;;
    supabase) d="Supabase CLI"; u="https://github.com/supabase/cli/releases" ;;
    tfenv) d="tfenv"; u="https://github.com/tfutils/tfenv/releases" ;;
    tldr) d="tldr-pages"; u="https://github.com/tldr-pages/tldr/releases" ;;
    uv) d="uv"; u="https://github.com/astral-sh/uv/releases" ;;
    vercel) d="Vercel CLI"; u="https://github.com/vercel/vercel/releases" ;;
    visual-studio-code) d="Visual Studio Code"; u="https://code.visualstudio.com/updates" ;;
    volta) d="Volta"; u="https://github.com/volta-cli/volta/releases" ;;
    wezterm) d="WezTerm"; u="https://wezterm.org/changelog.html" ;;
    yarn) d="Yarn"; u="https://github.com/yarnpkg/berry/releases" ;;
    zoom) d="Zoom (Workplace app)"; u="https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0068891" ;;
  esac
  printf '%s\t%s' "$d" "$u"
}

# ===========================================================================
# Smart cask upgrade
# ===========================================================================
# Replaces the old blanket `brew upgrade --cask --no-quit`. For every OUTDATED
# cask it asks classify_cask() what to do, then acts per verdict:
#   skip     — cask ships no .app (font / CLI-only): upgrade in place.
#   upgrade  — app installed but not running: upgrade in place (nobody using it).
#   protect  — app running but unsafe to close (terminal / unsaved / risky /
#              user list): stage with --no-quit; the new version applies on the
#              next launch. Nothing is force-closed, ever.
#   close    — app running and provably safe to quit: quit it gracefully,
#              upgrade, then relaunch. Only reached for scriptable apps with a
#              clean document model, or via the UPDATETOOLS_CLOSE override.
#
# Toggles:  CLOSE_APPS=0 / --no-close   -> treat every `close` as `protect`.
#           BREW_CASK_SKIP="a b"        -> casks needing interactive sudo (kept
#                                          out of the automated run, reported).
#           UPDATETOOLS_CLOSE / UPDATETOOLS_PROTECT — per-token overrides.
ut_upgrade_casks_smart() {
  have brew || { echo "Homebrew not found; skipping casks."; return 0; }
  local greedy_flag="${1:-}"
  local skip_list="${BREW_CASK_SKIP-stats aldente}"
  local close_enabled="${CLOSE_APPS:-1}"
  local skip_re token verdict app bid
  local n_up=0 n_close=0 n_protect=0 n_skip=0
  local manual=()

  skip_re="$(printf '%s' "$skip_list" | tr ', ' '\n\n' | sed '/^$/d' | paste -sd'|' -)"

  while IFS= read -r token; do
    [ -z "$token" ] && continue

    # Casks that need an interactive sudo password (privileged launchctl helper)
    # can't be answered in an automated run — report them for manual upgrade.
    if [ -n "$skip_re" ] && printf '%s\n' "$token" | grep -qxE "$skip_re"; then
      manual+=("$token"); n_skip=$((n_skip+1)); continue
    fi

    verdict="$(classify_cask "$token")"
    [ "$close_enabled" = "1" ] || { [ "$verdict" = "close" ] && verdict="protect"; }

    case "$verdict" in
      close)
        app="$(cask_to_apps "$token" | head -n1)"
        bid="$(app_to_bundleid "$app" 2>/dev/null)"
        echo ">> $token: running & safe to close — quitting, upgrading, relaunching"
        if [ -n "$bid" ] && graceful_quit "$bid" 20; then
          brew upgrade --cask "$token" || true
          relaunch_app "$bid"
          n_close=$((n_close+1))
        else
          echo "   quit did not complete (unsaved work / not scriptable) — staging instead"
          brew upgrade --cask --no-quit "$token" || true
          n_protect=$((n_protect+1))
        fi
        ;;
      protect)
        echo ">> $token: running & protected — staging (new version applies on next launch)"
        brew upgrade --cask --no-quit "$token" || true
        n_protect=$((n_protect+1))
        ;;
      upgrade)
        echo ">> $token: not running — upgrading in place"
        brew upgrade --cask --no-quit "$token" || true
        n_up=$((n_up+1))
        ;;
      *)  # skip = no app artifact (font / CLI-only cask)
        echo ">> $token: no app bundle — upgrading in place"
        brew upgrade --cask --no-quit "$token" || true
        n_up=$((n_up+1))
        ;;
    esac
  done <<< "$(brew outdated --cask $greedy_flag --quiet 2>/dev/null)"

  if [ "${#manual[@]}" -gt 0 ]; then
    echo "Skipped casks needing interactive sudo — upgrade manually when present:"
    local c; for c in "${manual[@]}"; do echo "  brew upgrade --cask $c"; done
  fi
  echo "casks: $n_up upgraded · $n_close closed+relaunched · $n_protect staged · $n_skip skipped(manual)"
  return 0
}

# ===========================================================================
# Version report -> ~/Desktop/updatetools-report-*.html
# ===========================================================================
# ut_report_begin  captures the "before" state (once, idempotent) AFTER
#   `brew update` and BEFORE any upgrade, into files under UT_REPORT_DIR.
# ut_report_finish captures the "after" state, diffs, writes the HTML report,
#   optionally opens it, and records the path in UT_LASTREPORT.
# $$ is stable across the step subshells the TUI spawns, so both halves agree
# on these paths even when run from different subshells.
UT_REPORT_DIR="${TMPDIR:-/tmp}/updatetools-report-$$"
UT_LASTREPORT="${TMPDIR:-/tmp}/updatetools-lastreport-$$"

# First dotted-numeric run from a noisy --version line (go1.26.5 -> 1.26.5).
_ut_ver() {
  awk '{
    if (match($0, /[0-9]+(\.[0-9]+)+([._+-][0-9A-Za-z.]+)?/))
      print substr($0, RSTART, RLENGTH);
    else { gsub(/^[ \t]+|[ \t]+$/, ""); print }
  }'
}

# Emit "name<TAB>version" for standalone CLIs (those not tracked via brew casks).
ut_capture_cli_versions() {
  local spec cmd args raw
  for spec in \
    "node|-v" "npm|-v" "pnpm|-v" "yarn|-v" "bun|-v" \
    "deno|--version" "uv|--version" "cargo|--version" "go|version" \
    "gem|--version" "claude|--version" "codex|--version" "agy|--version" \
    "gh|--version" "supabase|--version" "vercel|--version" "mas|version"; do
    cmd="${spec%%|*}"; args="${spec#*|}"
    have "$cmd" || continue
    raw="$("$cmd" $args 2>/dev/null | head -1)"
    [ -n "$raw" ] || continue
    printf '%s\t%s\n' "$cmd" "$(printf '%s' "$raw" | _ut_ver)"
  done
}

# Parse one `brew outdated --verbose` line ("name (old...) OP new") -> record.
_ut_parse_outdated() {  # $1 line, $2 kind
  local l="$1" kind="$2" name old new
  name="${l%% *}"
  # old sits inside "(...)": for a multi-install list "(1.0, 1.1)" keep the first
  # entry, but split only on the ", " list separator so a single "version,build"
  # cask version (e.g. "116.5.5,538461") keeps its build — matching `new`, which
  # keeps the whole last token, so old->new renders symmetrically.
  old="${l#*\(}"; old="${old%%)*}"; old="${old%%, *}"
  new="${l##* }"
  printf '%s|%s|%s|%s\n' "$name" "$old" "$new" "$kind"
}

ut_capture_brew_before() {
  have brew || return 0
  brew outdated --formula --verbose 2>/dev/null | while IFS= read -r l; do
    [ -n "$l" ] && _ut_parse_outdated "$l" formula
  done
  brew outdated --cask --greedy --verbose 2>/dev/null | while IFS= read -r l; do
    [ -n "$l" ] && _ut_parse_outdated "$l" cask
  done
}

ut_report_begin() {
  [ "${MAKE_REPORT:-1}" = "1" ] || return 0
  mkdir -p "$UT_REPORT_DIR" 2>/dev/null || return 0
  [ -f "$UT_REPORT_DIR/.began" ] && return 0   # idempotent: only the first call captures
  : > "$UT_REPORT_DIR/.began"
  ut_capture_brew_before   > "$UT_REPORT_DIR/brew" 2>/dev/null || true
  ut_capture_cli_versions  > "$UT_REPORT_DIR/cli"  2>/dev/null || true
  return 0
}

# Look up display + url for a name, appending "key|display|old|new|url" to a file.
_ut_emit_card() {  # $1 rawname, $2 old, $3 new, $4 out_file
  local nkey dl disp url
  nkey="$(ut_normalize "$1")"
  dl="$(ut_changelog_lookup "$nkey")"
  disp="${dl%%$'\t'*}"; url="${dl#*$'\t'}"
  [ -n "$disp" ] || disp="$1"
  printf '%s|%s|%s|%s|%s\n' "$nkey" "$disp" "$2" "$3" "$url" >> "$4"
}

ut_generate_report() {  # $1 = optional output path
  [ "${MAKE_REPORT:-1}" = "1" ] || return 0
  local out="${1:-}"
  [ -n "$out" ] || out="$HOME/Desktop/updatetools-report-$(date '+%Y%m%d-%H%M%S').html"
  local data data2 after_brew after_cli
  data="$(mktemp)"; data2="$(mktemp)"

  # brew: a formula/cask that was outdated before and is no longer outdated now
  # was successfully upgraded this run.
  if [ -f "$UT_REPORT_DIR/brew" ] && have brew; then
    after_brew="$( { brew outdated --quiet 2>/dev/null; \
                     brew outdated --cask --greedy --quiet 2>/dev/null; } )"
    while IFS='|' read -r name old new kind; do
      [ -n "$name" ] || continue
      printf '%s\n' "$after_brew" | grep -qxF "$name" && continue   # still outdated
      _ut_emit_card "$name" "$old" "$new" "$data"
    done < "$UT_REPORT_DIR/brew"
  fi

  # cli: version string changed between before and after. Appended AFTER brew so
  # that on a key collision (e.g. gh formula vs gh cli) the cli entry wins dedup.
  if [ -f "$UT_REPORT_DIR/cli" ]; then
    after_cli="$(mktemp)"
    ut_capture_cli_versions > "$after_cli" 2>/dev/null || true
    while IFS=$'\t' read -r ckey cold; do
      [ -n "$ckey" ] || continue
      local cnew
      cnew="$(grep -m1 "^$ckey"$'\t' "$after_cli" 2>/dev/null | cut -f2-)"
      [ -n "$cnew" ] && [ "$cnew" != "$cold" ] && _ut_emit_card "$ckey" "$cold" "$cnew" "$data"
    done < "$UT_REPORT_DIR/cli"
    rm -f "$after_cli"
  fi

  # Dedup by key (field 1), keeping the last occurrence (cli beats brew).
  awk -F'|' '{ rows[$1]=$0; seq[$1]=NR } END { for (k in rows) print seq[k]"\t"rows[k] }' \
      "$data" | sort -n | cut -f2- > "$data2"

  generate_html_report "$out" "$data2" >/dev/null
  printf '%s' "$out" > "$UT_LASTREPORT"
  rm -f "$data" "$data2"
  rm -rf "$UT_REPORT_DIR" 2>/dev/null
  printf '%s\n' "$out"
}

# TUI/plain convenience: generate, then open unless disabled.
ut_report_finish() {
  [ "${MAKE_REPORT:-1}" = "1" ] || return 0
  local path; path="$(ut_generate_report)"
  echo "Report: $path"
  if [ "${OPEN_REPORT:-1}" = "1" ] && [ -n "$path" ] && [ -f "$path" ]; then
    open "$path" 2>/dev/null || true
  fi
  return 0
}

# ===========================================================================
# HTML report document generator (researched, self-contained, escaped)
# ===========================================================================
# generate_html_report OUT_PATH DATA_FILE
#
# DATA_FILE: one "key|display|old|new|changelog_url" record per updated tool.
#   - Fields are pipe-separated; the changelog_url (5th field) may itself
#     contain '|' (the remainder of the line is taken as the URL).
#   - An empty 5th field (or a trailing '|' with nothing after) means
#     "no known changelog URL" and renders a card with no link.
# Every dynamic value is HTML-escaped (& < > " ').
# Robust under `set -u`; zero updated tools renders an empty-state card.
generate_html_report() {
  local out_path=${1:?generate_html_report: OUT_PATH required}
  local data_file=${2:?generate_html_report: DATA_FILE required}

  if [ ! -f "$data_file" ]; then
    printf 'generate_html_report: data file not found: %s\n' "$data_file" >&2
    return 1
  fi

  # --- HTML-escape a single string (order matters: & first) ---
  html_escape() {
    local s=${1-}
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    s=${s//\"/&quot;}
    s=${s//\'/&#39;}
    printf '%s' "$s"
  }

  local today
  today=$(date '+%Y-%m-%d')

  local cards="" count=0
  local key display old new url
  local d_e o_e n_e u_e link_html

  # `|| [ -n "$key" ]` catches a final line without a trailing newline.
  while IFS='|' read -r key display old new url || [ -n "${key:-}" ]; do
    # Skip fully blank lines.
    if [ -z "${key:-}" ] && [ -z "${display:-}" ] && [ -z "${old:-}" ] \
       && [ -z "${new:-}" ] && [ -z "${url:-}" ]; then
      continue
    fi

    # Ensure every field is defined under `set -u`.
    display=${display:-}
    old=${old:-}
    new=${new:-}
    url=${url:-}

    d_e=$(html_escape "$display")
    o_e=$(html_escape "$old")
    n_e=$(html_escape "$new")

    # Trim surrounding whitespace from the URL before the empty check.
    url=${url#"${url%%[![:space:]]*}"}
    url=${url%"${url##*[![:space:]]}"}

    if [ -n "$url" ]; then
      u_e=$(html_escape "$url")
      link_html="      <a class=\"changelog\" href=\"$u_e\" target=\"_blank\" rel=\"noopener noreferrer\">View changelog <span class=\"ext\">&#8599;</span></a>"
    else
      link_html="      <span class=\"no-changelog\">no changelog available</span>"
    fi

    cards+="    <article class=\"card\">
      <div class=\"card-name\">$d_e</div>
      <div class=\"ver\">
        <span class=\"old\">$o_e</span>
        <span class=\"arrow\">-&gt;</span>
        <span class=\"new\">$n_e</span>
      </div>
$link_html
    </article>
"
    count=$((count + 1))
  done < "$data_file"

  local summary
  if [ "$count" -eq 0 ]; then
    summary="No tools updated"
    cards="    <div class=\"empty\">Everything is already up to date.</div>"
  elif [ "$count" -eq 1 ]; then
    summary="1 tool updated"
  else
    summary="$count tools updated"
  fi

  local date_e summary_e
  date_e=$(html_escape "$today")
  summary_e=$(html_escape "$summary")

  # --- Emit the document. Placeholders: {{DATE}} {{SUMMARY}} {{CARDS}} ---
  # Quoted heredoc keeps the CSS literal; dynamic values are injected via printf.
  {
    cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
HTML_HEAD
    printf '<title>updatetools \xc2\xb7 %s</title>\n' "$date_e"
    cat <<'HTML_CSS'
<style>
  :root{
    --bg:#0e1113; --bg-2:#12161a; --card:#161a1d; --card-hover:#1a1f23;
    --border:#232a2e; --border-strong:#2d363b;
    --text:#d8dee2; --dim:#6b7680; --muted:#8a949c;
    --teal:#2bd4c0; --teal-dim:#1f9e90; --teal-glow:rgba(43,212,192,.14);
    --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
    --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
  }
  *{box-sizing:border-box}
  html,body{margin:0;padding:0}
  body{
    background:radial-gradient(1200px 600px at 50% -10%,var(--bg-2),var(--bg)) fixed;
    color:var(--text); font-family:var(--sans);
    -webkit-font-smoothing:antialiased; line-height:1.5;
    padding:48px 20px 72px;
  }
  .wrap{max-width:760px;margin:0 auto}
  header{margin-bottom:28px}
  .title{font-size:26px; font-weight:700; letter-spacing:-.01em; margin:0;
    display:flex; align-items:baseline; gap:12px; flex-wrap:wrap;}
  .title .brand{color:var(--text)}
  .title .sep{color:var(--dim); font-weight:400}
  .title .date{font-family:var(--mono); font-size:15px; color:var(--teal);
    background:var(--teal-glow); padding:2px 10px; border-radius:999px;}
  .summary{margin-top:10px; color:var(--muted); font-size:14px;
    display:flex; align-items:center; gap:8px;}
  .summary .dot{width:7px;height:7px;border-radius:50%;background:var(--teal);
    box-shadow:0 0 10px var(--teal)}
  .cards{display:flex; flex-direction:column; gap:14px; margin-top:26px}
  .card{background:linear-gradient(180deg,var(--card),var(--bg-2));
    border:1px solid var(--border); border-radius:14px; padding:18px 20px;
    transition:border-color .15s ease, transform .15s ease;
    position:relative; overflow:hidden;}
  .card::before{content:""; position:absolute; left:0; top:0; bottom:0; width:3px;
    background:linear-gradient(180deg,var(--teal),var(--teal-dim)); opacity:.7;}
  .card:hover{border-color:var(--border-strong); transform:translateY(-1px)}
  .card-name{font-size:16px; font-weight:600; color:var(--text);
    margin-bottom:12px; letter-spacing:-.005em;}
  .ver{font-family:var(--mono); font-size:14px; display:flex; align-items:center;
    gap:12px; flex-wrap:wrap; margin-bottom:14px;}
  .ver .old{color:var(--dim); text-decoration:line-through;
    text-decoration-color:var(--dim); text-decoration-thickness:1px;}
  .ver .arrow{color:var(--muted); font-weight:600}
  .ver .new{color:var(--teal); font-weight:700; background:var(--teal-glow);
    padding:2px 9px; border-radius:6px;}
  .changelog{display:inline-flex; align-items:center; gap:6px; font-size:13px;
    font-weight:600; text-decoration:none; color:var(--teal);
    border:1px solid var(--teal-dim); padding:7px 13px; border-radius:9px;
    transition:background .15s ease;}
  .changelog:hover{background:var(--teal-glow)}
  .changelog .ext{font-size:12px}
  .no-changelog{font-size:12px; color:var(--dim); font-style:italic;}
  .empty{text-align:center; color:var(--muted); padding:48px 20px;
    border:1px dashed var(--border-strong); border-radius:14px; font-size:14px;}
  footer{margin-top:40px; text-align:center; color:var(--dim); font-size:12px;
    font-family:var(--mono)}
</style>
</head>
<body>
  <div class="wrap">
    <header>
HTML_CSS
    printf '      <h1 class="title"><span class="brand">updatetools</span> <span class="sep">\xc2\xb7</span> <span class="date">%s</span></h1>\n' "$date_e"
    printf '      <div class="summary"><span class="dot"></span>%s</div>\n' "$summary_e"
    cat <<'HTML_MID'
    </header>
    <div class="cards">
HTML_MID
    printf '%s' "$cards"
    cat <<'HTML_TAIL'
    </div>
    <footer>generated by updatetools</footer>
  </div>
</body>
</html>
HTML_TAIL
  } > "$out_path"

  unset -f html_escape
  printf 'Wrote %s (%s updated)\n' "$out_path" "$count"
}
