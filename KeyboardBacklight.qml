import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "io.github.funkyspider.keyboard-backlight"
  ipcTarget: moduleName
  manageIpc: false

  property bool available: false
  property string deviceName: ""
  property int brightness: 0
  property int maximumBrightness: 0
  property int brightnessPercent: 0
  property real wheelAccumulator: 0
  property var actionQueue: []
  property bool refreshQueued: false

  readonly property string helperPath: String(Qt.resolvedUrl("bin/keyboard-backlight")).replace(/^file:\/\//, "")
  readonly property string configuredDevice: String(setting("device", "") || "").trim()
  readonly property string statusTooltip: root.available
    ? "Keyboard backlight: " + root.brightnessPercent + "%\nScroll to adjust · middle-click to toggle · right-click to turn off"
    : "Keyboard backlight unavailable"

  visible: available
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function clamp(value) {
    return Math.max(0, Math.min(100, Math.round(Number(value))))
  }

  function commandFor(action, value) {
    var command = [root.helperPath, action]
    if (action === "set") command.push(String(root.clamp(value)))
    if (root.configuredDevice !== "") command.push(root.configuredDevice)
    return command
  }

  function applyStatus(output) {
    var fields = String(output || "").trim().split("\t")
    if (fields.length < 5 || fields[0] !== "available") {
      root.available = false
      root.deviceName = ""
      root.brightness = 0
      root.maximumBrightness = 0
      root.brightnessPercent = 0
      return
    }

    root.available = true
    root.deviceName = fields[1]
    root.brightness = Math.max(0, parseInt(fields[2], 10) || 0)
    root.maximumBrightness = Math.max(0, parseInt(fields[3], 10) || 0)
    if (!brightnessSlider.dragging)
      root.brightnessPercent = root.clamp(parseInt(fields[4], 10) || 0)
  }

  function refresh() {
    if (statusProcess.running) {
      root.refreshQueued = true
      return
    }
    statusProcess.command = root.commandFor("status")
    statusProcess.running = true
  }

  function startAction(action, value) {
    actionProcess.command = root.commandFor(action, value)
    actionProcess.running = true
  }

  function runAction(action, value) {
    if (actionProcess.running) {
      var queue = root.actionQueue.slice()
      // Slider releases are absolute values. Only the newest pending value is
      // useful, so replace an older queued set instead of replaying both.
      if (action === "set" && queue.length > 0 && queue[queue.length - 1].action === "set")
        queue[queue.length - 1] = { action: action, value: value }
      else
        queue.push({ action: action, value: value })
      root.actionQueue = queue
      return
    }
    root.startAction(action, value)
  }

  function setBrightness(value) {
    var percent = root.clamp(value)
    root.brightnessPercent = percent
    root.runAction("set", percent)
  }

  function adjustBrightness(delta) {
    root.setBrightness(root.brightnessPercent + delta)
  }

  onConfiguredDeviceChanged: refresh()
  onOpenedChanged: if (opened) refresh()
  onStatusTooltipChanged: {
    if (button.tooltipHovered && root.bar)
      root.bar.showTooltip(button, root.statusTooltip)
  }
  Component.onCompleted: Qt.callLater(refresh)

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function up(): void { root.runAction("up") }
    function down(): void { root.runAction("down") }
    function off(): void { root.runAction("off") }
    function power(): void { root.runAction("toggle") }
    function brightness(percent: string): string {
      root.setBrightness(percent)
      return String(root.clamp(percent))
    }
  }

  Process {
    id: statusProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onRunningChanged: {
      if (running || !root.refreshQueued) return
      root.refreshQueued = false
      Qt.callLater(root.refresh)
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onRunningChanged: {
      if (running) return
      if (root.actionQueue.length > 0) {
        var queue = root.actionQueue.slice()
        var next = queue.shift()
        root.actionQueue = queue
        Qt.callLater(function() { root.startAction(next.action, next.value) })
      } else {
        Qt.callLater(root.refresh)
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"
    tooltipText: root.statusTooltip

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.runAction("off")
      else if (mouseButton === Qt.MiddleButton) root.runAction("toggle")
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      if (!root.available) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return

      var action = wheel.steps > 0 ? "up" : "down"
      for (var i = 0; i < Math.abs(wheel.steps); i++) root.runAction(action)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(330))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(260))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.adjustBrightness(dx * 5)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(14)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            text: "󰌌"
            textFormat: Text.PlainText
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Keyboard Backlight"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.available
                ? (root.brightnessPercent === 0 ? "OFF" : "ILLUMINATED")
                : "UNAVAILABLE"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(brightnessHeader.implicitHeight, percentage.implicitHeight)

            PanelSectionHeader {
              id: brightnessHeader
              text: "BRIGHTNESS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: percentage
              text: Math.round(brightnessSlider.dragging
                ? brightnessSlider.liveValue
                : root.brightnessPercent) + "%"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          CursorSurface {
            width: parent.width
            height: brightnessSlider.implicitHeight + Style.spacing.controlGap
            hasCursor: true
            foreground: root.bar.foreground

            PanelSlider {
              id: brightnessSlider
              bar: root.bar
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              minimum: 0
              maximum: 100
              step: 5
              value: root.brightnessPercent
              integer: true
              tickCount: 11
              onMoved: function(value) { root.brightnessPercent = root.clamp(value) }
              onReleased: function(value) { root.setBrightness(value) }
            }
          }
        }

        Text {
          width: parent.width
          text: "Ctrl+F1  Decrease    ·    Ctrl+F2  Increase"
          wrapMode: Text.WordWrap
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
