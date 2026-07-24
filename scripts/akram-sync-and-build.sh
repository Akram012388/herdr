#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

branch="$(git branch --show-current)"
if [[ "$branch" != "akram" ]]; then
  printf 'error: expected the akram integration branch, got %s\n' "$branch" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  printf 'error: working tree is not clean; commit or stash changes first\n' >&2
  exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  printf 'error: upstream remote is missing\n' >&2
  exit 1
fi

backup_ref="refs/akram-backups/pre-sync-$(date -u +%Y%m%dT%H%M%SZ)"
git update-ref "$backup_ref" HEAD
rebase_started=false
abort_failed_rebase() {
  if [[ "$rebase_started" == "true" ]] &&
    [[ -d "$repo_root/.git/rebase-merge" || -d "$repo_root/.git/rebase-apply" ]]; then
    printf 'Aborting failed rebase; source backup remains at %s\n' "$backup_ref" >&2
    git rebase --abort
  fi
}
trap abort_failed_rebase ERR

zig="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"
if [[ ! -x "$zig" ]]; then
  printf 'error: patched Zig 0.15 executable not found at %s\n' "$zig" >&2
  exit 1
fi

build_channel="${HERDR_BUILD_CHANNEL:-akram}"
build_id="${HERDR_BUILD_ID:-1}"
if [[ "$build_channel" != "akram" || -z "$build_id" || "$build_id" == *[!A-Za-z0-9-]* ]]; then
  printf 'error: downstream identity must use HERDR_BUILD_CHANNEL=akram and a non-empty HERDR_BUILD_ID\n' >&2
  exit 1
fi

printf 'Fetching official Herdr upstream...\n'
git fetch upstream --prune --tags

sync_target="${HERDR_AKRAM_SYNC_TARGET:-upstream/master}"
if ! git rev-parse --verify --quiet "${sync_target}^{commit}" >/dev/null; then
  printf 'error: sync target is not a resolvable commit: %s\n' "$sync_target" >&2
  exit 1
fi

printf 'Rebasing the Akram patch stack onto %s...\n' "$sync_target"
rebase_started=true
git rebase "$sync_target"
rebase_started=false

printf 'Validating the rebased integration branch...\n'
cargo fmt --check
# Validate as a stock build: the downstream identity is compile-time (option_env! in
# build_info.rs), and letting HERDR_BUILD_CHANNEL leak into test compilation flips
# channel-gated behavior that upstream tests assert against.
env -u HERDR_BUILD_CHANNEL -u HERDR_BUILD_ID \
  ZIG="$zig" cargo clippy --all-targets --locked -- -D warnings
# Serialize the complete suite: some configuration tests mutate process-wide environment state.
# Keep integration tests included so a broken upstream sync never produces an approved build.
# stdin comes from /dev/null: some update tests assert a noninteractive stdin, so a run from a
# real terminal must not behave differently from a scripted one.
env -u HERDR_BUILD_CHANNEL -u HERDR_BUILD_ID \
  ZIG="$zig" cargo test --locked -- --test-threads=1 </dev/null
HERDR_BUILD_CHANNEL="$build_channel" HERDR_BUILD_ID="$build_id" \
  ZIG="$zig" cargo build --release --locked

base_version="$(cargo metadata --no-deps --format-version 1 | python3 -c '
import json, sys
packages = json.load(sys.stdin)["packages"]
print(next(package["version"] for package in packages if package["name"] == "herdr"))
')"
expected_version="herdr ${base_version}-${build_channel}.${build_id}"
actual_version="$("$repo_root/target/release/herdr" --version)"
if [[ "$actual_version" != "$expected_version" ]]; then
  printf 'error: expected release identity %s, got %s\n' "$expected_version" "$actual_version" >&2
  exit 1
fi

printf '\nValidated binary:\n  %s/target/release/herdr\n' "$repo_root"
printf '  %s\n' "$actual_version"
shasum -a 256 "$repo_root/target/release/herdr"
printf 'Source backup:\n  %s\n' "$backup_ref"
printf '\nReview the rebase, then publish it with:\n  git push --force-with-lease origin akram\n'
