import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget + popout for omakeyclean. Layout follows the Omarchy panel
// vocabulary used by the network and bluetooth panels: PanelHero at the top
// with a trailing switch, a stat grid, then PanelSeparator/PanelSectionHeader
// pairs introducing each list of rows.
Panel {
  id: root
  moduleName: "omakeyclean"
  ipcTarget: "omakeyclean"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: (!!service && service.locked) ? (bar ? bar.urgent : Color.urgent) : barForeground

  readonly property var autoUnlockOptions: [
    { value: "60",  label: "1 min" },
    { value: "120", label: "2 min" },
    { value: "300", label: "5 min" },
    { value: "0",   label: "Off" }
  ]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened && service) {
    service.refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function startCleaning() {
    if (!service || !service.canArm) return
    root.close()
    service.lock()
  }

  // The plugin's `kind: "service"` entry point (Service.qml) is instantiated
  // once, shell-wide, regardless of monitor count -- this looks up that same
  // instance rather than owning one locally. The property stays named
  // `service` so every read below is unaffected; only its nullability
  // changes, since the singleton may not have finished loading yet.
  readonly property var service: bar?.shell?.firstPartyServiceFor("omakeyclean") ?? null

  // Which physical monitor this bar-widget instance actually renders on.
  // `bar` carries no per-screen identity -- Bar.qml injects the SAME single
  // Bar instance into every monitor's copy of a widget, per its own
  // `target.bar = root` -- so it cannot be used to tell monitors apart.
  // Vanilla Qt's `Window.window.screen` attached property doesn't track
  // Quickshell's own per-screen PanelWindow layer surfaces either (measured
  // empirically: it returned the same screen for both instances). Quickshell
  // provides its own `QsWindow` attached property for exactly this, used the
  // same way by the first-party Tray widget (bar/widgets/Tray.qml).
  readonly property var currentScreen: QsWindow.window ? QsWindow.window.screen : null

  // Lets the singleton's IpcHandler (which has no monitor of its own) target
  // a real panel for open/close/toggle. See Service.qml's _primaryPanel.
  onServiceChanged: if (service) service.registerPanel(root)
  Component.onDestruction: if (service) service.unregisterPanel(root)

  // Every unqualified `service` reference in this block MUST be written as
  // `root.service`. LockOverlay.qml declares its own `property var service`,
  // so a bare `service: service` here binds LockOverlay's property to
  // itself -- a QML property-shadowing footgun that silently produces an
  // always-null self-reference instead of forwarding Panel's real service.
  // (This is how the overlay went untested and broken from the day it was
  // written: `visible` never turned true because it read the same
  // permanently-null shadowed name.)
  LockOverlay {
    visible: !!root.service && (root.service.locked || root.service.arming)
    service: root.service
    screen: root.currentScreen
    foreground: root.foreground
    fontFamily: root.fontFamily
    onUnlockRequested: if (root.service) root.service.unlock()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: (!!service && service.locked) ? "󰌾" : "󰌌"
          color: root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }
    }
    onPressed: function (buttonCode) {
      // A locked session must be escapable from the bar too, in case the
      // overlay ends up on a monitor that is off. Also the reason every
      // monitor must share one Service: this has to work regardless of
      // which screen's icon actually triggered the lock.
      if (!service) return
      if (service.locked || service.arming) service.unlock()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------------------ hero
          PanelHero {
            id: hero
            width: parent.width
            title: "Keyboard"
            meta: service ? Model.statusMeta(service.locked, service.arming, service.remainingSeconds, service.autoUnlockSeconds) : "Loading…"
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: (!!service && service.locked) ? "󰌾" : "󰌌"
                color: (!!service && service.locked) ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              ToggleSwitch {
                id: lockSwitch
                checked: !!service && (service.locked || service.arming)
                busy: !!service && service.busy
                enabled: !!service && (service.locked || service.canArm)
                foreground: hero.foreground
                onToggled: {
                  if (!service) return
                  if (service.locked) service.unlock()
                  else root.startCleaning()
                }

                PanelToolTip {
                  visible: lockSwitch.containsMouse
                  text: (!!service && service.locked) ? "Unlock now" : "Lock and start cleaning"
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          // ------------------------------------------------------- stat grid
          GridLayout {
            width: parent.width
            columns: 4
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap

            InfoLabel { text: "Keyboards" }
            InfoValue { text: (service ? service.keyboardSelection.length : 0) + " armed" }
            InfoLabel { text: "Detected" }
            InfoValue { text: service ? String(service.realKeyboards.length) : "0" }

            InfoLabel { text: "Auto-unlock" }
            InfoValue {
              text: (!!service && service.autoUnlockSeconds > 0) ? Model.formatCountdown(service.autoUnlockSeconds) : "Off"
            }
          }

          // Blockers and errors share one line so the panel height is stable.
          Text {
            visible: text !== ""
            width: parent.width
            text: service ? (service.lastError !== "" ? service.lastError : service.armBlocker) : ""
            color: (!!service && service.lastError !== "") ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // -------------------------------------------------- auto-unlock row
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "AUTO-UNLOCK"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ButtonGroup {
              width: parent.width
              options: root.autoUnlockOptions
              value: service ? String(service.autoUnlockSeconds) : "120"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: false
              onChanged: function (value) { if (service) service.setAutoUnlock(parseInt(value, 10)) }
            }
          }

          // ----------------------------------------------------- keyboard list
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "KEYBOARDS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: !service || service.realKeyboards.length === 0
              width: parent.width
              text: "No keyboards detected."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: service ? service.realKeyboards : []
              DeviceRow {
                required property var modelData
                width: parent.width
                device: modelData
                kind: "keyboard"
                selected: !!service && service.keyboardSet[modelData.name] === true
                onToggled: if (service) service.toggleKeyboard(modelData.name)
              }
            }
          }

          // --------------------------------------------- auxiliary (collapsed)
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(auxHeader.implicitHeight, auxToggle.implicitHeight)

              PanelSectionHeader {
                id: auxHeader
                text: "OTHER KEY-EMITTING DEVICES"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelActionButton {
                id: auxToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: (!!service && service.showAuxiliary) ? "󰅃" : "󰅀"
                tooltipText: (!!service && service.showAuxiliary) ? "Hide" : "Show"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (service) { service.showAuxiliary = !service.showAuxiliary; service.save() }
              }
            }

            Text {
              visible: !!service && service.showAuxiliary
              width: parent.width
              text: "Hyprland reports these as keyboards, but udev says they carry no typeable key range — power buttons, headset controls, hotkey stubs. Lock them only if a stray key is coming from one."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: (!!service && service.showAuxiliary) ? service.auxiliaryDevices : []
              DeviceRow {
                required property var modelData
                width: parent.width
                device: modelData
                kind: "auxiliary"
                selected: !!service && service.keyboardSet[modelData.name] === true
                onToggled: if (service) service.toggleKeyboard(modelData.name)
              }
            }
          }
        }
      }
    }
  }

  // A device row: glyph, label, Hyprland device name, and an arm switch.
  component DeviceRow: CursorSurface {
    id: deviceRow
    property var device: null
    property string kind: "keyboard"
    property bool selected: false

    signal toggled()

    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: (!!service && (service.locked || service.arming)) ? Qt.ArrowCursor : Qt.PointingHandCursor
      enabled: !service || (!service.locked && !service.arming)
      onClicked: deviceRow.toggled()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: Model.deviceGlyph(deviceRow.kind)
        color: deviceRow.selected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: Model.prettyLabel(deviceRow.device ? deviceRow.device.label : "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: deviceRow.device ? deviceRow.device.name : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      ToggleSwitch {
        checked: deviceRow.selected
        interactive: false
        foreground: root.foreground
        trackHeight: Style.space(18)
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}
