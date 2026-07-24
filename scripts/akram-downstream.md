# Akram downstream build

This fork keeps `master` as a clean mirror of `ogulcancelik/herdr` and carries personal additions as
a small patch stack on the `akram` branch. The pane-theme producer remains separately reviewable on
`feature/plugin-pane-theme`.

## Candidate identity

The first downstream candidate is `0.7.5-akram.1`. Its executable remains named `herdr` and reports:

```text
herdr 0.7.5-akram.1
```

The build uses Herdr's existing compile-time identity:

```text
HERDR_BUILD_CHANNEL=akram
HERDR_BUILD_ID=1
```

It adds a schema-versioned `HERDR_PLUGIN_PANE_THEME_JSON` launch-time snapshot for plugin popup
panes. Herdr resolves the palette; plugins cannot override the protected variable, and action,
event, startup, and link-handler processes explicitly remove it.

## Updating and validation

The downstream binary rejects `herdr update` and `herdr channel set` so official-channel update
paths cannot silently replace the fork.

The canonical entry point is the smart wrapper (aliased as `herdr-akram-update`):

```sh
./scripts/akram-update.sh          # full update
./scripts/akram-update.sh --check  # dry run: report only, change nothing
```

The wrapper refuses to run inside a Herdr pane (`HERDR_ENV` is set; live handoff would disconnect
the driving session), fast-paths to a status report when `akram` already contains
`upstream/master`, stamps a date-based downstream identity (`HERDR_BUILD_ID=$(date -u
+%Y%m%dT%H%M)`, so every candidate version is self-dating and traceable), delegates to
`akram-manage-install.sh update`, pushes the rebased stack with `git push --force-with-lease
origin akram` on success, and reports theme-branch drift: a `git merge-tree` test says whether
`feature/plugin-pane-theme` still rebases cleanly onto `upstream/master`. The wrapper never
rebases that branch itself; rebase it manually when the drift report warns of conflicts or when
upstream approval arrives.

The wrapper records the exact commit that passed the full suite in the state directory
(`last-validated-commit`) and only fast-paths or pushes when the current `akram` head matches it,
so a rebase whose validation failed mid-run always re-enters the full update. Validation itself
runs as a stock build (the downstream `HERDR_BUILD_CHANNEL`/`HERDR_BUILD_ID` identity is scrubbed
from clippy and the test suite, and test stdin is `/dev/null`); the identity applies only to the
release build.

`akram-manage-install.sh update` remains the manual/debugging path. It:

1. records the current source commit under `refs/akram-backups/`;
2. fetches `upstream/master` and rebases the clean `akram` patch stack;
3. runs formatting, clippy, and the complete serialized test suite;
4. builds and verifies the downstream identity;
5. copies the selected installed `herdr` binary into the managed backup directory;
6. atomically installs the candidate and live-handoffs the running server;
7. prunes old downstream backups after a successful install.

If the rebase fails, it is aborted and the source branch returns to its pre-update state. If live
handoff fails while the old server remains active, the installed binary is restored automatically.
Live handoff preserves pane processes but disconnects attached TUI clients; run `herdr` to reattach.
If the installed binary is already current but the running server is stale, `install` repairs the
server with the current binary instead of treating the operation as complete. The scripts do not
release or push anything.

Inspect or reverse the managed install explicitly:

```sh
./scripts/akram-manage-install.sh status
./scripts/akram-manage-install.sh backups
./scripts/akram-manage-install.sh rollback
./scripts/akram-manage-install.sh prune [keep]
```

By default, backups live under `${XDG_STATE_HOME:-~/.local/state}/herdr-akram`. Override exact paths
with `HERDR_AKRAM_INSTALL_PATH`, `HERDR_AKRAM_CANDIDATE_BIN`, or
`HERDR_AKRAM_STATE_DIR`. Live-server handoff is attempted only when the managed install path resolves
to the `herdr` currently selected on `PATH`; an overridden test or alternate install path cannot
handoff an unrelated running session.

Backups do not grow without bound: every successful install prunes to the newest
`HERDR_AKRAM_KEEP_BACKUPS` (default 5) downstream binaries and `refs/akram-backups/` source refs.
Official (non `-akram.`) baseline backups and the active rollback target are never pruned, so the
path back to stock Herdr always survives.

The wrapper stamps `HERDR_BUILD_ID` from the UTC sync time, so no manual increment is needed; two
syncs on the same upstream base still produce distinguishable versions. Publication and the
eventual upstream contribution remain separate, explicitly approved operations.
