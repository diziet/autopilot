# Autopilot

Autonomous PR pipeline that works through a project's task list using Claude Code agents. Extracts and generalizes the `pr-pipeline` from the devops repo into a standalone tool.

## Architecture

- **Pure bash** — no Python, no Node. Shell scripts only.
- **bats-core** for testing — `make test` runs `bats tests/`.
- **shellcheck** for linting — `make lint` runs `shellcheck` on all `.sh` files.
- Entry points: `bin/autopilot-dispatch` (dispatcher) and `bin/autopilot-review` (reviewer cron + standalone).
- Shared libraries in `lib/`. Prompts in `prompts/`. Reviewer personas in `reviewers/`.
- Config via `autopilot.conf` (parsed `KEY=VALUE`, not sourced). All config vars prefixed `AUTOPILOT_`.

## Coding Standards

- Every function has a one-line comment explaining what it does.
- Functions over 50 lines should be split into helpers.
- Files over 300 lines should be split into modules.
- All variables in functions must be declared `local`.
- Use `readonly` for constants.
- Quote all variable expansions: `"$var"`, `"${array[@]}"`.
- No `eval`. No backtick command substitution — use `$()`.
- Error handling: check return codes, use `set -euo pipefail` in entry points.
- Logging: use `log_msg` (from lib/state.sh), not `echo` to stderr.

## Testing

- Every `lib/*.sh` module gets a corresponding `tests/test_*.bats` file.
- Tests must be deterministic — no network calls, no real Claude/GitHub invocations.
- Mock external commands by defining shell functions in test setup.
- Test file naming: `tests/test_<module>.bats`.
- Run tests: `make test` or `bats tests/`.

## Config System

- Config files are **parsed line-by-line**, not `source`d (security: prevents arbitrary code execution).
- Only lines matching `^AUTOPILOT_[A-Z_]*=` are accepted.
- Precedence: env var > config file > built-in default.
- `lib/config.sh` snapshots env vars before parsing, restores after.

## File Layout

```
bin/             Entry points (autopilot-dispatch, autopilot-review)
lib/             Shared shell libraries
prompts/         Agent prompt files (.md)
reviewers/       Reviewer persona files (.md)
examples/        Example config and task files
docs/            Documentation
tests/           bats test files
Makefile         test, lint, install targets
```

## Conventions

- Branch prefix: `autopilot/task-N` (configurable via `AUTOPILOT_BRANCH_PREFIX`).
- State directory: `.autopilot/` (state.json, logs/, locks/).
- All `gh` API calls use `AUTOPILOT_TIMEOUT_GH` for timeout.
- All agent spawns `unset CLAUDECODE` before launching Claude.
- Commit messages use conventional prefixes: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`.

## Reference

The full extraction plan with architecture details, config schema, state machine, and task descriptions is in the context file `docs/autopilot-plan.md` (from the devops repo). Consult it for implementation details.
