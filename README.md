<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Claude Island</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Claude Code CLI sessions.
    <br />
    <br />
    <a href="https://github.com/z3roll/claude-island/releases/latest" target="_blank" rel="noopener noreferrer"><img src="https://img.shields.io/github/v/release/z3roll/claude-island?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" /></a>&nbsp;<a href="https://github.com/z3roll/claude-island/releases" target="_blank" rel="noopener noreferrer"><img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/z3roll/claude-island/total?style=rounded&color=white&labelColor=000000"></a>
  </p>
</div>

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple Claude Code sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Terminal Focus** — Activate and restore minimized terminal windows from the notch
- **Auto-Setup** — Hooks install automatically on first launch
- 🔴 **NEW!** **Token Usage** — 5h/7d usage percentage with recovery time
- 🔴 **NEW!** **Model & Context** — Per-session model name and context window percentage
- 🔴 **NEW!** **Companion Pet** — Renders your Claude companion as animated ASCII art

## Requirements

- macOS 15.6+
- Claude Code CLI

## Install

Download the latest release DMG, or build from source:

```bash
./scripts/build.sh
```

## How It Works

Claude Island installs hooks into `~/.claude/hooks/` that communicate session state via a Unix socket. The app listens for events and displays them in the notch overlay.

When Claude needs permission to run a tool, the notch expands with approve/deny buttons — no need to switch to the terminal.

## Credits

This project is based on [ZhaoChaoqun/claude-island](https://github.com/ZhaoChaoqun/claude-island), which is a fork of the original [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island) (v1.2, Dec 2025).

## License

Apache 2.0 — see [LICENSE.md](LICENSE.md).
