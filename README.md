# Gear — a gearbox for Claude Code

Switch Claude Code models like shifting gears.

- **Windows** — `shift-gui.ps1`: a draggable H-pattern shifter that lives on top of your desktop. Drag the knob into a gate to send `/model <x>` to your Claude terminal. Includes a tachometer, a **fuel gauge** (context window remaining), **effort toggles** (`/effort low|medium|high|xhigh`), a **NOS button** (`/fast` toggle), and live **usage bars** (5-hour + weekly rate-limit utilization).
- **macOS / Linux** — `gear.sh`: a terminal gearbox. Pick a gear, it launches `claude` in that model (optionally with an effort level). Inside a running session, `/model` and `/effort` are your gears.

Single-file scripts. No dependencies beyond the Claude Code CLI (and PowerShell 5.1 on Windows, which ships with it).

## Usage — Windows GUI

```powershell
powershell -sta -File shift-gui.ps1
```

1. Focus your Claude terminal once — the shifter auto-locks onto the last window you touched (shown under `TARGET:`).
2. Drag the knob into a gear gate. It sends `/model <name>` to that terminal.
3. **Fuel gauge** reads context remaining from the session transcript. **Effort levers** (left) send `/effort`. **NOS** (`/fast`) toggles fast mode. **5H / WK bars** (right) show usage-limit utilization from the Claude usage API.

`-sta` is required (WinForms needs a single-threaded apartment).

## Usage — macOS / Linux terminal

```bash
chmod +x gear.sh
./gear.sh          # interactive menu
./gear.sh 3        # straight into gear 3 (Sonnet 5 1M)
./gear.sh 5 xhigh  # Fable 5 at xhigh effort
```

## Launch from inside Claude Code

Copy `commands/gear.md` to `~/.claude/commands/` and edit the script path inside it. Then `/gear` in any session launches the shifter.

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
