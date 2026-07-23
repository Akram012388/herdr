#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
candidate_bin="${HERDR_AKRAM_CANDIDATE_BIN:-$repo_root/target/release/herdr}"
state_dir="${HERDR_AKRAM_STATE_DIR:-${XDG_STATE_HOME:-${HOME:?}/.local/state}/herdr-akram}"
backup_dir="$state_dir/backups"
latest_backup_file="$state_dir/latest-backup"

usage() {
  cat <<'EOF'
usage: ./scripts/akram-manage-install.sh <command>

commands:
  status              show installed, candidate, server, and backup state
  install             back up the selected Herdr binary and switch to the candidate
  rollback [backup]   restore the latest backup, or the specified backup
  update              sync/rebase/build, then install the validated candidate
  backups             list managed binary backups

environment:
  HERDR_AKRAM_INSTALL_PATH   installed binary to manage (default: selected herdr on PATH)
  HERDR_AKRAM_CANDIDATE_BIN candidate binary (default: target/release/herdr)
  HERDR_AKRAM_STATE_DIR     backup state directory
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

json_field() {
  local field="$1"
  python3 -c '
import json
import sys

value = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    value = value.get(part) if isinstance(value, dict) else None
    if value is None:
        break
if isinstance(value, bool):
    print("true" if value else "false")
elif value is not None:
    print(value)
' "$field"
}

resolve_install_path() {
  local selected
  if [[ -n "${HERDR_AKRAM_INSTALL_PATH:-}" ]]; then
    selected="$HERDR_AKRAM_INSTALL_PATH"
  else
    selected="$(command -v herdr || true)"
  fi
  [[ -n "$selected" ]] || fail "herdr is not on PATH; set HERDR_AKRAM_INSTALL_PATH"
  [[ "$selected" == /* ]] || fail "install path must be absolute: $selected"
  printf '%s\n' "$selected"
}

client_json() {
  local binary="$1"
  "$binary" status client --json
}

server_json() {
  local binary="$1"
  "$binary" status server --json
}

binary_version() {
  client_json "$1" | json_field version
}

binary_protocol() {
  client_json "$1" | json_field protocol
}

binary_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

canonical_path() {
  python3 -c '
import os
import sys

print(os.path.realpath(sys.argv[1]))
' "$1"
}

manages_selected_install() {
  local install_path="$1"
  local selected
  selected="$(command -v herdr || true)"
  [[ -n "$selected" ]] || return 1
  [[ "$(canonical_path "$install_path")" == "$(canonical_path "$selected")" ]]
}

validate_binary() {
  local binary="$1"
  [[ -f "$binary" && -x "$binary" ]] || fail "binary is not an executable file: $binary"
  local version protocol
  version="$(binary_version "$binary")"
  protocol="$(binary_protocol "$binary")"
  [[ -n "$version" && -n "$protocol" ]] ||
    fail "could not read Herdr identity from $binary"
}

validate_candidate() {
  validate_binary "$candidate_bin"
  local version
  version="$(binary_version "$candidate_bin")"
  [[ "$version" == *-akram.* ]] ||
    fail "candidate is not an Akram downstream build: $version"
}

atomic_replace() {
  local source="$1"
  local target="$2"
  local target_dir temp_path
  target_dir="$(dirname "$target")"
  [[ -d "$target_dir" && -w "$target_dir" ]] ||
    fail "install directory is not writable: $target_dir"
  temp_path="$(mktemp "$target_dir/.herdr-akram.XXXXXX")"
  trap 'rm -f "$temp_path"' RETURN
  cp -p "$source" "$temp_path"
  chmod 755 "$temp_path"
  validate_binary "$temp_path"
  mv -f "$temp_path" "$target"
  trap - RETURN
}

create_backup() {
  local install_path="$1"
  local update_latest="${2:-true}"
  local timestamp version protocol sha backup_path metadata_path
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  version="$(binary_version "$install_path")"
  protocol="$(binary_protocol "$install_path")"
  sha="$(binary_sha256 "$install_path")"
  mkdir -p "$backup_dir"
  backup_path="$backup_dir/herdr-${timestamp}-${version}"
  if [[ -e "$backup_path" ]]; then
    backup_path="$backup_dir/herdr-${timestamp}-${version}-$$"
  fi
  cp -p "$install_path" "$backup_path"
  chmod 755 "$backup_path"
  metadata_path="${backup_path}.meta"
  {
    printf 'created_utc=%s\n' "$timestamp"
    printf 'install_path=%s\n' "$install_path"
    printf 'version=%s\n' "$version"
    printf 'protocol=%s\n' "$protocol"
    printf 'sha256=%s\n' "$sha"
  } >"$metadata_path"
  if [[ "$update_latest" == "true" ]]; then
    mkdir -p "$state_dir"
    printf '%s\n' "$backup_path" >"$latest_backup_file"
  fi
  printf '%s\n' "$backup_path"
}

wait_for_server_identity() {
  local binary="$1"
  local expected_version="$2"
  local expected_protocol="$3"
  local remaining=50 status version protocol running
  while ((remaining > 0)); do
    status="$(server_json "$binary" 2>/dev/null || true)"
    running="$(printf '%s' "$status" | json_field running)"
    version="$(printf '%s' "$status" | json_field version)"
    protocol="$(printf '%s' "$status" | json_field protocol)"
    if [[ "$running" == "true" && "$version" == "$expected_version" &&
      "$protocol" == "$expected_protocol" ]]; then
      return 0
    fi
    sleep 0.2
    remaining=$((remaining - 1))
  done
  return 1
}

handoff_to() {
  local control_binary="$1"
  local import_binary="$2"
  local expected_version="$3"
  local expected_protocol="$4"
  "$control_binary" server live-handoff \
    --import-exe "$import_binary" \
    --expected-protocol "$expected_protocol" \
    --expected-version "$expected_version"
  wait_for_server_identity "$control_binary" "$expected_version" "$expected_protocol"
}

print_status() {
  local install_path installed_json candidate_json status_json latest
  install_path="$(resolve_install_path)"
  validate_binary "$install_path"
  installed_json="$(client_json "$install_path")"

  printf 'install:   %s (%s, protocol %s)\n' \
    "$install_path" \
    "$(printf '%s' "$installed_json" | json_field version)" \
    "$(printf '%s' "$installed_json" | json_field protocol)"

  if [[ -x "$candidate_bin" ]]; then
    candidate_json="$(client_json "$candidate_bin")"
    printf 'candidate: %s (%s, protocol %s)\n' \
      "$candidate_bin" \
      "$(printf '%s' "$candidate_json" | json_field version)" \
      "$(printf '%s' "$candidate_json" | json_field protocol)"
  else
    printf 'candidate: missing (%s)\n' "$candidate_bin"
  fi

  if manages_selected_install "$install_path"; then
    status_json="$(server_json "$install_path" 2>/dev/null || true)"
    if [[ "$(printf '%s' "$status_json" | json_field running)" == "true" ]]; then
      printf 'server:    running %s (protocol %s, handoff %s)\n' \
        "$(printf '%s' "$status_json" | json_field version)" \
        "$(printf '%s' "$status_json" | json_field protocol)" \
        "$(printf '%s' "$status_json" | json_field capabilities.live_handoff)"
    else
      printf 'server:    stopped\n'
    fi
  else
    printf 'server:    not managed (install path is not the selected herdr on PATH)\n'
  fi

  latest="$(cat "$latest_backup_file" 2>/dev/null || true)"
  if [[ -n "$latest" && -x "$latest" ]]; then
    printf 'rollback:  %s (%s, protocol %s)\n' \
      "$latest" "$(binary_version "$latest")" "$(binary_protocol "$latest")"
  else
    printf 'rollback:  none\n'
  fi
}

install_candidate() {
  local install_path status_json server_running handoff_supported
  local installed_sha candidate_sha backup_path candidate_version candidate_protocol
  local old_version old_protocol
  install_path="$(resolve_install_path)"
  validate_binary "$install_path"
  validate_candidate

  installed_sha="$(binary_sha256 "$install_path")"
  candidate_sha="$(binary_sha256 "$candidate_bin")"
  if [[ "$installed_sha" == "$candidate_sha" ]]; then
    printf 'already installed: %s\n' "$(binary_version "$candidate_bin")"
    print_status
    return
  fi

  server_running=false
  handoff_supported=false
  old_version=""
  old_protocol=""
  if manages_selected_install "$install_path"; then
    status_json="$(server_json "$install_path" 2>/dev/null || true)"
    server_running="$(printf '%s' "$status_json" | json_field running)"
    handoff_supported="$(printf '%s' "$status_json" | json_field capabilities.live_handoff)"
    old_version="$(printf '%s' "$status_json" | json_field version)"
    old_protocol="$(printf '%s' "$status_json" | json_field protocol)"
  fi
  if [[ "$server_running" == "true" && "$handoff_supported" != "true" ]]; then
    fail "the running server cannot live-handoff; installation was not changed"
  fi

  backup_path="$(create_backup "$install_path")"
  candidate_version="$(binary_version "$candidate_bin")"
  candidate_protocol="$(binary_protocol "$candidate_bin")"
  printf 'backup: %s\n' "$backup_path"
  atomic_replace "$candidate_bin" "$install_path"
  printf 'installed: %s\n' "$candidate_version"

  if [[ "$server_running" == "true" ]]; then
    printf 'handing off live panes from %s/protocol %s...\n' "$old_version" "$old_protocol"
    if ! handoff_to "$install_path" "$install_path" "$candidate_version" "$candidate_protocol"; then
      status_json="$(server_json "$install_path" 2>/dev/null || true)"
      if [[ "$(printf '%s' "$status_json" | json_field version)" == "$old_version" &&
        "$(printf '%s' "$status_json" | json_field protocol)" == "$old_protocol" ]]; then
        atomic_replace "$backup_path" "$install_path"
        fail "live handoff failed; restored the installed binary from backup"
      fi
      fail "live handoff could not be verified; installed binary left at $candidate_version and backup kept at $backup_path"
    fi
    printf 'live handoff disconnects attached TUI clients; reconnect with: herdr\n'
  fi

  print_status
}

rollback_install() {
  local requested="${1:-}"
  local install_path backup_path current_backup
  local status_json server_running handoff_supported old_version old_protocol
  local backup_version backup_protocol
  install_path="$(resolve_install_path)"
  validate_binary "$install_path"
  if [[ -n "$requested" ]]; then
    backup_path="$requested"
  else
    backup_path="$(cat "$latest_backup_file" 2>/dev/null || true)"
  fi
  [[ -n "$backup_path" ]] || fail "no managed backup is available"
  [[ "$backup_path" == /* ]] || fail "backup path must be absolute: $backup_path"
  validate_binary "$backup_path"
  [[ "$backup_path" == "$backup_dir/"* ]] ||
    fail "refusing unmanaged rollback source: $backup_path"

  if [[ "$(binary_sha256 "$install_path")" == "$(binary_sha256 "$backup_path")" ]]; then
    printf 'already restored: %s\n' "$(binary_version "$backup_path")"
    return
  fi

  server_running=false
  handoff_supported=false
  old_version=""
  old_protocol=""
  if manages_selected_install "$install_path"; then
    status_json="$(server_json "$install_path" 2>/dev/null || true)"
    server_running="$(printf '%s' "$status_json" | json_field running)"
    handoff_supported="$(printf '%s' "$status_json" | json_field capabilities.live_handoff)"
    old_version="$(printf '%s' "$status_json" | json_field version)"
    old_protocol="$(printf '%s' "$status_json" | json_field protocol)"
  fi
  if [[ "$server_running" == "true" && "$handoff_supported" != "true" ]]; then
    fail "the running server cannot live-handoff; rollback was not started"
  fi

  current_backup="$(create_backup "$install_path" false)"
  backup_version="$(binary_version "$backup_path")"
  backup_protocol="$(binary_protocol "$backup_path")"
  atomic_replace "$backup_path" "$install_path"
  printf 'restored binary: %s\n' "$backup_version"

  if [[ "$server_running" == "true" ]]; then
    printf 'handing off live panes from %s/protocol %s...\n' "$old_version" "$old_protocol"
    if ! handoff_to "$install_path" "$install_path" "$backup_version" "$backup_protocol"; then
      status_json="$(server_json "$install_path" 2>/dev/null || true)"
      if [[ "$(printf '%s' "$status_json" | json_field version)" == "$old_version" &&
        "$(printf '%s' "$status_json" | json_field protocol)" == "$old_protocol" ]]; then
        atomic_replace "$current_backup" "$install_path"
        fail "rollback handoff failed; restored the previously installed binary"
      fi
      fail "rollback handoff could not be verified; recovery binary kept at $current_backup"
    fi
    printf 'live handoff disconnects attached TUI clients; reconnect with: herdr\n'
  fi

  printf '%s\n' "$current_backup" >"$latest_backup_file"
  print_status
}

list_backups() {
  if [[ ! -d "$backup_dir" ]]; then
    printf 'no managed backups\n'
    return
  fi
  local found=false path
  while IFS= read -r path; do
    found=true
    printf '%s  %s  protocol %s\n' \
      "$(binary_version "$path")" "$path" "$(binary_protocol "$path")"
  done < <(find "$backup_dir" -maxdepth 1 -type f ! -name '*.meta' -perm -u+x | sort -r)
  [[ "$found" == "true" ]] || printf 'no managed backups\n'
}

command="${1:-}"
case "$command" in
status)
  [[ $# -eq 1 ]] || {
    usage
    exit 2
  }
  print_status
  ;;
install)
  [[ $# -eq 1 ]] || {
    usage
    exit 2
  }
  install_candidate
  ;;
rollback)
  [[ $# -le 2 ]] || {
    usage
    exit 2
  }
  rollback_install "${2:-}"
  ;;
update)
  [[ $# -eq 1 ]] || {
    usage
    exit 2
  }
  "$repo_root/scripts/akram-sync-and-build.sh"
  install_candidate
  ;;
backups)
  [[ $# -eq 1 ]] || {
    usage
    exit 2
  }
  list_backups
  ;;
*)
  usage
  exit 2
  ;;
esac
