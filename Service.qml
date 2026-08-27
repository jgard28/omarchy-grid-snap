// Service.qml
//
// Owns persisted settings (grid size, last-picked cell/monitor, opacity,
// pin preference) and does the actual window manipulation via `hyprctl`.
//
// How window control works on this Hyprland version, briefly: as of
// Hyprland 0.55+, `hyprctl dispatch <text>` no longer takes the classic
// "dispatcher arg1 arg2" form -- it evaluates `<text>` as a Lua expression
// via `hl.dispatch(<text>)`. Every dispatcher call in this file was
// verified by hand against a live Hyprland 0.56.2 instance before being
// used here (toggle a property, read it back via `hyprctl clients -j`,
// confirm the change, restore it) -- see CHANGELOG.md for exactly what
// was and wasn't confirmed this way. In particular:
//   - `hl.dsp.window.float({ action, window })`, `.move({ x, y, window })`,
//     `.resize({ x, y, window })`, and `.pin({ action, window })` all
//     accept a `window = "address:0x..."` selector that targets a
//     SPECIFIC window without touching whatever currently has focus --
//     confirmed by targeting a background window while a different one
//     stayed focused throughout.
//   - Move/resize order matters: resizing after moving was observed to
//     shift the window's position (almost certainly because resize
//     anchors on the window's center, not its top-left corner). Resizing
//     FIRST and moving LAST sidesteps this, since nothing runs after the
//     move to disturb it.
//   - There is no live per-window opacity dispatcher in this API --
//     opacity is only available as a declarative `hl.window_rule({ match,
//     opacity })`, which matches by title/class, not by window address.
//     That means it can't be scoped as precisely as float/move/resize/pin
//     can, and it's the one part of this plugin that's genuinely
//     best-effort -- see the comment on applyOpacity() below.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: "jgard28.gridsnap"

  // --- Persisted state ---------------------------------------------------
  property var params: Model.mergeParams(null)
  property bool persistLoaded: false

  // --- Live (non-persisted) state -----------------------------------
  // The window this session is about to snap/unsnap -- captured explicitly
  // by captureTarget() BEFORE the panel opens and can steal focus. See
  // BarWidget.qml's button handler, which calls captureTarget() first,
  // then opens the panel.
  property string targetAddress: ""
  property string targetTitle: ""
  property string targetClass: ""

  // Populated by refreshMonitors(); each entry is {name, x, y, width, height}
  // in Hyprland's global layout coordinates (exactly what `hyprctl monitors
  // -j` reports, filtered down to the fields this plugin needs).
  property var monitors: []
  property string lastError: ""
  property string lastActionSummary: "Nothing snapped yet"

  // -----------------------------------------------------------------------
  // Settings persistence -- identical pattern to the Galaxy Effect plugin's
  // Service.qml; see that file's comments for the full rationale.
  // -----------------------------------------------------------------------
  function configObject() {
    if (pluginRegistry && typeof pluginRegistry.shellConfigProvider === "function")
      return pluginRegistry.shellConfigProvider()
    return shell && shell.shellConfig ? shell.shellConfig : null
  }

  function currentEntry() {
    var config = configObject()
    if (!pluginRegistry || typeof pluginRegistry.findEntryLocation !== "function") return null
    var loc = pluginRegistry.findEntryLocation(config, pluginId)
    if (!loc || !loc.found) return null
    if (loc.kind === "bar") return config.bar.layout[loc.section][loc.index]
    if (loc.kind === "plugin") return config.plugins[loc.index]
    return null
  }

  function loadPersisted() {
    var entry = currentEntry()
    if (entry) root.params = Model.mergeParams(entry.params)
    root.persistLoaded = true
    root.refreshMonitors()
  }

  function persistSettings() {
    if (!shell || typeof shell.updateEntryInline !== "function") return
    var entry = currentEntry() || {}
    var settings = {}
    for (var key in entry) {
      if (key !== "id") settings[key] = entry[key]
    }
    settings.params = root.params
    shell.updateEntryInline(pluginId, settings)
  }

  Component.onCompleted: {
    Qt.callLater(loadPersisted)
    writeScripts()
  }

  function setParam(key, value) {
    var d = Model.defFor(key)
    if (!d) return
    var n = Number(value)
    if (!isFinite(n)) return
    var next = {}
    for (var k in root.params) next[k] = root.params[k]
    var clamped = Model.clamp(n, d.min, d.max)
    var stepped = Math.round(clamped / d.step) * d.step
    next[key] = Math.round(stepped * 1e6) / 1e6
    root.params = next
    root.persistSettings()
  }

  function setSelection(monitorName, col, row) {
    var next = {}
    for (var k in root.params) next[k] = root.params[k]
    next.selectedMonitor = String(monitorName || "")
    next.selectedCol = Math.max(0, Math.round(Number(col) || 0))
    next.selectedRow = Math.max(0, Math.round(Number(row) || 0))
    root.params = next
    root.persistSettings()
  }

  // -----------------------------------------------------------------------
  // Capturing the target window
  // -----------------------------------------------------------------------
  // Must be called BEFORE the settings panel opens -- once the panel is
  // shown it can (and typically will) take keyboard focus itself, at which
  // point `hyprctl activewindow` would report the panel, not the window
  // the user actually meant to snap. BarWidget.qml's click handler calls
  // this first, then opens the panel.
  function captureTarget() {
    captureProc.running = true
  }

  Process {
    id: captureProc
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var win = Model.parseActiveWindow(text)
        if (win) {
          root.targetAddress = win.address
          root.targetTitle = win.title
          root.targetClass = win.class
        } else {
          root.targetAddress = ""
          root.targetTitle = ""
          root.targetClass = ""
        }
      }
    }
  }

  // -----------------------------------------------------------------------
  // Monitors
  // -----------------------------------------------------------------------
  function refreshMonitors() {
    monitorsProc.running = true
  }

  Process {
    id: monitorsProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      onStreamFinished: root.monitors = Model.parseMonitors(text)
    }
  }

  function monitorByName(name) {
    for (var i = 0; i < root.monitors.length; i++)
      if (root.monitors[i].name === name) return root.monitors[i]
    return root.monitors.length > 0 ? root.monitors[0] : null
  }

  // -----------------------------------------------------------------------
  // Snap / unsnap
  // -----------------------------------------------------------------------
  // Builds and runs one shell script per action rather than issuing several
  // separate Process calls from QML -- keeps the "read current float/pin
  // state, then only toggle what actually needs to change" logic atomic
  // and avoids a round trip back into QML between every hyprctl call.
  function snap() {
    if (!root.targetAddress) {
      root.lastError = "No window was focused when the panel opened."
      return
    }
    var monitor = root.monitorByName(root.params.selectedMonitor)
    if (!monitor) {
      root.lastError = "No monitor information available yet."
      return
    }
    var rect = Model.cellRect(monitor, root.params.gridCols, root.params.gridRows,
      root.params.selectedCol, root.params.selectedRow)
    var wantPin = root.params.pinOnSnap >= 0.5 ? "1" : "0"
    var opacity = root.params.opacity.toFixed(2)

    snapProc.command = ["bash", snapScriptPath,
      root.targetAddress, String(rect.x), String(rect.y), String(rect.w), String(rect.h),
      wantPin, opacity, root.targetTitle]
    snapProc.running = true
    root.lastActionSummary = "Snapped \"" + root.targetTitle + "\" to " + monitor.name
      + " (" + (root.params.selectedCol + 1) + "," + (root.params.selectedRow + 1) + " of "
      + root.params.gridCols + "x" + root.params.gridRows + ")"
  }

  function unsnap() {
    if (!root.targetAddress) {
      root.lastError = "No window was focused when the panel opened."
      return
    }
    unsnapProc.command = ["bash", unsnapScriptPath, root.targetAddress, root.targetTitle]
    unsnapProc.running = true
    root.lastActionSummary = "Restored \"" + root.targetTitle + "\""
  }

  // Scripts are written once to the plugin's own state directory rather
  // than inlined as `bash -c "..."` strings -- the snap script in
  // particular has enough quoting/escaping (window titles can contain
  // almost anything) that a real file is far less error-prone than
  // threading it through several layers of shell-inside-QML-string
  // escaping.
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/jgard28.gridsnap"
  readonly property string snapScriptPath: stateDir + "/snap.sh"
  readonly property string unsnapScriptPath: stateDir + "/unsnap.sh"

  // Written via a plain `cat <<'EOF' > file` heredoc inside a Process,
  // rather than through Quickshell's FileView write path -- this plugin
  // only needed one confirmed-reliable way to get a string onto disk, and
  // Process/bash was already proven out (see the Galaxy Effect plugin's
  // scanShaders()). The quoted heredoc delimiter ('SNAPEOF') stops the
  // shell from expanding anything inside the script content at WRITE
  // time -- the script's own $1/$2/... positional parameters are only
  // ever expanded later, when it actually runs.
  function writeScripts() {
    writeScriptsProc.command = ["bash", "-c",
      "mkdir -p \"$1\" && " +
      "cat > \"$1/snap.sh\" << 'SNAPEOF'\n" + Model.snapScript() + "\nSNAPEOF\n" +
      "cat > \"$1/unsnap.sh\" << 'UNSNAPEOF'\n" + Model.unsnapScript() + "\nUNSNAPEOF\n" +
      "chmod +x \"$1/snap.sh\" \"$1/unsnap.sh\"",
      "jgard28.gridsnap-write-scripts", root.stateDir]
    writeScriptsProc.running = true
  }

  Process {
    id: writeScriptsProc
  }

  Process {
    id: snapProc
    stdout: StdioCollector {
      onStreamFinished: {}
    }
    stderr: StdioCollector {
      onStreamFinished: if (text && String(text).trim() !== "") root.lastError = String(text).trim()
    }
  }

  Process {
    id: unsnapProc
    stdout: StdioCollector {
      onStreamFinished: {}
    }
    stderr: StdioCollector {
      onStreamFinished: if (text && String(text).trim() !== "") root.lastError = String(text).trim()
    }
  }

  // -----------------------------------------------------------------------
  // IPC
  // -----------------------------------------------------------------------
  function ipcSnap() {
    root.captureTarget()
    Qt.callLater(root.snap)
    return "ok"
  }

  function ipcUnsnap() {
    root.captureTarget()
    Qt.callLater(root.unsnap)
    return "ok"
  }

  function ipcParam(key, value) {
    var d = Model.defFor(key)
    if (!d) return "unknown-param"
    if (!isFinite(Number(value))) return "not-a-number"
    root.setParam(key, value)
    return String(Model.paramValue(root.params, key, d.def))
  }

  function ipcStatus() {
    return JSON.stringify({
      params: root.params,
      monitors: root.monitors,
      target: { address: root.targetAddress, title: root.targetTitle }
    })
  }
}
