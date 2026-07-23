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

Update, validate, back up the installed binary, and switch the running server from the checkout:

```sh
cd ~/Learning/Projects/herdr-codeakram/herdr
./scripts/akram-manage-install.sh update
```

The update command:

1. records the current source commit under `refs/akram-backups/`;
2. fetches `upstream/master` and rebases the clean `akram` patch stack;
3. runs formatting, clippy, and the complete serialized test suite;
4. builds and verifies the downstream identity;
5. copies the selected installed `herdr` binary into the managed backup directory;
6. atomically installs the candidate and live-handoffs the running server.

If the rebase fails, it is aborted and the source branch returns to its pre-update state. If live
handoff fails while the old server remains active, the installed binary is restored automatically.
Live handoff preserves pane processes but disconnects attached TUI clients; run `herdr` to reattach.
The scripts do not release or push anything.

Inspect or reverse the managed install explicitly:

```sh
./scripts/akram-manage-install.sh status
./scripts/akram-manage-install.sh backups
./scripts/akram-manage-install.sh rollback
```

By default, backups live under `${XDG_STATE_HOME:-~/.local/state}/herdr-akram`. Override exact paths
with `HERDR_AKRAM_INSTALL_PATH`, `HERDR_AKRAM_CANDIDATE_BIN`, or
`HERDR_AKRAM_STATE_DIR`. Live-server handoff is attempted only when the managed install path resolves
to the `herdr` currently selected on `PATH`; an overridden test or alternate install path cannot
handoff an unrelated running session.

Increment `HERDR_BUILD_ID` for a later downstream candidate. Publication and the eventual upstream
contribution remain separate, explicitly approved operations.
