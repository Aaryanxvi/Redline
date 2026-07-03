---
description: Launch the Gearbox model shifter
allowed-tools: Bash(powershell:*), Bash(bash:*)
---

Launch the Gearbox shifter, detached, so it keeps running independently of this session.

- On Windows, run: `powershell -Command "Start-Process powershell -ArgumentList '-sta','-WindowStyle','Hidden','-File','C:\path\to\Gearbox\shift-gui.ps1'"` (edit the path to where you cloned the repo). If a window titled "MODEL SHIFT" already exists, say so instead of launching a second copy.
- On macOS/Linux, the GUI is Windows-only. Tell the user to open a new terminal and run `./gear.sh` from the repo to launch claude in a chosen gear (`./gear.sh 3 xhigh` for gear + effort). Inside an already-running session, `/model` and `/effort` are the gears.

After launching, confirm in one short line. Do not do anything else.
