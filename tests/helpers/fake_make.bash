# Fake `make` for tests of the `make merge` path.
# _install_fake_make writes a `make` script first on PATH. The script appends
# its working directory, arguments and TMPDIR to FAKE_MAKE_LOG, prints
# FAKE_MAKE_OUTPUT, and exits FAKE_MAKE_EXIT (default 0). With
# FAKE_MAKE_REMOVE_TREE=1 and exit 0 it removes its working directory, as a
# successful `make merge` removes the worktree it runs in.
# Usage: load helpers/fake_make; _install_fake_make

# Write the fake make script and put its directory first on PATH.
_install_fake_make() {
  local bin_dir="${BATS_TEST_TMPDIR}/fake-make-bin"
  mkdir -p "$bin_dir"
  export FAKE_MAKE_LOG="${BATS_TEST_TMPDIR}/fake-make.log"
  export FAKE_MAKE_OUTPUT="${FAKE_MAKE_OUTPUT:-}"
  export FAKE_MAKE_EXIT="${FAKE_MAKE_EXIT:-0}"
  export FAKE_MAKE_REMOVE_TREE="${FAKE_MAKE_REMOVE_TREE:-0}"
  cat > "${bin_dir}/make" <<'SCRIPT'
#!/bin/bash
{
  echo "cwd=${PWD}"
  echo "args=$*"
  echo "tmpdir=${TMPDIR:-<unset>}"
} >> "$FAKE_MAKE_LOG"
if [ -n "$FAKE_MAKE_OUTPUT" ]; then
  printf '%s\n' "$FAKE_MAKE_OUTPUT"
fi
if [ "$FAKE_MAKE_REMOVE_TREE" = "1" ] && [ "$FAKE_MAKE_EXIT" = "0" ]; then
  rm -rf "$PWD"
fi
exit "$FAKE_MAKE_EXIT"
SCRIPT
  chmod +x "${bin_dir}/make"
  export PATH="${bin_dir}:${PATH}"
}

# Write a Makefile into dir whose merge rule runs scripts/merge.py.
_write_make_merge_makefile() {
  local dir="$1"
  mkdir -p "$dir"
  # shellcheck disable=SC2016  # $(PY) and $(pr) are make variables.
  printf '.PHONY: merge\nmerge: ## Sanctioned path: make merge pr=N\n\t$(PY) scripts/merge.py --pr "$(pr)"\n' \
    > "${dir}/Makefile"
}
