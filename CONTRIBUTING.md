# Contributing

Thanks for looking. This is a small plugin maintained in spare time — expect up
to a week for a reply, and don't read silence as disinterest.

## Start here

**Small and obvious** — a typo, a broken link, a one-line fix? Just open a pull
request. No issue needed.

**Anything bigger** — new features, refactors, changes to how locking works?
**Open an issue first** and let's agree on the approach. This isn't
bureaucracy: the lock mechanism has some non-obvious constraints (see
[How it works](#how-it-works)), and I'd rather spend your time well than turn
down a finished PR.

**Found a way to get someone permanently locked out of their keyboard?** Don't
open a public issue — see [Security](#security).

## Branch flow

```
main            <- released, tagged versions only
  development   <- integration branch, target your PR here
    fix/...     <- bug fixes
    feat/...    <- new functionality
    chore/...   <- docs, refactors, tooling, no behavior change
```

`main` and `development` are both permanent, protected against deletion and
force-push. Everything under them — `fix/…`, `feat/…`, `chore/…` — is
expected to be short-lived and is deleted automatically on merge; that's the
repo-wide "delete branch on merge" setting working as intended for *those*
branches only.

Open pull requests against `development`, not `main`. `main` only moves forward
via a PR from `development` when a release is cut, and is branch-protected —
direct pushes are rejected for everyone, maintainer included.

GitHub will default your PR's base to `main`. Change it to `development` in the
dropdown before submitting. If you forget, say so in the PR and I'll retarget
it — it's not a problem.

## Local development

This is not a standalone app — it's QML that runs inside Quickshell, which runs
inside Hyprland/Omarchy. There is no build step or binary to launch; you deploy
the plugin into Omarchy's plugin directory and it loads as part of the live
shell.

Deploy your working copy:

```bash
DEST=~/.config/omarchy/plugins/roymelgarv.omarchy-keyboard-cleaner
mkdir -p "$DEST"
rsync -a --delete --exclude '.git' ./ "$DEST/"
```

`rsync --delete` rather than `cp -r` on purpose: this is a real directory, not a
symlink, so you re-deploy after every edit — and `cp` leaves deleted files
behind, which produces phantom bugs that are miserable to chase.

Saving a file under `~/.config/omarchy/plugins/` hot-reloads the plugin, so
often that's all you need. If a change doesn't take:

```bash
omarchy plugin validate "$DEST"   # catch manifest/QML errors early
omarchy-restart-shell             # full reload
```

### Debugging

- **Live logs**: `journalctl --user -f` while you interact with the widget —
  QML errors and `IpcHandler` registration issues show up here.
- **IPC, without touching the UI**:
  ```bash
  omarchy-shell keyboard-cleaner status   # JSON: locked, arming, devices, remaining
  omarchy-shell keyboard-cleaner lock
  omarchy-shell keyboard-cleaner unlock
  omarchy-shell keyboard-cleaner toggle
  ```
- **Device classification, standalone**:
  ```bash
  ./bin/keyboard-cleaner-devices | jq .
  ```
- **Lock script, standalone** (bypasses QML entirely):
  ```bash
  ./bin/keyboard-cleaner-lock status
  while :; do ./bin/keyboard-cleaner-lock keys-down; sleep 0.3; done
  ```
  **Never hand a real device name to `lock` by hand.** `hl.device()` no-ops
  silently on a name it does not recognise and still returns `ok`, so
  `lock <real-keyboard> <invented-name>` exits 0 having genuinely disabled the
  real one — mixing in a fake name to keep the command "safe" buys nothing.
  Exercise failure paths with names that are *all* invented, and finish every
  session with a plain `./bin/keyboard-cleaner-lock unlock` — no shims, no
  environment overrides.

  Two ways to strand a device while testing, both easy to hit:

  - `rm`-ing `$XDG_RUNTIME_DIR/keyboard-cleaner/locked.json` throws away the
    only record of what is disabled. A later `unlock` restores whatever the
    *newest* state file names, and anything disabled before you deleted it
    stays disabled with nothing pointing at it.
  - Overriding `XDG_RUNTIME_DIR` to isolate state also moves Hyprland's socket
    out from under `hyprctl`, so every `eval` fails. The run looks like a
    device-level failure and is really a lost socket.

  If you do strand one, the recovery is the same as for any lockout below —
  or just lock and unlock once through the panel, which re-enables the whole
  armed set.
- **Hyprland-side state**: you cannot read a device's `enabled` flag back.
  `hyprctl devices -j` carries an `enabled` key, but it is `null` for every
  device even mid-session; `hl.get_config('device:<name>:enabled')` returns nil
  while resolving ordinary options fine; and
  `hyprctl getoption 'device[<name>]:enabled'` answers "no such option"
  (all checked on Hyprland 0.56.2). `hl.device()` is a setter with no getter
  beside it. So the state file is the only record of what is disabled, and
  "I checked Hyprland and the keyboard is fine" is not a claim this codebase
  can support — end tests with `unlock`, not with an inspection.
  ```bash
  ./bin/keyboard-cleaner-lock status   # the only honest answer
  hyprctl layers   # confirm the lock overlay surface is present when locked
  ```
- **Crash recovery**: `kill -9` the running `quickshell` process while locked,
  then let it restart — `locked` should restore from
  `$XDG_RUNTIME_DIR/keyboard-cleaner/locked.json` rather than being lost.

### If you lock yourself out while testing

You will, at least once. Reloading Hyprland's config resets every device to
enabled:

```bash
omarchy-restart-hyprctl
```

Or drop to a TTY with `Ctrl+Alt+F2` — the block is compositor-side and does not
affect TTYs. Worst case, reboot: session state lives in `$XDG_RUNTIME_DIR` and
never survives one.

## Before opening a PR

There's no CI yet, so this is manual. Required:

```bash
omarchy plugin validate <plugin-dir>   # must exit 0
```

Then actually run it: lock and unlock through the panel, confirm the overlay
appears and clears, and check `journalctl --user` for anything new. Tell me what
you ran in the PR — "tested" on its own doesn't help me review a change that can
brick someone's keyboard.

If you have `qmllint` available, `qmllint -I "$OMARCHY_PATH/shell" *.qml` is
useful, but it needs Omarchy's QML import path resolved correctly and is easy to
get spurious failures from. Don't let it block you.

## Scope

Changes that touch the lock mechanism — device disable/enable, held-key
handling, idle parking — get more scrutiny than anything else. A bug there means
someone's keyboard doesn't come back.

Welcome:

- Bug fixes, especially in recovery and teardown paths
- Pointer locking (touchpad while wiping a laptop keyboard) — a listed known
  gap; `bin/keyboard-cleaner-devices` already reports pointers
- Hotplug handling during a session
- Accessibility and theme correctness in the panel and overlay

Probably not:

- **Anything that needs root, a daemon, a setuid helper, or an evdev grab.** The
  whole design rests on being compositor-side and unprivileged.
- **Anything that persists a device-disable to disk** outside
  `$XDG_RUNTIME_DIR` — writing to `~/.local/state/omarchy/toggles/hypr/` would
  survive reboot and lock someone out permanently.
- **Turning this into a screen locker.** It's a cleaning aid; `hyprlock` already
  exists and the overlay deliberately takes no keyboard focus.
- **Removing an escape hatch** to make the lock "stronger." Every recovery path
  in the README is load-bearing.

If you want one of the "probably not" items anyway, open an issue and make the
case — these are defaults, not vetoes.

## Security

If you find a way to strand a keyboard, defeat every recovery path, or execute
something unintended through a device name or config value, please report it
privately rather than in a public issue:

- GitHub → **Security** → **Report a vulnerability** on this repo, or
- the Omarchy marketplace's
  [private security report form](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/security/advisories/new)

I'll credit you in the fix unless you'd rather I didn't.

## Licensing

By opening a pull request you agree your contribution ships under this project's
[MIT license](LICENSE). There's no CLA and nothing to sign.

---

## How it works

Background for changing the lock mechanism. You don't need any of this to fix a
typo or adjust the panel.

### Why per-device disable, and not a submap

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

### What counts as a keyboard

`hyprctl devices` does not list keyboards. It lists devices with a keyboard
*capability*, which on a normal desktop also includes power and sleep buttons,
microphone and headset endpoints, laptop WMI hotkey stubs, and the
consumer-control interfaces of mice. On a typical desktop that list runs to a
dozen or more entries, only a handful of which you can actually type on.

Worse, Hyprland's `main` keyboard is routinely one of the impostors — a WMI
hotkey stub or the virtual IME keyboard — so "just disable the main one" is
actively wrong.

`bin/keyboard-cleaner-devices` resolves this by joining Hyprland's device list
against udev, which already draws the right line: `ID_INPUT_KEYBOARD=1` is set
only for devices carrying a full alphanumeric key range, while `ID_INPUT_KEY=1`
covers anything that merely emits key events.

The join is by name-slug, because Hyprland exposes no evdev node — it lowercases
the libinput name, replaces spaces with dashes, and appends `-1`, `-2` to
disambiguate collisions. The script tries an exact match first and a
suffix-stripped match second.

Real keyboards are preselected. The classification is a strong hint, not gospel,
so the panel lets you arm anything — the impostors live behind the "other
key-emitting devices" reveal.

### Held keys

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
script reads back.

The wait is bounded by `KEYBOARD_CLEANER_KEY_TIMEOUT` (default 5s) so a
physically stuck key cannot make the plugin unusable. On timeout it locks anyway
and warns, and the panel surfaces the warning.
