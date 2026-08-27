# Changelog

## 1.0.0

Initial release.

- Snap the focused window into a grid cell on any connected monitor, grid
  cells computed from each monitor's real resolution/position
- Adjustable grid size (1-4 columns × 1-4 rows)
- Opacity slider (best-effort — see README's "How it works")
- Pin across workspaces toggle
- Idempotent snap (safe to click repeatedly) and a one-click Restore
- Terminal IPC: `snap`, `unsnap`, `status`, `param`
