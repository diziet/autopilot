#!/usr/bin/env bash
# Preflight (seconds, no build, no side effects). Checks that each tool the gate needs is on PATH
# and prints its path and version, then checks that the hooks are installed. Reads the tool list
# from DEV_TOOLS, which the Makefile passes. Every failure prints the fixing command. Fails CLOSED
# (exit 1) when anything is missing. Probes never install anything.
#
# TODO: the repo pins no tool versions, so this checks presence only. Add pins to the Makefile
# and compare against them here in a reviewed change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -f "$ROOT/Makefile" ] || { echo "doctor: $ROOT is not the repo root" >&2; exit 2; }
cd "$ROOT"

DEV_TOOLS="${DEV_TOOLS:?set by the Makefile}"
failures=0

ok()   { echo "doctor: ✓ $1"; }
fail() { echo "doctor: ✗ $1" >&2; echo "         fix: $2" >&2; failures=$((failures + 1)); }

# First line of `<tool> --version`. shellcheck prints its version on the second line.
version_of() {
  case "$1" in
    shellcheck) "$1" --version 2>&1 | sed -n 2p ;;
    *) "$1" --version 2>&1 | head -n 1 ;;
  esac
}

# 1. Each tool is on PATH. DEV_TOOLS holds <command>:<brew formula> pairs.
for pair in $DEV_TOOLS; do
  cmd="${pair%%:*}"
  formula="${pair#*:}"
  if tool_path="$(command -v "$cmd")"; then
    ok "$cmd at $tool_path ($(version_of "$cmd"))"
  else
    fail "$cmd not found on PATH" "make install-dev   (or: brew install $formula)"
  fi
done

# 2. Hooks installed.
hooks_path="$(git config core.hooksPath || true)"
if [ "$hooks_path" = ".githooks" ]; then
  ok "core.hooksPath=.githooks"
else
  fail "core.hooksPath is '${hooks_path:-unset}', expected .githooks" "make hooks-install"
fi

if [ "$failures" -gt 0 ]; then
  echo "doctor: $failures problem(s); fix commands above" >&2
  exit 1
fi
echo "doctor: healthy"
