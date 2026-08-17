# omakeyclean

Disable your keyboard so you can wipe it down, and unlock it with the mouse.

An Omarchy bar widget. Click the keyboard icon, pick which input devices to
freeze, and hold the mouse on the unlock button when you're done.

## Why per-device disable, and not a submap

The obvious Hyprland approach is a submap with a `catchall` bind. It does not
work. In `KeybindManager.cpp`, binds are filtered by modmask *before* the
catchall branch is reached, so any key pressed with a modifier held — `Ctrl+C`,
`Alt+Tab`, `Super+Q` — passes straight through to the focused window. Modifiers
themselves never reach the keybind manager at all; `onKeyboardMod()` delivers
them to clients independently. A submap lock leaks.

This plugin uses Hyprland's per-device `enabled` flag instead:

```bash
hyprctl eval 'hl.device({ name = "razer-razer-huntsman-v2", enabled = false })'
```

`CInputManager::onKeyboardKey` and `onKeyboardMod` both return early on
`!m_enabled`, so a disabled keyboard delivers nothing — no keys, no modifiers,
no keybinds, no IME, and it does not even reset the idle timer. It needs no
root, no daemon, and no evdev grab.

## What counts as a keyboard

`hyprctl devices` does not list keyboards. It lists devices with a keyboard
*capability*, which on a normal desktop also includes power and sleep buttons,
microphone and headset endpoints, laptop WMI hotkey stubs, and the
consumer-control interfaces of mice. On the author's machine that is 16
entries, only 5 of which you can type on.

Worse, Hyprland's `main` keyboard is routinely one of the impostors — a WMI
hotkey stub or the virtual IME keyboard — so "just disable the main one" is
actively wrong.

`bin/omakeyclean-devices` resolves this by joining Hyprland's device list
against udev, which already draws the right line: `ID_INPUT_KEYBOARD=1` is set
only for devices carrying a full alphanumeric key range, while `ID_INPUT_KEY=1`
covers anything that merely emits key events.

The join is by name-slug, because Hyprland exposes no evdev node — it lowercases
the libinput name, replaces spaces with dashes, and appends `-1`, `-2` to
disambiguate collisions. The script tries an exact match first and a
suffix-stripped match second.

Run it yourself:

```bash
./bin/omakeyclean-devices | jq .
```

Real keyboards are preselected. The classification is a strong hint, not
gospel, so the panel lets you arm anything — the impostors live behind the
"other key-emitting devices" reveal.

## Safety

The only way out of a locked session is the mouse, so:

- **Only keyboards are ever disabled.** Pointing devices are left alone by
  construction, so the unlock button is always reachable. (Pointer locking is
  deferred to a later iteration.)
- **Auto-unlock** is on by default (2 minutes, configurable, can be turned off).
- **Idle is parked** for the duration via `omarchy-shell idle disable`. A
  disabled keyboard stops feeding the idle timer, so without this a long wipe
  would trip the idle lock and drop you at a password prompt you cannot type
  into.
- **Session state lives in `$XDG_RUNTIME_DIR`**, never in
  `~/.local/state/omarchy/toggles/hypr/`. Hyprland sources that directory on
  every config reload; persisting a keyboard disable there would survive reboot
  and lock you out permanently.

### If you get stuck

In escalating order:

1. Hold the unlock button on the overlay.
2. Wait for auto-unlock.
3. Click the bar icon — it unlocks immediately while a session is active.
4. From another machine over SSH: `~/.config/omarchy/plugins/omakeyclean/bin/omakeyclean-lock unlock`
5. **Reload Hyprland's config.** `omarchy-restart-hyprctl`, a theme switch, or
   touching `~/.config/hypr/hyprland.lua` all clear `m_deviceConfigs`, and every
   device defaults back to enabled.
6. **A TTY.** The block is compositor-side, so `Ctrl+Alt+F2` is unaffected.

Because of (5), a theme switch mid-wipe will silently unlock you. That is a
deliberate trade: the panic button is worth more than surviving a reload.

## Install

```bash
omarchy plugin add https://github.com/<you>/omakeyclean.git --enable
```

Then place the widget:

```bash
omarchy bar move omakeyclean --section right
```

## Optional keybinding

Omarchy plugins cannot ship keybindings — the installer never runs plugin code
or writes Hyprland config. Add this to `~/.config/hypr/bindings.lua` yourself:

```lua
o.bind("SUPER + SHIFT + K", "Clean keyboard", "omarchy-shell omakeyclean lock")
```

## IPC

```bash
omarchy-shell omakeyclean toggle    # open/close the panel
omarchy-shell omakeyclean lock      # start a cleaning session
omarchy-shell omakeyclean unlock    # end it
omarchy-shell omakeyclean status    # JSON: locked, arming, devices, remaining
```

## Held keys

A key held at the moment its device is disabled never delivers its release:
`onKeyboardKey` returns early on `!m_enabled`, so the focused client keeps that
key latched forever. The keybinding trigger hits this every time — SUPER and
SHIFT are both physically down at the instant the bind fires.

So locking waits for every physical key to come up before disabling anything.
The overlay shows "Release all keys" during that window. From the bar button it
is imperceptible; from a keybinding it lasts as long as you keep holding.

State comes from `hl.is_key_down`, which reflects Hyprland's physical `m_pressed`
tracking. `hyprctl eval` only ever prints "ok" and never the chunk's value, so
the Lua side writes its answer to a file under `$XDG_RUNTIME_DIR` that the
script reads back. Inspect it live:

```bash
while :; do ./bin/omakeyclean-lock keys-down; sleep 0.3; done
```

The wait is bounded by `OMAKEYCLEAN_KEY_TIMEOUT` (default 5s) so a physically
stuck key cannot make the plugin unusable. On timeout it locks anyway and warns,
and the panel surfaces the warning.

## Local development

This is not a standalone app — it's QML that runs inside Quickshell, which
runs inside Hyprland/Omarchy. There is no build step or binary to launch;
you deploy the plugin into Omarchy's plugin directory and it loads as part
of the live shell.

Deploy your working copy (this is a real directory, not a symlink, so you
need to re-copy after every edit):

```bash
cp -r ./* ~/.config/omarchy/plugins/omakeyclean/
```

Validate before reloading, to catch manifest/QML errors early:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/omakeyclean
```

Reload the shell to pick up changes:

```bash
omarchy-restart-shell
```

### Debugging

- **Live logs**: `journalctl --user -f` while you interact with the widget —
  QML errors and `IpcHandler` registration issues show up here.
- **IPC, without touching the UI**:
  ```bash
  omarchy-shell omakeyclean status   # JSON: locked, arming, devices, remaining
  omarchy-shell omakeyclean lock
  omarchy-shell omakeyclean unlock
  omarchy-shell omakeyclean toggle
  ```
- **Device classification, standalone**:
  ```bash
  ./bin/omakeyclean-devices | jq .
  ```
- **Lock script, standalone** (bypasses QML entirely):
  ```bash
  ./bin/omakeyclean-lock status
  ./bin/omakeyclean-lock keys-down   # watch held-key detection live
  ```
- **Hyprland-side state**:
  ```bash
  hyprctl devices -j | jq '.keyboards[] | {name, enabled}'
  hyprctl layers   # confirm the lock overlay surface is present when locked
  ```
- **Crash-recovery path**: `kill -9` the running `quickshell` process while
  locked, then let it restart — `locked` state should restore from
  `$XDG_RUNTIME_DIR/omakeyclean/locked.json` rather than being lost.

### If you lock yourself out while testing

Reloading Hyprland's config resets every device to enabled:

```bash
omarchy-restart-hyprctl
```

Or drop to a TTY with `Ctrl+Alt+F2` — the block is compositor-side and does
not affect TTYs.

## Known gaps

- Hotplugging a keyboard mid-session leaves it enabled; it was not in the
  armed set.
- Pointer locking (touchpad while wiping a laptop keyboard) is not implemented.
  `bin/omakeyclean-devices` already reports pointers; the UI ignores them.

## License

MIT
