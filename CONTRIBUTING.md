# Contributing

## Branch flow

```
main            <- released, tagged versions only
  development   <- integration branch, target your PR here
    fix/...     <- bug fixes
    feat/...    <- new functionality
    chore/...   <- docs, refactors, tooling, no behavior change
```

Open pull requests against `development`, not `main`. `main` only moves
forward via a PR from `development` when a release is cut, and is
branch-protected — direct pushes are rejected for everyone, maintainer
included.

Name your branch by what it does: `fix/short-description`,
`feat/short-description`, `chore/short-description`.

## Before opening a PR

There's no CI yet, so these are manual:

```bash
omarchy plugin validate <plugin-dir>
qmllint -I "$OMARCHY_PATH/shell" *.qml
```

Both should exit clean. See the README's **Local development** section for
how to deploy your working copy into a live Omarchy shell and exercise it —
this plugin has no standalone runner, so testing means running it for real
inside Quickshell/Hyprland.

At minimum, before submitting: lock and unlock through the panel, confirm the
overlay appears, and check `journalctl --user` for anything new.

## Scope

Changes that touch the lock mechanism (device disable/enable, held-key
handling, idle parking) get more scrutiny than everything else — a bug here
means someone's keyboard doesn't come back. Explain what you tested and how,
not just what changed.
