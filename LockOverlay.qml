import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Fullscreen layer-shell surface shown while the keyboard is disabled.
//
// keyboardFocus stays None on purpose. The overlay is decoration and a mouse
// target -- the actual block is Hyprland's per-device `enabled` flag, not a
// focus trick -- so taking exclusive keyboard focus would buy nothing and
// would make the surface harder to recover from if it ever wedged.
PanelWindow {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  // Holding rather than clicking: a cleaning cloth dragged over the mouse is
  // very good at producing a stray click, and a stray click that ends the
  // session mid-wipe defeats the point.
  readonly property int holdMillis: 1500
  property real holdProgress: 0

  // Arming is the window between "lock requested" and "devices disabled",
  // spent waiting for every physical key to come up. Showing it explicitly is
  // the whole point: from a keybinding the user is still holding SUPER+SHIFT,
  // and this is what tells them to let go.
  readonly property bool arming: !!service && service.arming && !service.locked

  signal unlockRequested()

  visible: false
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "keyboard-cleaner-lock"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.72)
  }

  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(80), Style.space(420))
    implicitHeight: cardColumn.implicitHeight + Style.space(36)
    radius: Style.cornerRadius
    color: Color.popups.background
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

    Column {
      id: cardColumn
      anchors.centerIn: parent
      width: parent.width - Style.space(36)
      spacing: Style.space(14)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.arming ? "󰌌" : "󰌾"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display * 1.6
      }

      Text {
        width: parent.width
        text: root.arming ? "Release all keys" : "Keyboard locked"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        width: parent.width
        text: {
          if (!root.service)
            return ""
          if (root.arming)
            return "Waiting for every key to come up — a key held now would read as stuck afterwards."
          return Model.countLabel(root.service.lockedCount, "keyboard") + " disabled — safe to wipe"
        }
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      // Hold target. The fill sweeps left-to-right as the press is held so the
      // progress is legible without a separate spinner.
      BorderSurface {
        id: holdButton
        visible: !root.arming
        width: parent.width
        implicitHeight: Style.spacing.controlHeight + Style.space(12)
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.foreground, Color.accent)
        borderSpec: Border.controlSpec(holdArea.containsMouse ? "hover-cursor" : "normal", root.foreground, Color.accent)
        clip: true

        Rectangle {
          height: parent.height
          width: parent.width * root.holdProgress
          color: Style.selectedFillFor(root.foreground, Color.accent)
        }

        Text {
          anchors.centerIn: parent
          text: root.holdProgress > 0 ? "Keep holding…" : "Hold to unlock"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        MouseArea {
          id: holdArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPressed: holdAnimation.start()
          onReleased: { holdAnimation.stop(); root.holdProgress = 0 }
          onCanceled: { holdAnimation.stop(); root.holdProgress = 0 }
          onExited: { holdAnimation.stop(); root.holdProgress = 0 }
        }

        NumberAnimation {
          id: holdAnimation
          target: root
          property: "holdProgress"
          from: 0
          to: 1
          duration: root.holdMillis
          onFinished: {
            root.holdProgress = 0
            root.unlockRequested()
          }
        }
      }

      // Errors have to be legible from here. The panel's error line
      // (Panel.qml) lives inside the popout, which is shut during a session --
      // so on the one failure that matters, a partial re-enable that leaves
      // keyboards dead, this overlay is the only surface the user is looking at.
      Text {
        width: parent.width
        visible: !root.arming && !!root.service && root.service.lastError !== ""
        text: root.service ? root.service.lastError : ""
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        // Suppressed once something has gone wrong: if unlocking failed, the
        // countdown either already fired or is about to fail the same way, and
        // promising an automatic recovery that is not coming is worse than
        // saying nothing.
        visible: !root.arming && !!root.service
          && root.service.autoUnlockSeconds > 0 && root.service.lastError === ""
        text: root.service ? "Unlocks automatically in " + Model.formatCountdown(root.service.remainingSeconds) : ""
        color: Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        width: parent.width
        // Shown whenever auto-unlock cannot be relied on: either it is switched
        // off, or an error means the in-GUI paths may not work at all. This is
        // the last escape hatch, so it must be on screen exactly then.
        visible: !root.arming && !!root.service
          && (root.service.autoUnlockSeconds <= 0 || root.service.lastError !== "")
        // Full path on purpose: the script is bundled with the plugin and is
        // never on PATH, so a bare command name would fail for the one user who
        // most needs this to work as typed.
        text: root.service
          ? "Stuck? Switch to a TTY with Ctrl+Alt+F2 and run\n" + root.service.pluginDir + "/bin/keyboard-cleaner-lock unlock"
          : ""
        color: Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }
}
