---
description: Launch the Gearbox model shifter
allowed-tools: Bash(powershell:*), Bash(bash:*)
---

Launch the Gearbox shifter, detached, so it keeps running independently of this session.

**Windows** — run this, editing the path to where you cloned the repo:

```
powershell -Command "if (Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq 'MODEL SHIFT' }) { 'already running' } else { Start-Process powershell -ArgumentList '-sta','-WindowStyle','Hidden','-File','C:\path\to\Gearbox\shift-gui.ps1'; 'launched' }"
```

The guard skips launching if a "MODEL SHIFT" window is already open. Report whether it launched or was already running, in one short line.

**macOS / Linux** — the GUI is Windows-only. Tell the user to open a new terminal and run `./gear.sh` from the repo (`./gear.sh 5 xhigh` for gear + effort). Inside a running session, `/model` and `/effort` are the gears.

Do nothing else.
