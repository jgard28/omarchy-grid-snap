# Omarchy Grid Snap

Snap the focused window into a grid cell on any monitor — built for
watching a video (Netflix, YouTube, anything) in a corner while you work
in front of it. Pick a monitor, pick a grid size, click a cell, optionally
make it semi-transparent and pin it so it stays visible no matter which
workspace you switch to.

Plugin id: `jgard28.gridsnap` · version **1.0.0**

## Install

```bash
omarchy plugin add https://github.com/jgard28/omarchy-grid-snap.git --enable
```

## Usage

1. Focus the window you want to snap (your video window/tab).
2. **Left-click** the bar icon — this captures whatever window was just
   focused *before* the panel can steal focus itself, then opens the
   panel.
3. Pick a monitor, a grid size (columns × rows), and click a cell.
4. Optionally lower **Opacity** and/or leave **Pin across workspaces** on.
5. Click **Snap here**.
6. **Restore** in the panel (or right-click the bar icon at any time) puts
   the window back to normal tiled behavior.

Clicking **Snap here** again with the window still snapped is safe —
snapping is idempotent, it won't toggle floating/pin back off on a second
click, it'll just move/resize to the newly picked cell.

### Why this needs to be manual, not automatic "detect the video and snap it"

Wayland/Hyprland can only see *windows*, never individual browser tabs —
there's no way to know "this specific tab is playing a video" without a
browser extension talking to a native companion process, which is a much
bigger, per-browser project. `playerctl`/MPRIS can tell you *an app* is
playing media, but not *which window* if you have several open. Manual
capture-then-snap sidesteps all of that ambiguity entirely, at the cost of
one extra click.

## Multi-monitor / varying resolutions

Grid cells are computed from each monitor's *actual* resolution and
position (`hyprctl monitors -j`), not a fixed assumption — a 2×2 grid on a
2560×1440 monitor and a 2×2 grid on a 1920×1080 one both correctly cover
their own monitor edge-to-edge. The monitor picker lists whatever's
actually connected.

## Requirements

- Omarchy with `omarchy-shell` (Quickshell) and Hyprland
- **Hyprland 0.55+, using the Lua config/dispatch API** (`hl.dispatch`,
  `hl.dsp.*`) — this is what every window-manipulation call in this plugin
  is built on. See "How it works" below.
- `jq` (used by the snap/unsnap scripts to read current window state)

## How it works

Hyprland 0.55+ changed `hyprctl dispatch` to evaluate its argument as Lua
(`hl.dispatch(<your text>)`) instead of the classic
`dispatcher arg1 arg2` form. Every dispatcher call this plugin makes was
verified by hand against a live Hyprland 0.56.2 instance — toggle a
property, confirm the change via `hyprctl clients -j`, restore it — before
being used here:

| What | Call | Verified how |
|---|---|---|
| Float on/off | `hl.dsp.window.float({ action = "enable"/"disable", window = "address:0x..." })` | Toggled a real window's `.floating`, confirmed idempotent (calling `"enable"` twice doesn't flip back off) |
| Move | `hl.dsp.window.move({ x, y, window })` | Moved a window, confirmed exact `.at` via `hyprctl clients -j` |
| Resize | `hl.dsp.window.resize({ x, y, window })` | Confirmed exact `.size` |
| Pin (visible on all workspaces) | `hl.dsp.window.pin({ action = "toggle", window })` | Toggled `.pinned`, confirmed idempotent via a state-check-before-toggle in the script (no confirmed non-toggle "set" action) |
| Target a specific window without stealing focus | the `window = "address:0x..."` field on all of the above | Targeted a background window by address while a *different* window stayed focused throughout — confirmed via `hyprctl activewindow -j` |

The one genuinely best-effort part: **there is no live per-window opacity
dispatcher** in this API, only a declarative `hl.window_rule({ match =
{ title }, opacity })`, which matches by window *title*, not by address.
That means:
- It can affect another window that happens to share the exact same title
  (rare in practice, but possible).
- There's no confirmed way to cleanly *remove* a rule once applied — the
  Restore button re-applies the rule with opacity `1.0 1.0` to the same
  title match rather than un-registering it.
- The call was confirmed to execute without a Lua error, but not
  independently confirmed to visually change opacity on this specific
  Hyprland build. If it doesn't work for you, please open an issue with
  what `hyprctl eval` returns for the `hl.window_rule(...)` call in
  `~/.local/state/jgard28.gridsnap/snap.sh` run by hand.

Move/resize order matters: **resize runs before move**, not after —
resizing a floating window was observed to shift its reported position
(the dispatcher appears to anchor on the window's center, not its
top-left corner). Doing the move last means nothing runs afterward to
disturb the final position; this was confirmed to land a window at the
*exact* requested pixel coordinates and size.

### Files

- **`manifest.json`** — plugin metadata.
- **`Service.qml`** — persisted settings (grid size, last-picked
  monitor/cell, opacity, pin preference), monitor list (`hyprctl monitors
  -j`), target-window capture (`hyprctl activewindow -j`), and writes/runs
  the snap/unsnap scripts.
- **`BarWidget.qml`** — the bar icon and IPC. Captures the target window
  in the click handler, *before* the panel can open and steal focus.
- **`Panel.qml`** — monitor picker, grid size steppers, a click-a-cell
  visual grid, opacity slider, pin toggle, Snap/Restore buttons.
- **`Model.js`** — param definitions, the monitor/window JSON parsers, the
  cell-rect geometry math, and the actual snap.sh/unsnap.sh script text.

Scripts are generated once to `${XDG_STATE_HOME:-~/.local/state}/jgard28.gridsnap/`
and invoked with fresh arguments per click, rather than being rebuilt as a
`bash -c "..."` string every time — a window title can contain almost
anything (quotes, `$`, backticks), and a real script reading `"$1".."$8"`
sidesteps re-deriving safe quoting for that on every single click.

## IPC

```bash
omarchy-shell jgard28.gridsnap <command> [args]
```

| Command | What it does |
|---|---|
| `open` / `show` | Open the panel (captures the currently focused window first) |
| `close` / `hide` | Close the panel |
| `toggle` | Open or close the panel |
| `snap` | Snap whatever window is *currently* focused (no panel involved) using the last-used monitor/grid/cell/opacity/pin settings |
| `unsnap` | Restore whatever window is currently focused |
| `status` | Current settings, connected monitors, and captured target, as JSON |
| `param <key> <value>` | Set one setting — `gridCols`/`gridRows` (1-4), `opacity` (0.2-1.0), `pinOnSnap` (0/1) |

## Known limitations

- Opacity is best-effort — see "How it works" above.
- No automatic "detect a playing video and snap it" mode — see the FAQ
  above for why. `playerctl`-based auto-detection is a plausible future
  addition, flagged as a real ambiguity (which window, if several) rather
  than solved here.
- Pin's `"toggle"` action is used defensively (read state, only toggle if
  it needs to change) because no confirmed non-toggle "force on" action
  was found for it — unlike float, where `"enable"`/`"disable"` were
  confirmed to work as true force-set actions.

## License

MIT — see [LICENSE](LICENSE).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
