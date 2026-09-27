# Security Policy

## Supported versions

Security fixes ship in the latest release (the tag the Homebrew formula pins,
which `--self-update` installs). Older releases are not supported.

## What updatetools does on your Mac

`updatetools` is one readable Bash file with no obfuscation. Run it as your
normal user, never as `sudo updatetools`.

**sudo is held only while it is needed.** The password is asked for only if a
step that may need root is enabled: Homebrew (pkg-based casks), apps from
DMGs, App Store (`mas`) or macOS (`softwareupdate`). Those steps run first.
Then the run calls `sudo -k` and the dashboard forgets the password, and only
after that do npm, pnpm, uv, cargo and the CLI updaters start. Their install
scripts run without cached root. If one of them asks for a password anyway, the
dashboard shows the prompt to you; it is never answered automatically.

**The password** is typed into the local dashboard, kept in memory for the
privileged steps, and handed to `sudo` through a `0600` temporary file that is
deleted as soon as it is read. It is never logged.

**The dashboard** listens on `127.0.0.1` only, behind a random per-run token
exchanged for an `HttpOnly` cookie and a `Host` check. It stops when the tab
closes.

**Network access**, beyond what each package manager does itself:

- `--self-update`: `Formula/updatetools.rb` from this repository, then the
  release tarball it pins, verified against its sha256;
- apps from DMGs: the download URL and sha256 from the Homebrew cask;
- report icons: `icons.duckduckgo.com` (by the vendor's host name) and
  `github.com/<org>.png`, cached in `~/.cache/updatetools/icons`.

**Background processes:** an update for an open DMG app is left to a one-shot
helper that waits for you to quit the app, swaps the bundle atomically, and
deletes itself. The swap helper is compiled locally from source embedded in the
script (`xcrun clang`). A LaunchAgent is installed only by `--schedule`.

**What it does not protect against:**

- **Compromised packages.** updatetools runs each package manager's own update
  command and trusts what that registry serves. A malicious npm, PyPI, crates or
  Homebrew release gets installed like any other update. Scoping sudo limits
  what such a package can do during the run; it does not detect it.
- **A compromised maintainer account.** `--self-update` checks that the release
  matches the sha256 in the formula, but both come from this repository. That
  prevents installing unreleased commits and corrupted downloads; it does not
  prevent a malicious release. The same is true for `brew install`.

## Reporting a vulnerability

Do not disclose suspected vulnerabilities in a public issue, discussion, or
pull request.

Use GitHub's private
[Report a vulnerability](https://github.com/dekrezz/updatetools/security/advisories/new)
form instead. Include:

- the affected commit or version;
- the macOS version and relevant environment details;
- clear reproduction steps;
- the expected and observed behavior;
- the potential impact; and
- a suggested fix, if you have one.

Remove passwords, tokens, personal data, and other secrets from logs before
attaching them.

You should receive an acknowledgement within 72 hours and a status update
within seven days. Please allow time for a fix before publishing details.

## Security-sensitive areas

Reports are especially useful when they involve:

- privilege escalation or sudo credential handling;
- command or shell injection;
- update download integrity and code-signing verification;
- unsafe application replacement or deferred update behavior;
- insecure temporary files, permissions, or cleanup; or
- unintended disclosure of local system information.
