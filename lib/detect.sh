#!/usr/bin/env bash
# Framework detection for test and lint commands.
# Shared by testgate.sh and hooks.sh. Each _has_* function checks for
# marker files indicating a particular language or tool.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_DETECT_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_DETECT_LOADED=1

# Allowlisted test commands for auto-detection security.
readonly _TESTGATE_ALLOWLIST="pytest npm bats make cargo go bundle ./gradlew mvn"

# Allowlisted lint commands for auto-detection security.
readonly _LINT_ALLOWLIST="ruff flake8 npx cargo golangci-lint bundle make"

# --- Test Framework Detection ---

# Detect the test command for a project. Uses AUTOPILOT_TEST_CMD if set.
detect_test_cmd() {
  local project_dir="${1:-.}"
  local custom_cmd="${AUTOPILOT_TEST_CMD:-}"
  if [[ -n "$custom_cmd" ]]; then
    echo "$custom_cmd"
    return 0
  fi
  _auto_detect_test_cmd "$project_dir"
}

# Auto-detect test framework in priority order.
# Disables coverage plugin for auto-detected pytest (adds overhead in pipeline).
_auto_detect_test_cmd() {
  local project_dir="${1:-.}"
  if _has_pytest "$project_dir"; then echo "pytest -p no:cov"; return 0; fi
  if _has_npm_test "$project_dir"; then echo "npm test"; return 0; fi
  if _has_bats "$project_dir"; then echo "bats tests/"; return 0; fi
  if _has_cargo "$project_dir"; then echo "cargo test"; return 0; fi
  if _has_go_mod "$project_dir"; then echo "go test ./..."; return 0; fi
  if _has_rspec "$project_dir"; then echo "bundle exec rspec"; return 0; fi
  if _has_rake_test "$project_dir"; then echo "bundle exec rake test"; return 0; fi
  if _has_gradlew "$project_dir"; then echo "./gradlew test"; return 0; fi
  if _has_maven "$project_dir"; then echo "mvn test"; return 0; fi
  if _has_make_test "$project_dir"; then echo "make test"; return 0; fi
  return 1
}

# --- Allowlist Validation ---

# Validate that a test command's first word is on the allowlist.
_is_allowed_cmd() {
  local first_word="${1%% *}"
  local allowed
  for allowed in $_TESTGATE_ALLOWLIST; do
    [[ "$first_word" = "$allowed" ]] && return 0
  done
  return 1
}

# --- Project Type Detectors ---

# Check if project uses pytest.
_has_pytest() {
  local d="$1"
  if [[ -f "${d}/conftest.py" ]] || [[ -f "${d}/tests/conftest.py" ]]; then return 0; fi
  if [[ -f "${d}/pyproject.toml" ]] && grep -q 'pytest' "${d}/pyproject.toml" 2>/dev/null; then return 0; fi
  local f; for f in "${d}"/requirements*.txt; do
    [[ -f "$f" ]] && grep -qi 'pytest' "$f" 2>/dev/null && return 0
  done
  return 1
}

# Check if project has npm test script.
_has_npm_test() {
  local d="$1"
  [[ -f "${d}/package.json" ]] || return 1
  local script
  script="$(jq -r '.scripts.test // empty' "${d}/package.json" 2>/dev/null)"
  [[ -n "$script" ]]
}

# Check if project has bats test files.
_has_bats() {
  local d="$1"
  local found
  found="$(find "${d}/tests" -maxdepth 1 -name '*.bats' 2>/dev/null | head -1)"
  [[ -n "$found" ]]
}

# Check if project uses Cargo (Rust).
_has_cargo() {
  local d="$1"
  [[ -f "${d}/Cargo.toml" ]]
}

# Check if project uses Go modules.
_has_go_mod() {
  local d="$1"
  [[ -f "${d}/go.mod" ]]
}

# Check if project uses RSpec (Ruby).
_has_rspec() {
  local d="$1"
  [[ -f "${d}/Gemfile" ]] && [[ -d "${d}/spec" ]]
}

# Check if project uses Rake test (Ruby).
_has_rake_test() {
  local d="$1"
  [[ -f "${d}/Rakefile" ]]
}

# Check if project uses Gradle wrapper (Java).
_has_gradlew() {
  local d="$1"
  [[ -f "${d}/gradlew" ]]
}

# Check if project uses Maven (Java).
_has_maven() {
  local d="$1"
  [[ -f "${d}/pom.xml" ]]
}

# Check if project has Makefile with test target.
_has_make_test() {
  local d="$1"
  [[ -f "${d}/Makefile" ]] && grep -q '^test:' "${d}/Makefile" 2>/dev/null
}

# --- Lint Framework Detection ---

# Auto-detect lint tool for the project.
_detect_lint_cmd() {
  local d="${1:-.}"
  if _has_ruff_config "$d"; then echo "ruff check ."; return 0; fi
  if _has_flake8_config "$d"; then echo "flake8"; return 0; fi
  if _has_eslint_config "$d"; then echo "npx eslint ."; return 0; fi
  if _has_cargo "$d"; then echo "cargo clippy"; return 0; fi
  if _has_golangci_lint "$d"; then echo "golangci-lint run"; return 0; fi
  if _has_rubocop "$d"; then echo "bundle exec rubocop"; return 0; fi
  if [[ -f "${d}/Makefile" ]] && grep -q '^lint:' "${d}/Makefile" 2>/dev/null; then
    echo "make lint"; return 0
  fi
  return 1
}

# Validate that a lint command's first word is on the lint allowlist.
_is_allowed_lint_cmd() {
  local first_word="${1%% *}"
  local allowed
  for allowed in $_LINT_ALLOWLIST; do
    [[ "$first_word" = "$allowed" ]] && return 0
  done
  return 1
}

# --- Lint Tool Detectors ---

# Check if project uses ruff (Python).
_has_ruff_config() {
  local d="$1"
  [[ -f "${d}/ruff.toml" ]] && return 0
  [[ -f "${d}/pyproject.toml" ]] && grep -q '\[tool\.ruff\]' "${d}/pyproject.toml" 2>/dev/null
}

# Check if project uses flake8 (Python).
_has_flake8_config() {
  local d="$1"
  [[ -f "${d}/.flake8" ]] && return 0
  [[ -f "${d}/setup.cfg" ]] && grep -q '\[flake8\]' "${d}/setup.cfg" 2>/dev/null
}

# Check if project uses ESLint (Node).
_has_eslint_config() {
  local d="$1"
  local f
  for f in "${d}"/.eslintrc* "${d}"/eslint.config.*; do
    [[ -f "$f" ]] && return 0
  done
  if [[ -f "${d}/package.json" ]]; then
    jq -e '.devDependencies.eslint // empty' "${d}/package.json" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Check if project uses golangci-lint (Go).
_has_golangci_lint() {
  local d="$1"
  [[ -f "${d}/.golangci.yml" ]]
}

# Check if project uses RuboCop (Ruby).
_has_rubocop() {
  local d="$1"
  [[ -f "${d}/.rubocop.yml" ]]
}
