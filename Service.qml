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
//     Confirmed live: a rule applied this way OUTLIVES the window it was
//     meant for and silently reapplies to any later window sharing the
//     same title+class. See "Opacity-rule sweep" further down for how
//     this plugin tracks and auto-resets those rules once their window
//     is confirmed closed -- that tracking is what actually makes
//     opacity safe to ship, not anything about the rule call itself.
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

  // Runs `fn` once captureTarget()'s subprocess has ACTUALLY finished and
  // targetAddress/targetTitle/targetClass reflect its result -- calling
  // captureTarget() and then immediately calling something that reads
  // those properties (e.g. via Qt.callLater) races the subprocess: a
  // Qt.callLater callback typically runs on the next event-loop tick,
  // which is often sooner than a spawned process returns, and would use
  // WHATEVER the previous capture left behind instead of the fresh one.
  // Used by the IPC snap/unsnap commands, which have no panel-open step
  // to naturally separate "capture" from "act" in time the way the bar
  // icon's click handler does.
  function captureTargetThen(fn) {
    root._afterCapture = fn
    root.captureTarget()
  }
  property var _afterCapture: null

  Process {
    id: captureProc
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        // Clear any leftover status from a PREVIOUS target -- without
        // this, reopening the panel on a new window can show a stale
        // "Snapped ..." or error message that was actually about whatever
        // window was captured last time, which reads as if it just
        // happened to the window you're looking at now.
        root.lastActionSummary = "Nothing snapped yet"
        root.lastError = ""

        var win = Model.parseActiveWindow(text)
        if (win) {
          root.targetAddress = win.address
          root.targetTitle = win.title
          root.targetClass = win.class
          // Default the monitor picker to wherever this window ACTUALLY
          // is, rather than always falling back to the first monitor or
          // whatever was picked last time. This only takes effect if the
          // monitor list has already loaded; if it hasn't yet, the
          // picker's own fallback (first monitor) still applies, and this
          // is harmless -- refreshMonitors() runs on every panel open too.
          if (root.monitors.length > 0 && typeof win.monitor === "number") {
            var name = Model.monitorNameForId(root.monitors, win.monitor)
            if (name) root.setSelection(name, root.params.selectedCol, root.params.selectedRow)
          }
        } else {
          root.targetAddress = ""
          root.targetTitle = ""
          root.targetClass = ""
        }

        if (root._afterCapture) {
          var fn = root._afterCapture
          root._afterCapture = null
          fn()
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
      wantPin, opacity, root.targetTitle, root.targetClass]
    snapProc.running = true
    root.lastActionSummary = "Snapped \"" + root.targetTitle + "\" to " + monitor.name
      + " (" + (root.params.selectedCol + 1) + "," + (root.params.selectedRow + 1) + " of "
      + root.params.gridCols + "x" + root.params.gridRows + ")"

    // Track (or stop tracking) this window for the opacity-rule sweep --
    // see sweepOpacityRules() below for why this bookkeeping exists at
    // all: a window_rule outlives the window it was meant for, so
    // anything that applied one below full opacity needs to stay tracked
    // until that window is confirmed closed, at which point the sweep
    // resets it on its own.
    var next = {}
    for (var k in root.params) next[k] = root.params[k]
    next.openRules = root.params.opacity < 0.999
      ? Model.addOpenRule(root.params.openRules, root.targetAddress, root.targetTitle, root.targetClass)
      : Model.removeOpenRule(root.params.openRules, root.targetAddress)
    root.params = next
    root.persistSettings()
  }

  function unsnap() {
    if (!root.targetAddress) {
      root.lastError = "No window was focused when the panel opened."
      return
    }
    unsnapProc.command = ["bash", unsnapScriptPath, root.targetAddress, root.targetTitle, root.targetClass]
    unsnapProc.running = true
    root.lastActionSummary = "Restored \"" + root.targetTitle + "\""

    var next = {}
    for (var k in root.params) next[k] = root.params[k]
    next.openRules = Model.removeOpenRule(root.params.openRules, root.targetAddress)
    root.params = next
    root.persistSettings()
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
  readonly property string resetScriptPath: stateDir + "/reset.sh"

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
      "cat > \"$1/reset.sh\" << 'RESETEOF'\n" + Model.resetOpacityScript() + "\nRESETEOF\n" +
      "chmod +x \"$1/snap.sh\" \"$1/unsnap.sh\" \"$1/reset.sh\"",
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
  // Opacity-rule sweep -- this is the actual safety net, not the comments
  // in snap.sh
  // -----------------------------------------------------------------------
  // Confirmed live (see CHANGELOG.md): a window_rule opacity change
  // OUTLIVES the window it was applied for, and silently reapplies to any
  // LATER window that happens to share the same title+class -- including
  // one that has nothing to do with this plugin, opened days later. That
  // is a real "messes with something the user didn't touch" risk, not a
  // cosmetic one.
  //
  // The fix: every window this plugin ever applies a non-1.0 opacity to
  // gets tracked in params.openRules ({address, title, class}) until
  // proven closed. Periodically (and once at startup, in case a tracked
  // window closed while the shell wasn't running), check which tracked
  // addresses are no longer present in `hyprctl clients -j` and reset
  // THEIR rule back to opacity 1.0 -- at that point the window it was for
  // is gone, so resetting can only ever affect a future, unrelated window,
  // never one currently in use. A rule is never reset while its window is
  // still open, so this can't undo an opacity setting someone is actively
  // using.
  function sweepOpacityRules() {
    if (root.params.openRules.length === 0) return
    sweepProc.running = true
  }

  Process {
    id: sweepProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var liveAddresses = Model.addressesFromClientsJson(text)
        var stillOpen = []
        var stale = []
        for (var i = 0; i < root.params.openRules.length; i++) {
          var rule = root.params.openRules[i]
          if (liveAddresses.indexOf(rule.address) !== -1) stillOpen.push(rule)
          else stale.push(rule)
        }
        if (stale.length === 0) return

        var next = {}
        for (var k in root.params) next[k] = root.params[k]
        next.openRules = stillOpen
        root.params = next
        root.persistSettings()

        root._resetQueue = root._resetQueue.concat(stale)
        root.processResetQueue()
      }
    }
  }

  // Stale rules are cleaned up one at a time (rather than racing several
  // Process instances) since this only ever runs for a handful of items
  // at most and simplicity matters more than speed here.
  property var _resetQueue: []

  function processResetQueue() {
    if (resetProc.running || root._resetQueue.length === 0) return
    var rule = root._resetQueue.shift()
    resetProc.command = ["bash", root.resetScriptPath, rule.title, rule.class]
    resetProc.running = true
  }

  Process {
    id: resetProc
    onExited: root.processResetQueue()
  }

  Timer {
    // 30s: frequent enough that a stale rule doesn't linger long after
    // its window closes, infrequent enough to be background noise -- this
    // is a couple of cheap `hyprctl`/`jq` calls, not a rendering loop.
    interval: 30000
    running: root.persistLoaded
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sweepOpacityRules()
  }

  // -----------------------------------------------------------------------
  // IPC
  // -----------------------------------------------------------------------
  function ipcSnap() {
    root.captureTargetThen(root.snap)
    return "ok"
  }

  function ipcUnsnap() {
    root.captureTargetThen(root.unsnap)
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
