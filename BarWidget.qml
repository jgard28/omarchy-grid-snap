// BarWidget.qml
//
// The bar icon and terminal IPC surface. Structure copied from the Galaxy
// Effect plugin's BarWidget.qml (Loader-owned Panel.qml, injectPanel(),
// an IpcHandler block) -- see that file for why this is the standard
// shape for an Omarchy shell bar-widget plugin with a settings panel.
//
// The one thing specific to THIS plugin: captureTarget() is called here,
// in the click handler, BEFORE the panel opens -- not inside Panel.qml.
// That ordering matters. Once the panel is shown it can take keyboard
// focus itself, and at that point `hyprctl activewindow` would report the
// panel, not whatever window the user actually meant to snap.
import QtQuick
import Quickshell.Io
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "jgard28.gridsnap"

  readonly property var fx: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("jgard28.gridsnap") : null

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (root.fx) root.fx.captureTarget()
    if (root.fx) root.fx.refreshMonitors()
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Terminal / scripting entry points: `omarchy-shell jgard28.gridsnap <cmd>`.
  // Snap/unsnap over IPC act on whatever window is ACTUALLY focused at the
  // moment the command runs (there's no panel involved to steal focus in
  // that case), unlike the button, which captures the target first.
  IpcHandler {
    target: "jgard28.gridsnap"
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.togglePanel() }
    function status(): string {
      return root.fx && root.fx.ipcStatus ? root.fx.ipcStatus() : "no-service"
    }
    function snap(): string {
      return root.fx && root.fx.ipcSnap ? root.fx.ipcSnap() : "no-service"
    }
    function unsnap(): string {
      return root.fx && root.fx.ipcUnsnap ? root.fx.ipcUnsnap() : "no-service"
    }
    function param(key: string, value: string): string {
      return root.fx && root.fx.ipcParam ? root.fx.ipcParam(key, value) : "no-service"
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barIcon
    useActiveColor: false
    tooltipText: "Grid Snap"

    // Left-click: toggle the panel, capturing the currently-focused window
    // only on the OPEN transition (capturing again on close would just
    // re-capture the panel itself, which is harmless but pointless).
    // Right-click: quick unsnap of whatever's currently focused, no panel
    // needed -- the fast "put it back" escape hatch.
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.fx) {
          root.fx.captureTarget()
          Qt.callLater(root.fx.unsnap)
        }
        return
      }
      if (root.opened) root.close()
      else root.open()
    }
  }
}
