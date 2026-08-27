// Model.js
//
// Shared constants, persisted-param definitions, and the pure geometry
// math for turning "monitor + grid size + which cell" into actual pixel
// coordinates. Kept separate from Service.qml (which does the actual
// hyprctl calls) so the coordinate math can be tested/reasoned about
// without needing a running compositor.
.pragma library

var barIcon = "▦" // "▦" -- squared grid glyph

// Every persisted setting, with its default/range -- the same "one list,
// generic slider Repeater" pattern used in the Galaxy Effect plugin.
// `kind` marks which ones get a non-slider control in Panel.qml.
var paramDefs = [
  { key: "gridCols", label: "Grid columns", min: 1, max: 4, step: 1, def: 2 },
  { key: "gridRows", label: "Grid rows",    min: 1, max: 4, step: 1, def: 2 },
  { key: "opacity",  label: "Opacity",      min: 0.2, max: 1.0, step: 0.05, def: 1.0 },
  // 0/1 toggle -- rendered as a switch, not a slider.
  { key: "pinOnSnap", label: "Pin across workspaces", min: 0, max: 1, step: 1, def: 1 }
]

// Sliders only (excludes pinOnSnap, which gets its own toggle row, and
// gridCols/gridRows, which get stepper controls next to the cell grid
// rather than full-width sliders).
var sliderParamDefs = paramDefs.filter(function (d) { return d.key === "opacity" })

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

function defFor(key) {
  for (var i = 0; i < paramDefs.length; i++)
    if (paramDefs[i].key === key) return paramDefs[i]
  return null
}

function mergeParams(saved) {
  var out = {}
  for (var i = 0; i < paramDefs.length; i++) {
    var d = paramDefs[i]
    var raw = saved ? saved[d.key] : undefined
    var v = typeof raw === "number" && isFinite(raw) ? raw : d.def
    out[d.key] = clamp(v, d.min, d.max)
  }
  // selectedMonitor/selectedCol/selectedRow aren't in paramDefs (they're
  // strings/indices, not numeric sliders) -- persist them separately with
  // their own light validation.
  out.selectedMonitor = saved && typeof saved.selectedMonitor === "string" ? saved.selectedMonitor : ""
  out.selectedCol = saved && typeof saved.selectedCol === "number" && isFinite(saved.selectedCol)
    ? Math.max(0, Math.round(saved.selectedCol)) : 0
  out.selectedRow = saved && typeof saved.selectedRow === "number" && isFinite(saved.selectedRow)
    ? Math.max(0, Math.round(saved.selectedRow)) : 0
  return out
}

function paramValue(params, key, fallback) {
  if (params && typeof params[key] === "number") return params[key]
  var d = defFor(key)
  return d ? d.def : fallback
}

// The actual geometry: given one monitor's own rect (in Hyprland's global
// layout coordinates, which is what `hyprctl monitors -j`'s x/y/width/
// height already are) and a grid size, compute the pixel rect for one
// cell. This is pure arithmetic -- no rounding surprises to worry about
// beyond the final Math.round(), since window position/size dispatchers
// want whole pixels.
//
// Grid cells are carved out of the monitor's USABLE area -- monitor rect
// minus `reserved` -- not the full physical monitor rect. `reserved` is
// `hyprctl monitors -j`'s own [left, top, right, bottom] pixel margins
// for whatever's claimed an exclusive layer-shell zone on that monitor
// (confirmed: the Omarchy bar reserves 26px at the top on every monitor
// via a real `"reserved": [0, 26, 0, 0]` from a live system). Skipping this
// and dividing the raw monitor rect instead is exactly what put row 0
// underneath/behind the bar -- the top of that cell landed at the
// monitor's y origin, which is where the bar already lives.
function cellRect(monitor, cols, rows, col, row) {
  cols = Math.max(1, Math.round(cols))
  rows = Math.max(1, Math.round(rows))
  col = clamp(Math.round(col), 0, cols - 1)
  row = clamp(Math.round(row), 0, rows - 1)

  var reserved = (monitor.reserved && monitor.reserved.length === 4)
    ? monitor.reserved : [0, 0, 0, 0]
  var usable = {
    x: monitor.x + reserved[0],
    y: monitor.y + reserved[1],
    width: Math.max(1, monitor.width - reserved[0] - reserved[2]),
    height: Math.max(1, monitor.height - reserved[1] - reserved[3])
  }

  var cellW = usable.width / cols
  var cellH = usable.height / rows

  return {
    x: Math.round(usable.x + col * cellW),
    y: Math.round(usable.y + row * cellH),
    w: Math.round(cellW),
    h: Math.round(cellH)
  }
}

// Parses `hyprctl monitors -j`'s stdout into the plain {name,x,y,width,
// height,reserved} shape cellRect() above expects, dropping every other
// field (scale, refresh rate, etc.) this plugin has no use for.
function parseMonitors(json) {
  var raw
  try { raw = JSON.parse(json) } catch (e) { return [] }
  if (!Array.isArray(raw)) return []
  var out = []
  for (var i = 0; i < raw.length; i++) {
    var m = raw[i]
    if (!m || typeof m.name !== "string") continue
    var reserved = Array.isArray(m.reserved) && m.reserved.length === 4
      ? m.reserved.map(function (v) { return Number(v) || 0 })
      : [0, 0, 0, 0]
    out.push({
      name: m.name,
      x: Number(m.x) || 0,
      y: Number(m.y) || 0,
      width: Number(m.width) || 0,
      height: Number(m.height) || 0,
      reserved: reserved
    })
  }
  return out
}

// Same idea for `hyprctl activewindow -j` -- just the fields we need to
// decide what to snap and to build the window_rule match below.
function parseActiveWindow(json) {
  var raw
  try { raw = JSON.parse(json) } catch (e) { return null }
  if (!raw || typeof raw.address !== "string" || !raw.address) return null
  return {
    address: raw.address,
    title: String(raw.title || ""),
    class: String(raw.class || ""),
    monitor: raw.monitor
  }
}

// -----------------------------------------------------------------------
// The actual hyprctl scripts
// -----------------------------------------------------------------------
// Both scripts are written to disk once (see Service.qml's writeScripts())
// and then invoked repeatedly with fresh positional arguments -- nothing
// here is a template needing per-call string interpolation from QML,
// which is deliberate: building the same shell logic as a `bash -c
// "..."` string assembled fresh in QML every click would mean re-deriving
// the correct quoting for a window title that can contain literally
// anything (quotes, `$`, backticks, unicode) every single time. A real
// script file that reads its inputs as `"$1"`.."$8"` sidesteps that
// entirely -- the shell only ever has to quote-safely pass strings as
// argv elements, never re-parse them as code.
//
// Dispatcher calls throughout were verified by hand against a live
// Hyprland 0.56.2 instance (toggle a property, confirm via `hyprctl
// clients -j`, restore it) before being used here -- see this repo's
// CHANGELOG.md for exactly what that verification covered.

function snapScript() {
  return [
    "set -euo pipefail",
    "addr=\"$1\"; x=\"$2\"; y=\"$3\"; w=\"$4\"; h=\"$5\"; want_pin=\"$6\"; opacity=\"$7\"; title=\"$8\"",
    "sel=\"address:$addr\"",
    "",
    "# Read current floating/pinned state so this is idempotent: clicking",
    "# Snap twice in a row must not toggle floating/pin back OFF the second",
    "# time. Only flip what actually needs to change.",
    "cur=$(hyprctl clients -j | jq -r --arg a \"$addr\" '.[] | select(.address==$a)')",
    "is_floating=$(printf '%s' \"$cur\" | jq -r '.floating // false')",
    "is_pinned=$(printf '%s' \"$cur\" | jq -r '.pinned // false')",
    "",
    "if [ \"$is_floating\" != \"true\" ]; then",
    "  hyprctl dispatch \"hl.dsp.window.float({ action = 'enable', window = '$sel' })\" >/dev/null",
    "fi",
    "",
    "# Resize BEFORE move: resizing was observed to shift the window's",
    "# reported position (the dispatcher appears to anchor on the window's",
    "# center, not its top-left corner). Doing the move last means nothing",
    "# runs afterward to disturb the final position.",
    "hyprctl dispatch \"hl.dsp.window.resize({ x = $w, y = $h, window = '$sel' })\" >/dev/null",
    "hyprctl dispatch \"hl.dsp.window.move({ x = $x, y = $y, window = '$sel' })\" >/dev/null",
    "",
    "if [ \"$want_pin\" = \"1\" ] && [ \"$is_pinned\" != \"true\" ]; then",
    "  hyprctl dispatch \"hl.dsp.window.pin({ action = 'toggle', window = '$sel' })\" >/dev/null",
    "elif [ \"$want_pin\" = \"0\" ] && [ \"$is_pinned\" = \"true\" ]; then",
    "  hyprctl dispatch \"hl.dsp.window.pin({ action = 'toggle', window = '$sel' })\" >/dev/null",
    "fi",
    "",
    "# Opacity is the one part of this plugin that's genuinely best-effort:",
    "# there is no live, per-window-instance opacity dispatcher in this",
    "# Hyprland Lua API -- only a declarative window_rule matched by",
    "# title/class, not by address. That means it CAN affect another window",
    "# that happens to share this exact title, and there's no confirmed way",
    "# to later remove just this one rule (unsnap.sh re-applies opacity",
    "# 1.0/1.0 to the same title match instead of trying to un-register it).",
    "if [ -n \"$title\" ]; then",
    "  esc_title=$(printf '%s' \"$title\" | sed 's/[.^$*+?()\\[{|\\\\]/\\\\&/g')",
    "  hyprctl eval \"hl.window_rule({ match = { title = '^${esc_title}$' }, opacity = '$opacity $opacity' })\" >/dev/null || true",
    "fi"
  ].join("\n")
}

function unsnapScript() {
  return [
    "set -euo pipefail",
    "addr=\"$1\"; title=\"$2\"",
    "sel=\"address:$addr\"",
    "",
    "cur=$(hyprctl clients -j | jq -r --arg a \"$addr\" '.[] | select(.address==$a)')",
    "is_floating=$(printf '%s' \"$cur\" | jq -r '.floating // false')",
    "is_pinned=$(printf '%s' \"$cur\" | jq -r '.pinned // false')",
    "",
    "if [ \"$is_pinned\" = \"true\" ]; then",
    "  hyprctl dispatch \"hl.dsp.window.pin({ action = 'toggle', window = '$sel' })\" >/dev/null",
    "fi",
    "if [ \"$is_floating\" = \"true\" ]; then",
    "  hyprctl dispatch \"hl.dsp.window.float({ action = 'disable', window = '$sel' })\" >/dev/null",
    "fi",
    "",
    "if [ -n \"$title\" ]; then",
    "  esc_title=$(printf '%s' \"$title\" | sed 's/[.^$*+?()\\[{|\\\\]/\\\\&/g')",
    "  hyprctl eval \"hl.window_rule({ match = { title = '^${esc_title}$' }, opacity = '1.0 1.0' })\" >/dev/null || true",
    "fi"
  ].join("\n")
}

function parseOnOffToggle(raw, current) {
  var v = String(raw || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (!v) return current
  if (v === "toggle") return !current
  if (v === "off" || v === "0" || v === "false" || v === "no") return false
  if (v === "on" || v === "1" || v === "true" || v === "yes") return true
  return current
}
