import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Device inventory, persisted selection, and the lock lifecycle.
//
// This is a `kind: "service"` plugin entry point: the shell instantiates it
// exactly once, regardless of monitor count (shell.qml's ensureService()),
// and every monitor's Panel.qml bar-widget instance reads this same object
// via `bar.shell.firstPartyServiceFor(<plugin id>)`. That matters here
// specifically because `locked`/`arming` gate whether a hardware disable is
// in effect -- if each monitor held its own copy, locking from one screen
// would leave every other screen's bar icon, overlay, and unlock button
// believing nothing was locked.
//
// Everything that touches Hyprland goes through bin/keyboard-cleaner-lock rather
// than inline hyprctl calls, so a stranded session can be recovered from a
// terminal with the exact same code path the panel uses.
//
// Root is Item, not QtObject, matching every first-party service (idle,
// media): Item carries the default `data` property that lets a plain child
// like IpcHandler attach without an explicit `property IpcHandler x: ...`
// wrapper. It is never made visible -- shell.qml parents services into a
// hidden host Item -- so nothing about being an Item is actually rendered.
Item {
  id: root

  // file:// URL of the plugin folder, minus the scheme, so the bundled scripts
  // can be invoked wherever `omarchy plugin add` put us.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/keyboard-cleaner.json"
  // Mirrors STATE_DIR/STATE_FILE in bin/keyboard-cleaner-lock. Duplicated on
  // purpose: teardown has to clear this file without the script, which removal
  // may already have deleted. Keep the two in step.
  readonly property string stateFilePath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/keyboard-cleaner/locked.json"

  property var keyboards: []          // [{name, label, class, main}]
  property var keyboardSelection: []  // device names armed for locking
  property int autoUnlockSeconds: 120
  property bool showAuxiliary: false

  property bool locked: false
  // True from the moment lock() is called until the devices are actually
  // disabled. The gap is the wait for every physical key to come up, which is
  // usually instant from the bar button and about as long as it takes to let
  // go of SUPER+SHIFT from a keybinding.
  property bool arming: false
  property bool busy: false
  property real remainingSeconds: 0
  property string lastError: ""
  property bool configLoaded: false
  property bool hasStoredSelection: false

  readonly property var keyboardSet: Model.selectionSet(keyboardSelection)
  readonly property var realKeyboards: keyboards.filter(function (d) { return d.class === "keyboard" })
  readonly property var auxiliaryDevices: keyboards.filter(function (d) { return d.class !== "keyboard" })
  readonly property string armBlocker: Model.armBlocker(keyboardSelection)
  readonly property bool canArm: armBlocker === "" && !busy
  readonly property int armedCount: keyboardSelection.length

  // Bar-widget instances (one per monitor) register themselves here so IPC
  // open/close/toggle have a panel to act on. "Primary" is just whichever
  // registered first -- an arbitrary but deterministic choice, matching the
  // arbitrary-first-wins behavior of Quickshell's own IpcHandler registration.
  property var _panels: []
  readonly property var _primaryPanel: _panels.length > 0 ? _panels[0] : null

  function registerPanel(panel) {
    if (_panels.indexOf(panel) === -1) _panels = _panels.concat([panel])
  }

  function unregisterPanel(panel) {
    var at = _panels.indexOf(panel)
    if (at === -1) return
    var next = _panels.slice()
    next.splice(at, 1)
    _panels = next
  }

  function refresh() {
    devicesProcess.command = ["bash", pluginDir + "/bin/keyboard-cleaner-devices"]
    devicesProcess.running = true
  }

  function applyDevices(json) {
    var parsed
    try {
      parsed = JSON.parse(json)
    } catch (e) {
      lastError = "Could not read the device list."
      return
    }
    lastError = ""
    // The script also reports pointers; this release locks keyboards only, so
    // that half of its output is ignored on purpose.
    keyboards = parsed.keyboards || []
  }

  function toggleKeyboard(name) {
    if (locked || arming) return
    keyboardSelection = Model.toggleName(keyboardSelection, name)
    save()
  }

  function setAutoUnlock(seconds) {
    autoUnlockSeconds = seconds
    save()
  }

  property string _lastWritten: ""

  function save() {
    if (!configLoaded) return
    var payload = JSON.stringify({
      keyboards: keyboardSelection,
      autoUnlockSeconds: autoUnlockSeconds,
      showAuxiliary: showAuxiliary
    }, null, 2) + "\n"
    if (payload === _lastWritten) return
    _lastWritten = payload
    configFile.setText(payload)
  }

  // Remembered names are never pruned, so the armed set can name a keyboard
  // that is currently unplugged. Filter at the point of use instead.
  function presentSelection() {
    var present = Model.selectionSet(keyboards.map(function (d) { return d.name }))
    return keyboardSelection.filter(function (name) { return present[name] === true })
  }

  function lock() {
    if (locked || arming || !canArm) return
    var devices = presentSelection()
    if (devices.length === 0) {
      lastError = "None of the armed keyboards are connected."
      return
    }
    busy = true
    arming = true
    lockProcess.command = ["bash", pluginDir + "/bin/keyboard-cleaner-lock", "lock"].concat(devices)
    lockProcess.running = true
  }

  function unlock() {
    if (!locked && !arming) return
    busy = true
    unlockProcess.command = ["bash", pluginDir + "/bin/keyboard-cleaner-lock", "unlock"]
    unlockProcess.running = true
  }

  // `locked` lives only in this QML object, but the hardware disable lives in
  // Hyprland and outlives the shell process. Without restoring it, a shell
  // restart while locked -- a crash, a re-exec, anything short of the graceful
  // hot-reload path -- would leave the bar icon and overlay claiming nothing
  // was locked for a keyboard that is still genuinely dead, breaking the
  // "click any bar icon to unlock" escape hatch.
  //
  // bin/keyboard-cleaner-lock already tracks the real session in
  // $XDG_RUNTIME_DIR/keyboard-cleaner/locked.json (devices + lockedAt), written on
  // lock and cleared on unlock, independent of this QML object's lifetime.
  // `status` reads it back. Runs once, after config load, so autoUnlockSeconds
  // reflects the persisted setting before it's used to judge whether the
  // countdown would already have elapsed.
  function restoreRuntimeState() {
    stateProcess.command = ["bash", pluginDir + "/bin/keyboard-cleaner-lock", "status"]
    stateProcess.running = true
  }

  function applyRuntimeState(json) {
    var parsed
    try {
      parsed = JSON.parse(json)
    } catch (e) {
      return
    }
    var devices = parsed.devices || []
    if (devices.length === 0) return // nothing was locked when the shell went away

    var lockedAt = Number(parsed.lockedAt) || 0
    var elapsed = lockedAt > 0 ? (Date.now() / 1000 - lockedAt) : 0

    if (autoUnlockSeconds > 0 && elapsed >= autoUnlockSeconds) {
      // The auto-unlock window already passed while nothing was watching it.
      // Finish the job: re-enable the devices, clear the runtime state file,
      // restore idle. unlock() requires locked||arming to act, so this is the
      // one place that sets locked before calling it -- correctly, since the
      // hardware really was locked a moment ago.
      locked = true
      unlock()
      return
    }

    locked = true
    remainingSeconds = autoUnlockSeconds > 0 ? Math.max(0, Math.round(autoUnlockSeconds - elapsed)) : 0
    setIdleEnabled(false)
    if (autoUnlockSeconds > 0) countdown.start()
  }

  // A disabled keyboard stops feeding Hyprland's idle timer, so a two-minute
  // wipe would otherwise trip the idle lock and drop the user at a password
  // prompt they cannot type into. Park idle handling for the session.
  function setIdleEnabled(enabled) {
    Quickshell.execDetached(["omarchy-shell", "idle", enabled ? "enable" : "disable"])
  }

  // Being torn down mid-session must not strand a disabled keyboard. This runs
  // when the plugin is disabled or removed, both of which destroy the service
  // while the hardware disable is still in effect in Hyprland -- with the
  // overlay and IPC gone, so nothing would be left to say what happened or to
  // undo it.
  //
  // Two constraints make this awkward, both confirmed by testing against a real
  // `omarchy plugin remove` mid-lock:
  //
  //   1. It cannot call bin/keyboard-cleaner-lock. Removal moves the plugin
  //      folder, and it wins that race -- the script is already gone by the time
  //      the detached process would read it. So the recovery is inlined here,
  //      using only hyprctl and jq, which live on PATH.
  //   2. It cannot use `unlockProcess`. A Process owned by an object being
  //      destroyed can go away before it ever runs. execDetached hands the work
  //      to the system, which survives this object -- and does still fire during
  //      teardown, verified with a marker file.
  //
  // Enabling an already-enabled device is a no-op, so re-enabling the armed set
  // is safe even if part of it was never disabled.
  Component.onDestruction: {
    if (!locked && !arming) return

    var script = ""
    var devices = presentSelection()
    for (var i = 0; i < devices.length; i++)
      script += "hyprctl eval 'hl.device({ name = \"" + devices[i] + "\", enabled = true })' >/dev/null 2>&1; "
    script += "rm -f " + stateFilePath + "; "
    // Retried: during a plugin unload the shell's IPC is briefly unavailable,
    // and a single attempt here loses the race and silently does nothing. Idle
    // staying parked is not cosmetic -- stay-awake persists across reboots, so
    // the machine would never lock or run the screensaver again.
    script += "for i in 1 2 3 4 5; do omarchy-shell idle enable >/dev/null 2>&1 && break; sleep 1; done"

    Quickshell.execDetached(["bash", "-c", script])
  }

  property Process devicesProcess: Process {
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDevices(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0)
        root.lastError = "Device detection failed (exit " + exitCode + ")."
    }
  }

  property Process stateProcess: Process {
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyRuntimeState(text)
    }
  }

  property Process lockProcess: Process {
    running: false
    command: []
    // The script warns here when it gave up waiting for a stuck key; the lock
    // still went through, so this is a notice rather than a failure.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text).indexOf("still held") !== -1)
          root.lastError = "A key was still held — it may read as stuck until you press it again."
      }
    }
    onExited: function (exitCode) {
      root.busy = false
      root.arming = false
      if (exitCode !== 0) {
        root.lastError = "Could not disable the selected devices."
        return
      }
      root.locked = true
      root.remainingSeconds = root.autoUnlockSeconds
      root.setIdleEnabled(false)
      if (root.autoUnlockSeconds > 0)
        root.countdown.start()
    }
  }

  property Process unlockProcess: Process {
    running: false
    command: []
    onExited: function (exitCode) {
      root.busy = false
      root.arming = false
      root.countdown.stop()
      root.locked = false
      root.remainingSeconds = 0
      root.setIdleEnabled(true)
      if (exitCode !== 0)
        root.lastError = "Re-enable reported an error — run omarchy-restart-hyprctl."
    }
  }

  property Timer countdown: Timer {
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      root.remainingSeconds -= 1
      if (root.remainingSeconds <= 0) {
        stop()
        root.unlock()
      }
    }
  }

  property FileView configFile: FileView {
    path: root.configPath
    watchChanges: false
    printErrors: false
    atomicWrites: true

    onLoaded: {
      var stored = {}
      try {
        stored = JSON.parse(text())
      } catch (e) {
        stored = {}
      }
      // An explicit empty array is a real choice ("nothing armed") and must
      // not be re-seeded; only a missing key means first run.
      root.hasStoredSelection = Array.isArray(stored.keyboards)
      root.keyboardSelection = stored.keyboards || []
      root.autoUnlockSeconds = stored.autoUnlockSeconds !== undefined ? stored.autoUnlockSeconds : 120
      root.showAuxiliary = stored.showAuxiliary === true
      root.configLoaded = true
      root.applyStoredAgainstDevices()
      root.checkRuntimeStateOnce()
    }

    onLoadFailed: {
      root.hasStoredSelection = false
      root.configLoaded = true
      root.applyStoredAgainstDevices()
      root.checkRuntimeStateOnce()
    }
  }

  // First run only: arm exactly the devices udev calls real keyboards.
  //
  // Deliberately does NOT prune names that are missing from the current
  // device list. A probe that comes back short -- during shell startup, or
  // while Hyprland is re-enumerating -- would otherwise permanently delete a
  // keyboard from the armed set. Absent devices simply do not render, and
  // lock() filters them out at the point of use.
  function applyStoredAgainstDevices() {
    if (!configLoaded || keyboards.length === 0 || hasStoredSelection)
      return
    keyboardSelection = Model.defaultKeyboardSelection(keyboards)
    hasStoredSelection = true
    save()
  }

  property bool runtimeStateChecked: false

  function checkRuntimeStateOnce() {
    if (runtimeStateChecked) return
    runtimeStateChecked = true
    restoreRuntimeState()
  }

  onKeyboardsChanged: applyStoredAgainstDevices()

  Component.onCompleted: refresh()

  // Single IPC target for the whole plugin. Quickshell's IpcHandler
  // registration is winner-take-all per target string -- the first handler
  // registered for "keyboard-cleaner" would win ALL of its methods, silently
  // dropping every other instance's. Living here, on the one true singleton,
  // means there is only ever one handler to register in the first place.
  IpcHandler {
    target: "keyboard-cleaner"
    function open(): void { if (root._primaryPanel) root._primaryPanel.open() }
    function close(): void { if (root._primaryPanel) root._primaryPanel.close() }
    function show(): void { if (root._primaryPanel) root._primaryPanel.open() }
    function hide(): void { if (root._primaryPanel) root._primaryPanel.close() }
    function toggle(): void { if (root._primaryPanel) root._primaryPanel.toggle() }
    function lock(): string {
      if (root._primaryPanel) root._primaryPanel.close()
      root.lock()
      return root.canArm ? "locking" : root.armBlocker
    }
    function unlock(): string { root.unlock(); return "unlocking" }
    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        arming: root.arming,
        devices: root.keyboardSelection,
        remaining: root.remainingSeconds
      })
    }
  }
}
