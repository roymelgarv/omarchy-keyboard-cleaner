---
name: Bug report
about: Something isn't working as expected
title: ""
labels: bug
---

## What happened

<!-- What did you do, what did you expect, what happened instead? -->

## Environment

- Omarchy version / commit:
- Hyprland version: `hyprctl version`
- Number of monitors:
- Output of `omarchy plugin list --json | jq '.[] | select(.id | test("keyboard-cleaner"))'`:

## If the keyboard was left disabled

This matters most for anything touching lock/unlock, since it can leave a
keyboard unusable. Please include:

- `omarchy-shell keyboard-cleaner status` output at the time
- Relevant lines from `journalctl --user -b 0`
- Whether `omarchy-restart-hyprctl` or a TTY got you unstuck
