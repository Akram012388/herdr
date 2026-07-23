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

zig="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"
if [[ ! -x "$zig" ]]; then
  printf 'error: patched Zig 0.15 executable not found at %s\n' "$zig" >&2
  exit 1
fi

printf 'Fetching official Herdr upstream...\n'
git fetch upstream --prune --tags

printf 'Rebasing the Akram patch stack onto upstream/master...\n'
git rebase upstream/master

printf 'Validating the rebased integration branch...\n'
cargo fmt --check
ZIG="$zig" cargo clippy --all-targets --locked -- -D warnings
# Serialize the complete suite: some configuration tests mutate process-wide environment state.
# Keep integration tests included so a broken upstream sync never produces an approved build.
ZIG="$zig" cargo test --locked -- --test-threads=1
ZIG="$zig" cargo build --release --locked

printf '\nValidated binary:\n  %s/target/release/herdr\n' "$repo_root"
shasum -a 256 "$repo_root/target/release/herdr"
printf '\nReview the rebase, then publish it with:\n  git push --force-with-lease origin akram\n'
