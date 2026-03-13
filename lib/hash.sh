#!/usr/bin/env bash
# Portable MD5 hashing utilities.
# Resolves the correct md5 command across macOS (md5) and Linux (md5sum),
# including fallback to absolute paths for minimal-PATH environments (launchd).

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_HASH_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_HASH_LOADED=1

# Resolve the md5 command to use. Echoes the command/path on success.
# Tries PATH lookup first, then absolute paths for minimal-PATH environments.
_resolve_md5_cmd() {
  if command -v md5 >/dev/null 2>&1; then
    echo "md5"
  elif [[ -x /sbin/md5 ]]; then
    echo "/sbin/md5"
  elif command -v md5sum >/dev/null 2>&1; then
    echo "md5sum"
  elif [[ -x /usr/bin/md5sum ]]; then
    echo "/usr/bin/md5sum"
  else
    return 1
  fi
}

# Compute an MD5 hash of stdin content. Always outputs a bare hex digest.
_compute_hash() {
  local cmd
  cmd="$(_resolve_md5_cmd)" || {
    echo "_compute_hash: neither md5 nor md5sum found" >&2
    return 1
  }

  case "$cmd" in
    *md5sum) "$cmd" | cut -d' ' -f1 ;;
    *)       "$cmd" -q ;;
  esac
}
