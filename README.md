# Gear — a gearbox for Claude Code

Switch Claude Code models like shifting gears. A draggable H-pattern shifter (`shift-gui.ps1`) that lives on top of your desktop: drag the knob into a gate to send `/model <x>` to your Claude terminal. Includes a tachometer, a **fuel gauge** (context window remaining), **effort toggles** (`/effort low|medium|high|xhigh`), a **NOS button** (`/fast` toggle), and live **usage bars** (5-hour + weekly rate-limit utilization).

Single-file script. No dependencies beyond Windows PowerShell and the Claude Code CLI.

## Requirements

- Windows (uses WinForms + `user32.dll`)
- [Claude Code](https://claude.com/claude-code) CLI on your PATH
- Windows PowerShell 5.1 (ships with Windows)

## Usage

```powershell
powershell -sta -File shift-gui.ps1
```

1. Focus your Claude terminal once — the shifter auto-locks onto the last window you touched (shown under `TARGET:`).
2. Drag the knob into a gear gate. It sends `/model <name>` to that terminal.
3. **Fuel gauge** reads context remaining from the session transcript. **Effort levers** (left) send `/effort`. **NOS** (`/fast`) toggles fast mode. **5H / WK bars** (right) show usage-limit utilization from the Claude usage API.

`-sta` is required (WinForms needs a single-threaded apartment).

## Gears

| Gate | Model |
|------|-------|
| 1 | Haiku 4.5 |
| 2 | Sonnet 5 |
| 3 | Sonnet 5 (1M context) |
| 4 | Opus 4.8 |
| 5 | Fable 5 |
| R | Default |

## Notes

- The fuel gauge reads Claude Code's local session transcripts under `~/.claude/projects`. Nothing leaves your machine.
- Usage bars call the Claude usage endpoint with the OAuth token from `~/.claude/.credentials.json` — same token the CLI already uses.
- Effort level can't be read back from the transcript, so the levers start neutral each launch; clicking one sends the command.

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, ship it.
