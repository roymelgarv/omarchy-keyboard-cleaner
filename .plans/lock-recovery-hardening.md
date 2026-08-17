# Fix two lock-recovery failures

## Context

A review of `development` found two High-severity bugs, both in the paths that
are supposed to *get a user out* of a locked keyboard. Neither is cosmetic: this
plugin deliberately disables input devices, so a failure in recovery means
someone's keyboard doesn't come back.

**1. Teardown breaks on an apostrophe in a device name.**
`Service.qml`'s `Component.onDestruction` builds a `bash -c` string by
interpolating device names into a single-quoted `hyprctl eval '...'`. A libinput
name containing `'` (USB product strings do) makes the *entire* script
unparseable, so nothing in it runs. Reproduced:

```
hyprctl eval 'hl.device({ name = "bob's keyboard", enabled = true })' >/dev/null 2>&1; rm -f …
bash: -c: line 0: unexpected EOF while looking for matching `"'
```

The `rm -f` of the state file and the `omarchy-shell idle enable` retry loop are
in the same string, so the blast radius is: keyboard stays disabled, stale
`locked.json` left behind, **and idle stays parked** — which the code's own
comment notes survives reboots, meaning the machine never locks or runs the
screensaver again.

**2. The held-key probe fails open.**
`held_keys()` truncates `$PROBE_FILE`, runs `hyprctl eval … || true`, then cats
the file. If the eval fails or the Lua chunk errors, the file stays empty —
indistinguishable from "no keys are held." `wait_for_key_release` returns success
immediately and the disable lands on a held keyboard, producing exactly the
latched-key bug the mechanism exists to prevent.

Outcome: teardown survives any device name, and an unreadable probe is treated as
"keys might be held" rather than "all clear."

## Git state

Branch `fix/lock-recovery-hardening` **already exists locally**, created off
`development` at `23dd487`, clean and checked out. It has no upstream yet.

First actions: write this plan to `.plans/lock-recovery-hardening.md`, commit,
and `git push -u origin fix/lock-recovery-hardening` so the Omarchy PC can pick
it up. Delete `.plans/` in this same branch once the work is done, so it never
reaches `development`, `main`, or the marketplace package.

## Fix 1 — `Service.qml` teardown (`Component.onDestruction`, ~line 226)

Stop interpolating untrusted strings into shell source. Pass them as `argv` and
use a Lua long-bracket literal so neither bash nor Lua needs escaping.

Replace the script-building block with a static script plus arguments:

```qml
// Device names and paths are passed as positional arguments, never
// interpolated: a libinput name containing a quote or apostrophe would
// otherwise break the shell quoting and silently discard this entire
// script -- including the idle restore below, which must not be lost.
// The Lua string uses a long bracket ([==[ ]==]) so it needs no escaping
// either.
var script =
  'state=$1; shift; ' +
  'for d in "$@"; do hyprctl eval "hl.device({ name = [==[$d]==], enabled = true })" >/dev/null 2>&1; done; ' +
  'rm -f "$state"; ' +
  // Retried: during a plugin unload the shell's IPC is briefly unavailable,
  // and a single attempt here loses the race and silently does nothing. Idle
  // staying parked is not cosmetic -- stay-awake persists across reboots, so
  // the machine would never lock or run the screensaver again.
  'for i in 1 2 3 4 5; do omarchy-shell idle enable >/dev/null 2>&1 && break; sleep 1; done'

Quickshell.execDetached(
  ["bash", "-c", script, "keyboard-cleaner-teardown", stateFilePath].concat(presentSelection()))
```

With `bash -c <script> <name> <args…>`, `$0` is the name and `$1…` the
arguments — hence `state=$1; shift` before the `"$@"` loop.

Do **not** add `set -e` to this script: the idle restore has to run even if a
`hyprctl` call or the `rm` fails.

## Fix 2 — `bin/keyboard-cleaner-lock` probe

### 2a. Sentinel so failure is detectable (`held_keys`, ~line 52)

Have the Lua chunk write an `ok:` prefix. Then "file absent or unprefixed" means
the probe didn't run, and `ok:` with nothing after it means genuinely no keys
held. Also switch the `$PROBE_FILE` path in the Lua to a long bracket, for the
same reason as Fix 1.

```bash
held_keys() {
  mkdir -p "$STATE_DIR"
  rm -f "$PROBE_FILE"
  hyprctl eval "local d={} for kc=1,255 do if hl.is_key_down(kc) then d[#d+1]=kc end end local f=io.open([==[$PROBE_FILE]==],'w') if f then f:write('ok:'..table.concat(d,',')) f:close() end" \
    >/dev/null 2>&1 || true
  cat "$PROBE_FILE" 2>/dev/null || true
}
```

### 2b. Fail closed in `wait_for_key_release` (~line 63)

An unreadable probe now polls for the full `KEY_TIMEOUT` and then locks with a
*distinct* warning, rather than returning success on the first iteration.

```bash
wait_for_key_release() {
  local -r poll=0.1 attempts=$(awk -v t="$KEY_TIMEOUT" 'BEGIN { printf "%d", (t / 0.1) + 1 }')
  local raw held="" i probe_ok=0
  for ((i = 0; i < attempts; i++)); do
    raw=$(held_keys)
    if [[ $raw == ok:* ]]; then
      probe_ok=1
      held=${raw#ok:}
      [[ -n "$held" ]] || return 0
    else
      # Probe did not run. Unknown is treated as "might be held" rather than
      # "all clear" -- guessing wrong here latches a key in the focused client
      # with no way to release it.
      probe_ok=0
    fi
    sleep "$poll"
  done
  if (( probe_ok )); then
    echo "keyboard-cleaner: keys $held still held after ${KEY_TIMEOUT}s; locking anyway" >&2
  else
    echo "keyboard-cleaner: held-key probe failed; locking anyway after ${KEY_TIMEOUT}s" >&2
  fi
  return 1
}
```

Both messages carry a stable token (`still held` / `probe failed`) that the panel
matches on — see 2d.

### 2c. `keys-down` output and the `jq` dep check

`keys-down` is a documented debugging command (CONTRIBUTING's
`while :; do ./bin/keyboard-cleaner-lock keys-down; sleep 0.3; done`), so strip
the sentinel for human output and make failure visible instead of printing a
misleading empty line:

```bash
keys-down)
  raw=$(held_keys)
  if [[ $raw == ok:* ]]; then
    echo "${raw#ok:}"
  else
    echo "keyboard-cleaner: held-key probe failed" >&2
    exit 1
  fi
  ;;
```

Separately, line 38 checks only `hyprctl`, but the script uses `jq` at ~91 and
~114. Add it (`keyboard-cleaner-devices` already checks all three):

```bash
for dep in hyprctl jq; do
  command -v "$dep" >/dev/null || { echo "keyboard-cleaner: missing dependency: $dep" >&2; exit 1; }
done
```

### 2d. Surface the new warning in the panel (`Service.qml`, ~line 273)

`lockProcess.stderr` currently matches only `"still held"`, so a probe failure
would be silently swallowed. Handle both:

```qml
onStreamFinished: {
  var out = String(text)
  if (out.indexOf("still held") !== -1)
    root.lastError = "A key was still held — it may read as stuck until you press it again."
  else if (out.indexOf("probe failed") !== -1)
    root.lastError = "Could not check for held keys — if a key reads as stuck, press it again."
}
```

### 2e. Same quoting flaw in `set_enabled` (~line 77)

`set_enabled` has the identical defect as Fix 1 — `hyprctl eval "hl.device({ name
= \"$device\", … })"` breaks on a `"` in a device name. Same one-line fix, and
leaving the two inconsistent invites the bug back:

```bash
hyprctl eval "hl.device({ name = [==[$device]==], enabled = $value })" >/dev/null
```

## Explicitly out of scope

Also found in review, deliberately **not** in this branch — separate PRs:

- IPC `lock()` returning `""` instead of `"locking"` (`Service.qml:391`)
- `armedCount` counting armed rather than actually-disabled devices
  (`Service.qml:60`) — overstates in the overlay
- `cmd_unlock`'s fallback re-enabling mice and devices the user disabled on
  purpose (`keyboard-cleaner-lock:117`)
- Teardown using `presentSelection()` rather than the recorded locked set
- `LockOverlay.qml:161` hiding the TTY recovery hint whenever auto-unlock is on

## Verification

Run on the Omarchy PC. Deploy per CONTRIBUTING:

```bash
DEST=~/.config/omarchy/plugins/roymelgarv.omarchy-keyboard-cleaner
mkdir -p "$DEST" && rsync -a --delete --exclude '.git' ./ "$DEST/"
omarchy plugin validate "$DEST"     # must exit 0
omarchy-restart-shell
```

**Static:** `bash -n bin/keyboard-cleaner-lock` and
`qmllint -I "$OMARCHY_PATH/shell" *.qml`.

**Quoting fix, in isolation** — the real UI can't exercise this without a device
whose name contains an apostrophe (`presentSelection()` filters out any name not
in the live device list, so a hand-edited config won't reach the script). Test
the new argv shape directly; it must print the name intact and reach the end:

```bash
bash -c 'state=$1; shift; for d in "$@"; do echo "would enable: [$d]"; done; echo "reached end: $state"' \
  x /tmp/locked.json "bob's keyboard" 'quote"name' 'back\slash'
```

**Probe, happy path:** `./bin/keyboard-cleaner-lock keys-down` prints an empty
line with nothing held, and keycodes while you hold keys:

```bash
while :; do ./bin/keyboard-cleaner-lock keys-down; sleep 0.3; done
```

**Probe, failure path:** simulate by pointing `PROBE_FILE` somewhere unwritable
or temporarily breaking the Lua chunk (e.g. `hl.is_key_dowwn`), then confirm
`keys-down` exits non-zero with `probe failed`, and that a panel lock takes ~5s
and shows "Could not check for held keys" instead of locking instantly.

**Held-key path, real:** with the optional keybinding bound, hold `SUPER+SHIFT+K`
— the overlay must show "Release all keys" until you let go, then lock. Confirm
no key reads as stuck afterwards.

**Teardown, the main regression test.** From a second machine over SSH or a TTY,
so you aren't relying on the keyboard you just disabled:

```bash
# lock from the panel first, then:
omarchy plugin disable roymelgarv.omarchy-keyboard-cleaner
hyprctl devices -j | jq '.keyboards[] | {name, enabled}'   # all true
ls "$XDG_RUNTIME_DIR/keyboard-cleaner/"                    # locked.json gone
omarchy-shell idle status                                  # idle restored, NOT parked
```

Repeat with `omarchy plugin remove` (which moves the folder before teardown
fires — the constraint that forced the inlined script in the first place).

**Escape hatches still work:** hold-to-unlock on the overlay, auto-unlock
expiry, bar-icon click while locked, and
`bin/keyboard-cleaner-lock unlock` over SSH.

## Wrap-up

1. `git rm -r .plans` and commit, so the plan doesn't reach `development`.
2. Open a PR against `development` (not `main`), per CONTRIBUTING.
3. In the PR body, list what was actually run from the Verification section —
   the PR template asks for this, and it matters most for lock-mechanism changes.
