# Linux GUI — design notes (not built yet)

Parked here until there's a Linux box to build and test on. `main` ships Windows +
macOS GUIs; Linux has no port yet.

## Runtime: GJS (GNOME JavaScript + GTK + Cairo)

The Linux analog to Windows PowerShell/WinForms and macOS Swift/AppKit — a
preinstalled scripting runtime with a native GUI toolkit, no compile step, no Python.

- Run: `gjs gearbox-linux.js`
- Preinstalled on GNOME desktops (Ubuntu, Fedora); elsewhere `apt install gjs` / `dnf install gjs`.
- Draw the chrome disc / tach / fuel gauge / H-shifter with **Cairo** (`cairo_pattern` linear
  gradients cover what GDI+ `LinearGradientBrush` did on Windows).
- Always-on-top: `GtkWindow` with `set_keep_above(true)` (X11) or the layer-shell
  protocol on Wayland (`gtk-layer-shell`), falling back to a normal floating window.

## Injection: tmux first, xdotool fallback

OS-level keystroke injection is the Linux pain point — `xdotool` is X11-only and does
nothing on Wayland. The clean, Wayland-proof channel is **tmux**:

- If Claude Code runs inside tmux: `tmux send-keys -t <pane> "/model sonnet" Enter`.
  No keystroke simulation, works on X11 **and** Wayland, even over SSH.
- Target the pane via `$GEAR_TMUX` (e.g. `session:window.pane`) or auto-detect the
  active pane with `tmux display-message -p '#{pane_id}'`.
- Non-tmux X11 fallback: `xdotool type --window <id>` + `key Return`.
- Native Wayland without tmux: no reliable path — document tmux as the requirement.

## Reused logic (identical to the Windows/Mac ports)

- **Fuel**: tail the newest `~/.claude/projects/**/*.jsonl`, sum the last `usage` entry,
  render against the model's context window (200K Haiku / 1M else; −33K on Sonnet).
- **Usage bars**: OAuth `usage` endpoint; token from `~/.claude/.credentials.json`
  (Linux keeps it in the file, no Keychain).
- Gears, geometry, effort levers, NOS → all copy straight from `shift-gui.ps1`.

## Build checklist (when a Linux box is available)

1. `gearbox-linux.js` — GJS/GTK window + Cairo drawing, ported from the Windows layout.
2. Wire injection through `tmux send-keys` with the `$GEAR_TMUX` target.
3. Test on X11 and Wayland (GNOME + a wlroots compositor like Sway).
4. Add a `/gear` Linux branch that launches `gjs gearbox-linux.js`.
5. Merge to `main`, update the README platform table.
