# Changelog

## 1.1.0

A refinement pass driven by actually evaluating the UI and hunting for
anything that could misbehave, not new features:

- **Stability fix (the important one):** confirmed live that the opacity
  `window_rule` outlives the window it was applied to and silently
  reapplies to any later, unrelated window sharing the same title —
  verified by closing a test window and opening a fresh one with the
  identical title, which inherited the old opacity untouched. Fixed by
  tracking every window a non-1.0 opacity gets applied to and sweeping
  (every 30s, and once at startup) to reset any tracked rule whose window
  has since closed. A rule is never touched while its window is still
  open. Also narrowed matching to title **and** class together, not title
  alone.
- **Fixed a real race** in the IPC `snap`/`unsnap` commands: they called
  `captureTarget()` (an async subprocess) and then immediately acted via
  `Qt.callLater`, which can run before the subprocess returns, using
  stale target data from a previous capture. Panel-driven snaps were
  never affected (the panel-open step naturally separates capture from
  action in time); IPC-driven ones now wait for the real capture via
  `captureTargetThen()`.
- **UX: auto-select the monitor the target window is actually on** when
  it's captured, instead of always defaulting to the first monitor or
  whatever was picked last time.
- **UX: Snap/Restore are now disabled with a clear inline explanation**
  when no window was captured, instead of failing silently into a small
  error line.
- **UX: stale status text no longer lingers** — opening the panel on a
  new window used to still show the previous window's "Snapped ..." or
  error message until you took a new action.
- Fixed the bar-overlap bug found via real-world testing: grid cells are
  now carved from each monitor's *usable* area (`hyprctl monitors -j`'s
  `reserved` margin subtracted first), not its full physical size — the
  earlier version divided the raw rect, which put the entire top row of
  cells partially underneath the Omarchy bar. Verified against a real
  Netflix/Firefox window, both numerically (`hyprctl clients -j`) and
  visually.

## 1.0.0

Initial release.

- Snap the focused window into a grid cell on any connected monitor, grid
  cells computed from each monitor's real resolution/position
- Adjustable grid size (1-4 columns × 1-4 rows)
- Opacity slider (best-effort — see README's "How it works")
- Pin across workspaces toggle
- Idempotent snap (safe to click repeatedly) and a one-click Restore
- Terminal IPC: `snap`, `unsnap`, `status`, `param`
