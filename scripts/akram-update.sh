#!/usr/bin/env bash
set -euo pipefail

# Smart downstream update entry point (aliased as herdr-akram-update).
# Wraps akram-manage-install.sh update with the habits a routine update needs:
# a date-based build identity, an up-to-date fast path, pushing the rebased
# stack, and a theme-branch drift signal. It never touches upstream remotes
# beyond fetching, and never rebases feature/plugin-pane-theme itself.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manage="$repo_root/scripts/akram-manage-install.sh"
theme_branch="feature/plugin-pane-theme"

usage() {
  cat <<'EOF'
usage: ./scripts/akram-update.sh [--check]

Sync the akram patch stack onto upstream/master, validate, build, install,
live-handoff the running server, push the rebased stack to origin, and report
theme-branch drift.

  --check   report what an update would do (upstream delta, origin sync,
            theme drift, install state) without building, installing,
            pushing, or pruning
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

check_only=false
case "${1:-}" in
"") ;;
--check)
  check_only=true
  ;;
-h | --help)
  usage
  exit 0
  ;;
*)
  usage
  exit 2
  ;;
esac

# Live handoff disconnects attached TUI clients; running this from inside a
# Herdr pane would cut off the very session driving the update.
[[ -z "${HERDR_ENV:-}" ]] ||
  fail "refusing to run inside a Herdr pane; live handoff would disconnect this session. Run from a plain terminal."

cd "$repo_root"

branch="$(git branch --show-current)"
[[ "$branch" == "akram" ]] || fail "expected the akram integration branch, got ${branch:-detached HEAD}"
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean; commit or stash changes first"
git remote get-url upstream >/dev/null 2>&1 || fail "upstream remote is missing"
git remote get-url origin >/dev/null 2>&1 || fail "origin remote is missing"

printf 'Fetching upstream and origin...\n'
git fetch upstream --prune --tags
git fetch origin --prune

theme_drift_report() {
  if ! git show-ref --verify --quiet "refs/heads/$theme_branch"; then
    printf 'theme branch: %s not found locally\n' "$theme_branch"
    return
  fi
  local behind rc=0
  behind="$(git rev-list --count "$theme_branch..upstream/master")"
  if ((behind == 0)); then
    printf 'theme branch: current with upstream/master\n'
    return
  fi
  git merge-tree --write-tree upstream/master "$theme_branch" >/dev/null 2>&1 || rc=$?
  case "$rc" in
  0)
    printf 'theme branch: %s commits behind upstream/master; rebases cleanly, safe to leave parked\n' "$behind"
    ;;
  1)
    printf 'WARNING: theme branch is %s commits behind upstream/master and would CONFLICT on rebase.\n' "$behind"
    printf '         Rebase %s manually soon, while the upstream context is fresh.\n' "$theme_branch"
    ;;
  *)
    printf 'theme branch: %s commits behind upstream/master (merge test unavailable, exit %s)\n' "$behind" "$rc"
    ;;
  esac
}

push_stack() {
  if [[ "$(git rev-parse akram)" == "$(git rev-parse origin/akram 2>/dev/null || echo missing)" ]]; then
    printf 'origin/akram: already in sync\n'
    return
  fi
  if [[ "$check_only" == "true" ]]; then
    printf 'origin/akram: behind local akram; a real run would push --force-with-lease\n'
    return
  fi
  printf 'Publishing the rebased stack to origin/akram...\n'
  git push --force-with-lease origin akram
}

if git merge-base --is-ancestor upstream/master akram; then
  printf 'akram already contains upstream/master; no sync needed.\n'
  push_stack
  theme_drift_report
  "$manage" status
  exit 0
fi

behind_upstream="$(git rev-list --count akram..upstream/master)"
printf 'upstream/master has %s new commits.\n' "$behind_upstream"

if [[ "$check_only" == "true" ]]; then
  printf 'check mode: a real run would rebase, run the full serialized suite, build,\n'
  printf 'install with live handoff, push origin/akram, and prune old backups.\n'
  push_stack
  theme_drift_report
  "$manage" status
  exit 0
fi

build_id="$(date -u +%Y%m%dT%H%M)"
printf 'Downstream identity for this sync: -akram.%s\n' "$build_id"
printf 'Note: the full serialized test suite runs next; expect a long wait.\n'
printf 'Note: live handoff will disconnect attached Herdr TUI clients (panes survive).\n'

HERDR_BUILD_CHANNEL=akram HERDR_BUILD_ID="$build_id" "$manage" update

push_stack
theme_drift_report
