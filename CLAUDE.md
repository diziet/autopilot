# Autopilot

Autopilot is an autonomous PR pipeline that works through a project's task list with Claude Code agents. It is the `pr-pipeline` from the devops repo, extracted and generalized into a standalone tool.

## Architecture

- **Pure bash** — the product in `bin/` and `lib/` is shell scripts only: no Python, no Node. The repo tooling in `scripts/` may use Python 3 from the system, standard library only.
- **bats-core** for testing — `make test` runs `bats tests/`. Always run with `--jobs 20` or use `make test`.
- **shellcheck** for linting — `make lint` runs `shellcheck` on all `.sh` files.
- Entry points: `bin/autopilot-dispatch` (dispatcher) and `bin/autopilot-review` (reviewer cron + standalone).
- Shared libraries in `lib/`. Prompts in `prompts/`. Reviewer personas in `reviewers/`.
- Config comes from `autopilot.conf`, parsed as `KEY=VALUE` lines, not sourced. Every config variable starts with `AUTOPILOT_`.

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

## Workflow

These rules cover work done outside autopilot's task pipeline, by a person or another agent.
An autopilot coder works in the task worktree the daemon created and follows its prompt.

- One worktree per task: `make worktree b=<type>/<name>` creates `../<type>/<name>` from
  `origin/main` and installs the hooks. Commit and push from that worktree.
- Local `main` is a read-only mirror of `origin/main`. The hooks in `.githooks/` refuse a commit
  on `main`, a merge commit on `main`, a push to `main`, and moving `main` to a commit that
  `origin/main` does not contain.
- Autopilot's self-update runs `git fetch origin main` and `git merge --ff-only origin/main` in
  the primary checkout (`lib/self_update.sh`). The dispatcher runs `git pull --ff-only`. The hooks
  allow both, because they only fast-forward `main` to `origin/main`.
- Never `git stash`. Every worktree of the repo shares one stash stack.
- `make merge pr=N` is the only merge path for this repo's PRs. It runs the gate on a preview
  merge of the PR into `origin/main` and merges with a merge commit, never a squash.
  `lib/merger.sh` squash-merges autopilot's own task PRs; that is product behavior.
- `make gate` runs `gate-wiring-check`, `test-tooling` and `check` under a machine-wide lock.
  `make doctor` is the preflight; run it first when a gate fails for no visible reason.
- `make sync` fetches and fast-forwards the current branch.
- `make branches-gc` is report-only. `make branches-gc args=--delete` removes only merged branches.
- `make install-dev` sets up a development machine. `make install` installs the product.
- Prose follows `docs/writing-style.md`.

## Config System

- Config files are **parsed line-by-line**, not `source`d, so a config file cannot execute arbitrary code.
- Only lines matching `^AUTOPILOT_[A-Z_]+=` are accepted.
- Precedence: env var > config file > built-in default.
- `lib/config.sh` saves the env vars before parsing and restores them after.

## File Layout

```
bin/             Entry points (autopilot-dispatch, autopilot-review)
lib/             Shared shell libraries
prompts/         Agent prompt files (.md)
reviewers/       Reviewer persona files (.md)
examples/        Example config and task files
docs/            Documentation
tests/           bats test files
tests/tooling/   unittest tests for the repo tooling in scripts/
scripts/         Repo tooling: make merge, gate, doctor, worktree, sync
.githooks/       Git hooks that keep local main read-only
Makefile         test, lint, install targets; `make help` lists all
```

## IMPORTANT: Forbidden Actions

- **Do not run `gh pr merge`.** Autopilot's merger lands `autopilot/task-N` PRs. Every other PR lands through `make merge pr=N` (see Workflow).
- **Do not run `git push` to `main`** — only push to your feature branch (`autopilot/task-N`).

## Conventions

- Branch prefix: `autopilot/task-N` (configurable via `AUTOPILOT_BRANCH_PREFIX`).
- State directory: `.autopilot/` (state.json, logs/, locks/).
- All `gh` API calls use `AUTOPILOT_TIMEOUT_GH` for timeout.
- All agent spawns `unset CLAUDECODE` before launching Claude.
- Commit messages use conventional prefixes: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`.

## Reference

The context file `docs/autopilot-plan.md` (from the devops repo) contains the full extraction plan: architecture details, config schema, state machine, and task descriptions. Read it for implementation details.
