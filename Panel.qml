// Panel.qml
//
// The settings popover: which window is targeted, a monitor picker, grid
// size steppers, a click-a-cell grid, an opacity slider, a pin toggle,
// and Snap/Restore buttons. Same "plain QtQuick primitives, only the
// handful of shared Omarchy shell UI pieces the reference plugin already
// uses" approach as the Galaxy Effect plugin's Panel.qml -- see that
// file's header comment for the full rationale.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "jgard28.gridsnap"
  ipcTarget: "jgard28.gridsnap"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var fx: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("jgard28.gridsnap") : null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var monitors: fx ? fx.monitors : []
  readonly property int gridCols: fx ? Math.round(Model.paramValue(fx.params, "gridCols", 2)) : 2
  readonly property int gridRows: fx ? Math.round(Model.paramValue(fx.params, "gridRows", 2)) : 2
  readonly property string selectedMonitor: fx && fx.params.selectedMonitor ? fx.params.selectedMonitor
    : (monitors.length > 0 ? monitors[0].name : "")
  readonly property int selectedCol: fx ? fx.params.selectedCol : 0
  readonly property int selectedRow: fx ? fx.params.selectedRow : 0

  function currentMonitorRect() {
    if (!fx) return null
    var m = fx.monitorByName(root.selectedMonitor)
    return m
  }

  KeyboardPanel {
    id: kp
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    contentWidth: kp.fittedContentWidth(Style.space(440))
    contentHeight: kp.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      width: parent.width
      spacing: Style.space(14)

      PanelHero {
        width: parent.width
        title: "Grid Snap"
        meta: fx && fx.targetTitle ? fx.targetTitle : "No window focused"
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          Text {
            text: Model.barIcon
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }
      }

      // --- Monitor picker -----------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.monitors.length > 0

        Text {
          text: "Monitor"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: root.monitors

            Rectangle {
              required property var modelData
              readonly property bool selected: modelData.name === root.selectedMonitor
              radius: Style.space(6)
              color: selected ? Qt.darker(root.foreground, 4.0) : "transparent"
              border.width: 1
              border.color: selected ? root.foreground : Qt.darker(root.foreground, 2.0)
              width: label.implicitWidth + Style.space(16)
              height: label.implicitHeight + Style.space(10)

              Text {
                id: label
                anchors.centerIn: parent
                text: parent.modelData.name + "  " + parent.modelData.width + "×" + parent.modelData.height
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.fx) root.fx.setSelection(parent.modelData.name, root.selectedCol, root.selectedRow)
              }
            }
          }
        }
      }

      // --- Grid size steppers ---------------------------------------
      Row {
        width: parent.width
        spacing: Style.space(24)

        GridSizeStepper {
          label: "Columns"
          value: root.gridCols
          onChanged: function(v) { if (root.fx) root.fx.setParam("gridCols", v) }
        }

        GridSizeStepper {
          label: "Rows"
          value: root.gridRows
          onChanged: function(v) { if (root.fx) root.fx.setParam("gridRows", v) }
        }
      }

      // --- Cell picker -------------------------------------------------
      // A visual grid matching the selected monitor's aspect ratio --
      // click a cell to pick it as the snap target.
      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: "Position"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Item {
          id: cellGrid
          width: parent.width
          readonly property var monitorRect: root.currentMonitorRect()
          readonly property real aspect: monitorRect && monitorRect.height > 0
            ? monitorRect.width / monitorRect.height : (16 / 9)
          height: width / aspect

          Grid {
            anchors.fill: parent
            columns: root.gridCols
            rows: root.gridRows
            spacing: Style.space(3)

            Repeater {
              model: root.gridCols * root.gridRows

              Rectangle {
                required property int index
                readonly property int col: index % root.gridCols
                readonly property int row: Math.floor(index / root.gridCols)
                readonly property bool selected: col === root.selectedCol && row === root.selectedRow
                width: (cellGrid.width - Style.space(3) * (root.gridCols - 1)) / root.gridCols
                height: (cellGrid.height - Style.space(3) * (root.gridRows - 1)) / root.gridRows
                radius: Style.space(4)
                color: selected ? root.foreground : Qt.darker(root.foreground, 3.0)
                border.width: 1
                border.color: Qt.darker(root.foreground, 2.0)

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.fx) root.fx.setSelection(root.selectedMonitor, parent.col, parent.row)
                }
              }
            }
          }
        }
      }

      // --- Opacity slider -------------------------------------------
      Repeater {
        model: Model.sliderParamDefs

        Column {
          id: sliderRow
          required property var modelData
          width: column.width
          spacing: Style.space(4)

          readonly property real value: root.fx
            ? Model.paramValue(root.fx.params, modelData.key, modelData.def) : modelData.def

          Text {
            text: sliderRow.modelData.label + "  ·  " + sliderRow.value.toFixed(2)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item {
            id: track
            width: parent.width
            height: Style.space(16)

            readonly property real fraction: Math.max(0, Math.min(1,
              (sliderRow.value - sliderRow.modelData.min) / (sliderRow.modelData.max - sliderRow.modelData.min)))

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              height: Style.space(4)
              radius: height / 2
              color: Qt.darker(root.foreground, 3.0)
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: track.width * track.fraction
              height: Style.space(4)
              radius: height / 2
              color: root.foreground
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              x: Math.max(0, Math.min(track.width - width, track.width * track.fraction - width / 2))
              width: Style.space(12)
              height: Style.space(12)
              radius: width / 2
              color: root.foreground
            }

            MouseArea {
              anchors.fill: parent
              onPressed: (mouse) => updateFromMouse(mouse.x)
              onPositionChanged: (mouse) => { if (pressed) updateFromMouse(mouse.x) }

              function updateFromMouse(mx) {
                if (!root.fx) return
                if (!(track.width > 0)) return
                var fraction = Math.max(0, Math.min(1, mx / track.width))
                var raw = sliderRow.modelData.min + fraction * (sliderRow.modelData.max - sliderRow.modelData.min)
                var stepped = Math.round(raw / sliderRow.modelData.step) * sliderRow.modelData.step
                root.fx.setParam(sliderRow.modelData.key, stepped)
              }
            }
          }
        }
      }

      Text {
        width: parent.width
        visible: root.fx && root.fx.params.opacity < 0.999
        text: "Below 1.0, your real wallpaper/other windows will show through this one -- handy for keeping half an eye on a video while you work in front of it."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      BoolToggleRow {
        width: column.width
        paramKey: "pinOnSnap"
        label: "Pin across workspaces"
        description: "Keeps the snapped window visible no matter which workspace you switch to -- the point of this plugin (watch in one corner while you work anywhere else). Turn off if you'd rather it only show on its own workspace."
      }

      // --- Actions ----------------------------------------------------
      Row {
        width: parent.width
        spacing: Style.space(10)

        Rectangle {
          width: (parent.width - Style.space(10)) * 0.6
          height: Style.space(36)
          radius: Style.space(8)
          color: Qt.darker(root.foreground, 4.0)
          border.width: 1
          border.color: root.foreground

          Text {
            anchors.centerIn: parent
            text: "Snap here"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.fx) root.fx.snap()
          }
        }

        Rectangle {
          width: (parent.width - Style.space(10)) * 0.4
          height: Style.space(36)
          radius: Style.space(8)
          color: "transparent"
          border.width: 1
          border.color: Qt.darker(root.foreground, 2.0)

          Text {
            anchors.centerIn: parent
            text: "Restore"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.fx) root.fx.unsnap()
          }
        }
      }

      Text {
        width: parent.width
        text: root.fx ? root.fx.lastActionSummary : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        visible: root.fx && root.fx.lastError !== ""
        text: root.fx ? root.fx.lastError : ""
        color: "#ff8080"
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  // A "N  [-] [+]" stepper for grid columns/rows -- clamped 1..4 to match
  // Model.paramDefs' range.
  component GridSizeStepper: Row {
    id: stepper
    property string label: ""
    property int value: 2
    signal changed(int v)
    spacing: Style.space(8)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: stepper.label + ":"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      width: Style.space(22); height: Style.space(22)
      radius: Style.space(4)
      color: "transparent"
      border.width: 1
      border.color: Qt.darker(root.foreground, 2.0)
      Text { anchors.centerIn: parent; text: "−"; color: root.foreground; font.family: root.fontFamily }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: stepper.changed(Math.max(1, stepper.value - 1))
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: String(stepper.value)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Rectangle {
      width: Style.space(22); height: Style.space(22)
      radius: Style.space(4)
      color: "transparent"
      border.width: 1
      border.color: Qt.darker(root.foreground, 2.0)
      Text { anchors.centerIn: parent; text: "+"; color: root.foreground; font.family: root.fontFamily }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: stepper.changed(Math.min(4, stepper.value + 1))
      }
    }
  }

  component BoolToggleRow: Column {
    id: boolRow
    property string paramKey: ""
    property string label: ""
    property string description: ""
    spacing: Style.space(4)

    readonly property bool checked: root.fx
      ? Model.paramValue(root.fx.params, boolRow.paramKey, 0) >= 0.5 : false

    Row {
      spacing: Style.space(10)

      ToggleSwitch {
        anchors.verticalCenter: parent.verticalCenter
        checked: boolRow.checked
        foreground: root.foreground
        onToggled: if (root.fx) root.fx.setParam(boolRow.paramKey, boolRow.checked ? 0 : 1)
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: boolRow.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      width: boolRow.width
      visible: boolRow.description !== ""
      text: boolRow.description
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
