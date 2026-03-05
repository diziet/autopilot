#!/usr/bin/env bash
# Check required dependencies for Autopilot installation.
# Delegates to lib/preflight.sh for the canonical dependency list and hints.
# Adds verbose version output for interactive use via `make check-deps`.

set -euo pipefail

# Use bash builtins only (no dirname) so restricted PATH in tests works.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

# Source preflight for _PREFLIGHT_DEPS, _get_install_hint, _check_command.
# shellcheck source=lib/preflight.sh
source "${LIB_DIR}/preflight.sh"

# Get a version string for a dependency (best-effort).
_get_version() {
  local cmd="$1"
  case "$cmd" in
    git)     git --version 2>&1 | head -1 ;;
    jq)      jq --version 2>&1 ;;
    gh)      gh --version 2>&1 | head -1 ;;
    claude)  echo "(found on PATH)" ;;
    timeout) echo "(found on PATH)" ;;
    *)       echo "(found on PATH)" ;;
  esac
}

# Pad a command name to a fixed width for aligned output.
_pad_name() {
  printf "%-8s" "$1"
}

echo "Checking dependencies..."

missing=0
claude_cmd="${AUTOPILOT_CLAUDE_CMD:-claude}"

# Check the configured Claude command.
if _check_command "$claude_cmd"; then
  echo "  ✓ $(_pad_name "$claude_cmd")$(_get_version "$claude_cmd")"
else
  echo "  ✗ $(_pad_name "$claude_cmd")MISSING — $(_get_install_hint "claude")"
  missing=1
fi

# Check standard deps from preflight.
for dep in $_PREFLIGHT_DEPS; do
  if _check_command "$dep"; then
    echo "  ✓ $(_pad_name "$dep")$(_get_version "$dep")"
  else
    echo "  ✗ $(_pad_name "$dep")MISSING — $(_get_install_hint "$dep")"
    # Extra macOS guidance for timeout.
    if [[ "$dep" == "timeout" ]]; then
      echo "    macOS does not include GNU timeout by default."
      echo "    Install via: brew install coreutils"
      echo "    Homebrew adds 'timeout' to /opt/homebrew/bin (Apple Silicon)"
      echo "    or /usr/local/bin (Intel). Ensure this is in your PATH."
    fi
    missing=1
  fi
done

echo ""

if [[ "$missing" -gt 0 ]]; then
  echo "ERROR: Missing required dependencies. Install them and re-run."
  exit 1
fi

echo "All dependencies found."
