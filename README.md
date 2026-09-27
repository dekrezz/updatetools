<div align="center">
  <img src="assets/updatetools-mark.svg" width="112" alt="updatetools logo">

  <h1>updatetools</h1>

  <p><strong>Update everything on your Mac with one command.</strong></p>

  <p>macOS, App Store apps, Homebrew apps, apps from DMGs and developer tools —
  in one run, without closing what you are working on.</p>

  <p>
    <a href="https://github.com/dekrezz/updatetools/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/dekrezz/updatetools?style=flat-square&color=7AA2FF"></a>
    <img alt="macOS" src="https://img.shields.io/badge/macOS-12%2B-11151D?style=flat-square&logo=apple&logoColor=white">
    <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/license-Apache_2.0-67E8C4?style=flat-square"></a>
  </p>
</div>

## Install

```bash
brew tap dekrezz/updatetools https://github.com/dekrezz/updatetools
brew trust --formula dekrezz/updatetools/updatetools
brew install updatetools
```

Then run:

```bash
updatetools
```

A live dashboard opens in your browser. Pick what to update, press **Start**.

## What it updates

- 🍎 **macOS** system updates — Safari, security data, Command Line Tools (`softwareupdate`)
- 🛍 **App Store** apps (`mas`)
- 🍺 **Homebrew** formulas and apps (`brew`)
- 📦 **Apps installed from DMGs** — verified, signed replacements only
- 🟢 **Node** global packages (`npm`, `pnpm`)
- 🐍 **Python** tools (`uv`)
- 🦀 **Rust** binaries (`cargo`)
- 🤖 **AI & dev CLIs** — Claude Code, Codex, Antigravity, Supabase, Vercel, `gh` extensions
- 🧑‍💻 **VS Code** extensions

Tools you don't have are skipped. At the end you see exactly what changed.

## Safe by default

- **Never interrupts your work.** Apps that are open or have unsaved changes get the update on next launch.
- **Never restarts your Mac.** Updates that need a restart are listed, not installed.
- **Root only where needed.** sudo is dropped before npm, cargo, uv and other package updates run. [Details](SECURITY.md#what-updatetools-does-on-your-mac)
- **Nothing to clean up.** Logs and the report are temporary unless you pass `--debug`.

## Common options

```bash
updatetools --plain              # text output, no browser
updatetools --only homebrew,macos
updatetools --skip appstore
updatetools --schedule 1d        # run every day in the background
```

All flags, step keys and details: **[docs/USAGE.md](docs/USAGE.md)**.

## License

[Apache 2.0](LICENSE)
