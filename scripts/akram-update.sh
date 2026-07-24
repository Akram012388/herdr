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
state_dir="${HERDR_AKRAM_STATE_DIR:-${XDG_STATE_HOME:-${HOME:?}/.local/state}/herdr-akram}"
marker_file="$state_dir/last-validated-commit"

usage() {
  cat <<'EOF'
usage: ./scripts/akram-update.sh [--check | --release]

Sync the akram patch stack onto upstream, validate, build, install,
live-handoff the running server, push the rebased stack to origin, and report
release state and theme-branch drift.

  (no flag)   sync onto the upstream/master tip
  --release   sync onto the newest upstream release tag instead of the master
              tip: the release-cadence default
  --check     report what an update would do (upstream delta, release state,
              origin sync, theme drift, install state) without building,
              installing, pushing, or pruning
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# -le 1 ]] || {
  usage
  exit 2
}

check_only=false
release_mode=false
case "${1:-}" in
"") ;;
--check)
  check_only=true
  ;;
--release)
  release_mode=true
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

latest_tag="$(git tag --list --sort=-v:refname | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"

# The downstream binary rejects the official update checker, so this is the only place a new
# upstream release announces itself.
release_report() {
  if [[ -z "$latest_tag" ]]; then
    printf 'releases: no upstream release tags found\n'
    return
  fi
  local installed
  installed="$(herdr --version 2>/dev/null | awk '{print $2}' || true)"
  if git merge-base --is-ancestor "$latest_tag" akram; then
    printf 'releases: latest upstream release %s is already in the akram stack (installed: %s)\n' \
      "$latest_tag" "${installed:-unknown}"
  else
    printf 'releases: NEW upstream release %s is not in the akram stack (installed: %s); run --release to sync to it\n' \
      "$latest_tag" "${installed:-unknown}"
  fi
}

target_ref="upstream/master"
if [[ "$release_mode" == "true" ]]; then
  [[ -n "$latest_tag" ]] || fail "no upstream release tags found; cannot sync in release mode"
  target_ref="$latest_tag"
fi

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

# The fast path requires both no new target commits AND a validation marker for the exact
# current head: a rebase whose validation failed mid-run must re-enter the full update, never
# get skipped or pushed as if it had been approved.
head_commit="$(git rev-parse akram)"
validated_commit="$(cat "$marker_file" 2>/dev/null || true)"

if git merge-base --is-ancestor "$target_ref" akram; then
  if [[ "$validated_commit" == "$head_commit" ]]; then
    printf 'akram already contains %s and this commit passed validation; nothing to sync.\n' "$target_ref"
    push_stack
    release_report
    theme_drift_report
    "$manage" status
    exit 0
  fi
  if [[ "$release_mode" == "true" && "$check_only" != "true" ]]; then
    # Rebasing onto an already-contained tag would rewind the base and replay upstream commits
    # as our own; the stack is past this release, so master mode is the only forward validator.
    fail "akram already contains release $target_ref but this commit has not passed validation; run herdr-akram-update (master mode) to validate and install"
  fi
  printf 'akram already contains %s, but this commit has not passed validation; running the full update.\n' "$target_ref"
else
  behind_target="$(git rev-list --count "akram..$target_ref")"
  printf '%s has %s new commits for the stack.\n' "$target_ref" "$behind_target"
fi

if [[ "$check_only" == "true" ]]; then
  printf 'check mode: a real run would rebase onto %s, run the full serialized suite, build,\n' "$target_ref"
  printf 'install with live handoff, push origin/akram, and prune old backups.\n'
  push_stack
  release_report
  theme_drift_report
  "$manage" status
  exit 0
fi

build_id="$(date -u +%Y%m%dT%H%M)"
printf 'Downstream identity for this sync: -akram.%s\n' "$build_id"
printf 'Note: the full serialized test suite runs next; expect a long wait.\n'
printf 'Note: live handoff will disconnect attached Herdr TUI clients (panes survive).\n'

HERDR_BUILD_CHANNEL=akram HERDR_BUILD_ID="$build_id" \
  HERDR_AKRAM_SYNC_TARGET="$target_ref" "$manage" update

mkdir -p "$state_dir"
git rev-parse akram >"$marker_file"
push_stack
release_report
theme_drift_report
