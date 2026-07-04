# 🏎️ Redline

Redline is a physical gear-shifter for Claude Code. It's a floating H-pattern shifter that drives `/model`, `/effort`, and `/fast` in a running session — plus live instrumentation: a fuel gauge for the context window and utilization bars for your rate limits. Switch models by dragging a stick, not by typing.

- **`shift-gui.ps1`** — **Windows** GUI (PowerShell + WinForms). Types the command into your terminal.
- **`redline-mac.swift`** — **macOS** GUI (Swift + AppKit). Writes the command through the terminal's own AppleScript API (iTerm2 / Terminal.app) — no keystroke injection, no Accessibility prompt.

> A Codex CLI version is in progress on the [`experimental`](https://github.com/Aaryanxvi/Redline/tree/experimental) branch.

<p align="center">
  <img src="dashboard.png" alt="Redline dashboard: H-pattern shifter, tachometer, fuel gauge, effort levers, NOS button, and usage bars" width="300">
</p>

## 🚦 Quickstart

```powershell
git clone https://github.com/Aaryanxvi/Redline.git
cd Redline
powershell -sta -File shift-gui.ps1
```

Click your Claude Code terminal once so Redline locks onto it (shown under `TARGET`), then drag the stick into a gate. That's it.

## ⚙️ How it works

Redline never talks to Claude directly. It targets a terminal window and types into it, exactly as if you'd typed the slash command yourself:

- **Targeting** — a focus poller (`user32.dll` `GetForegroundWindow`) tracks the last non-Redline window you touched. That window is the target; switching between terminals re-targets automatically.
- **Injection** — on a shift, Redline foregrounds the target (restoring it only if minimized, never resizing it) and sends the command via `SendKeys` + Enter.
- **Fuel gauge** — reads the target session's transcript under `~/.claude/projects`, sums the newest `usage` entry (`input + cache_creation + cache_read + output`), and renders it against the model's context window (200K for Haiku, 1M for everything else; the 33K autocompact buffer is subtracted for Sonnet to match `/context`).
- **Usage bars** — call the same OAuth `usage` endpoint the CLI uses, with the token from `~/.claude/.credentials.json`. Cached for 5 minutes, fetched off-thread so the UI never blocks.

Nothing leaves your machine. No dependencies beyond PowerShell 5.1 (ships with Windows) and the Claude Code CLI.

## 🔧 Installation

### Windows (GUI)

Clone or [download the ZIP](https://github.com/Aaryanxvi/Redline/archive/refs/heads/main.zip), then run:

```powershell
powershell -sta -File shift-gui.ps1
```

`-sta` is required — WinForms needs a single-threaded apartment. If PowerShell blocks the script, allow it for that one session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### macOS (GUI)

```bash
swift redline-mac.swift
```

Needs Xcode Command Line Tools (`xcode-select --install`) — the one dependency, the way PowerShell is on Windows. Same shifter, drawn natively with AppKit. Instead of injecting keystrokes it writes the command through the terminal's own scripting interface: iTerm2's `write text` or Terminal.app's `do script`. Run Claude Code in **iTerm2 or Terminal.app**, keep that terminal frontmost, and drag the stick. (New — give it a run and open an issue if anything misbehaves.)

### Launch with `/redline` from inside Claude Code

Type `/redline` in any Claude Code session to pop the shifter open. Two one-time steps to install it — the command finds the repo through a `REDLINE_DIR` environment variable, so there's no path to hand-edit.

**Windows (PowerShell):**

```powershell
# 1. copy the command into Claude Code, from inside your cloned repo folder
mkdir $HOME\.claude\commands -Force
copy commands\redline.md $HOME\.claude\commands\

# 2. tell it where the repo is (persists across sessions)
setx REDLINE_DIR "$PWD"
```

**macOS / Linux:**

```bash
# 1. copy the command into Claude Code, from inside your cloned repo folder
mkdir -p ~/.claude/commands
cp commands/redline.md ~/.claude/commands/

# 2. tell it where the repo is (add to ~/.zshrc or ~/.bashrc to persist)
echo "export REDLINE_DIR=\"$PWD\"" >> ~/.zshrc
```

Restart Claude Code, then `/redline` launches the shifter (Windows/macOS) with a guard that won't spawn a second copy.

## 📊 The dashboard

| Control | Command sent | Notes |
|---------|-------------|-------|
| Gear stick (gates 1–5, R) | `/model <name>` | Drag into a gate to shift |
| Effort levers (left) | `/effort low\|medium\|high\|xhigh` | Flip a lever to set thinking depth |
| NOS bottle | `/fast` | Toggles fast mode |
| Tachometer / fuel gauge | — | Context window remaining |
| 5H / WK bars (right) | — | 5-hour and weekly rate-limit utilization |

Every control has a sound: a recorded shifter clunk on a gear change, a button click on the effort levers, and a pressurized-gas hiss on the NOS bottle.

### 🕹️ Gears

| Gate | Model | `/model` arg |
|------|-------|--------------|
| 1 | Haiku 4.5 | `haiku` |
| 2 | Sonnet 5 | `sonnet` |
| 3 | Sonnet 5 (1M context) | `sonnet[1m]` |
| 4 | Opus 4.8 | `opus` |
| 5 | Fable 5 | `claude-fable-5` |
| R | Default | `default` |

## 📦 What's inside

- `shift-gui.ps1` — the Windows GUI. Single file, WinForms, no dependencies.
- `redline-mac.swift` — the macOS GUI. Single file, AppKit, needs Xcode CLT.
- `gear-shift.wav`, `switch-click.wav` — the shifter and switch sound samples.
- `commands/redline.md` — the `/redline` slash command for Claude Code.

## ⚠️ Notes & limitations

- **Effort isn't logged to the transcript**, so the levers can't reflect your current setting — they start neutral each launch and only *set* effort when clicked.
- **Targeting follows focus.** If a shift does nothing, click your Claude terminal so it becomes the target (its title shows under `TARGET`).
- **Transcripts are read tail-first** (last 1 MB, byte-seeked) so the gauge stays responsive even on multi-megabyte session files.

## 📄 License

MIT — see [LICENSE](LICENSE). Use it, fork it, ship it.
