# Configuration Reference

Complete reference for all Autopilot configuration variables, account setup, custom reviewers, and the permission model.

## Config Files

Autopilot reads configuration from two locations in your project directory:

| File | Purpose |
|------|---------|
| `autopilot.conf` | Project-level config (commit to repo) |
| `.autopilot/config.conf` | Local overrides (gitignored) |

Both files use plain `KEY=VALUE` syntax. Only lines matching `AUTOPILOT_[A-Z_]+=` are accepted. Comments start with `#`. Blank lines are ignored.

```bash
# Example autopilot.conf
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
AUTOPILOT_TIMEOUT_CODER=3600
AUTOPILOT_REVIEWERS="general,security"
```

### Security

Config files are **parsed line-by-line, never sourced**. This prevents arbitrary code execution from cloned repositories. Unknown variable names are silently ignored.

### Precedence

When the same variable is set in multiple places, the highest-priority source wins:

```
environment variable  >  .autopilot/config.conf  >  autopilot.conf  >  built-in default
```

This means you can temporarily override any setting with an environment variable:

```bash
AUTOPILOT_TIMEOUT_CODER=1800 autopilot-dispatch /path/to/project
```

### Value Syntax

- Unquoted: `AUTOPILOT_TIMEOUT_CODER=2700`
- Double-quoted: `AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"`
- Single-quoted: `AUTOPILOT_CLAUDE_CMD='claude'`

Surrounding quotes (single or double) are stripped automatically. Special characters inside quotes are preserved as-is.

---

## All Variables

### Claude Code Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_CLAUDE_CMD` | `claude` | Claude CLI binary name or path |
| `AUTOPILOT_CLAUDE_FLAGS` | `""` (empty) | Extra flags passed to every Claude invocation |
| `AUTOPILOT_CLAUDE_OUTPUT_FORMAT` | `json` | Output format for Claude responses |
| `AUTOPILOT_CODER_CONFIG_DIR` | `""` (empty) | `CLAUDE_CONFIG_DIR` for coder/fixer/merger agents |
| `AUTOPILOT_REVIEWER_CONFIG_DIR` | `""` (empty) | `CLAUDE_CONFIG_DIR` for reviewer agents |

### Task Source

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_TASKS_FILE` | `""` (auto-detect) | Path to the tasks file relative to project root |
| `AUTOPILOT_CONTEXT_FILES` | `""` (none) | Colon-separated paths to reference documents |

### Timeouts (seconds)

| Variable | Default | Human | Description |
|----------|---------|-------|-------------|
| `AUTOPILOT_TIMEOUT_CODER` | `2700` | 45 min | Coder agent implementation time |
| `AUTOPILOT_TIMEOUT_FIXER` | `900` | 15 min | Fixer agent review feedback time |
| `AUTOPILOT_TIMEOUT_TEST_GATE` | `300` | 5 min | Test gate execution |
| `AUTOPILOT_TIMEOUT_REVIEWER` | `600` | 10 min | Full review cycle (all reviewers) |
| `AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE` | `450` | 7.5 min | Per-reviewer Claude call (must be < `TIMEOUT_REVIEWER`) |
| `AUTOPILOT_TIMEOUT_MERGER` | `600` | 10 min | Merger agent (final review + merge) |
| `AUTOPILOT_TIMEOUT_SUMMARY` | `60` | 1 min | Background task summary generation |
| `AUTOPILOT_TIMEOUT_DIAGNOSE` | `300` | 5 min | Failure diagnosis agent |
| `AUTOPILOT_TIMEOUT_SPEC_REVIEW` | `300` | 5 min | Spec compliance review |
| `AUTOPILOT_TIMEOUT_FIX_TESTS` | `600` | 10 min | Test fixer agent |
| `AUTOPILOT_TIMEOUT_GH` | `30` | 30 sec | GitHub API calls via `gh` CLI |

**Timeout nesting:** `AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE` must be less than `AUTOPILOT_TIMEOUT_REVIEWER`. The outer timeout covers the full review cycle including diff fetching, comment posting, and all reviewer calls. The inner timeout is per individual reviewer.

### Limits

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_MAX_RETRIES` | `5` | Max coder respawns per task before diagnosis |
| `AUTOPILOT_MAX_TEST_FIX_RETRIES` | `3` | Max test fixer attempts before escalating |
| `AUTOPILOT_STALE_LOCK_MINUTES` | `45` | Auto-clean lock files older than this |
| `AUTOPILOT_MAX_LOG_LINES` | `1000` | Rotate `pipeline.log` after this many lines |
| `AUTOPILOT_MAX_DIFF_BYTES` | `500000` | Skip review for diffs larger than 500 KB |
| `AUTOPILOT_MAX_SUMMARY_LINES` | `50` | Max lines of completed-task summary in coder context |
| `AUTOPILOT_MAX_SUMMARY_ENTRY_LINES` | `20` | Max lines per individual summary entry |

### Testing

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_TEST_CMD` | `""` (auto-detect) | Custom test command (bypasses auto-detection) |
| `AUTOPILOT_TEST_TIMEOUT` | `300` | Test execution timeout in seconds |
| `AUTOPILOT_TEST_OUTPUT_TAIL` | `80` | Lines of test output included in PR comments |

When `AUTOPILOT_TEST_CMD` is empty, Autopilot auto-detects the test framework by checking for (in order): `pytest`, `npm test`, `bats`, `make test`.

### Review

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_REVIEWERS` | `general,dry,performance,security,design` | Comma-separated reviewer personas |
| `AUTOPILOT_SPEC_REVIEW_INTERVAL` | `5` | Run spec compliance every Nth merged task (0 = disable) |

### Branches

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_BRANCH_PREFIX` | `autopilot` | Branch naming prefix (`<prefix>/task-N`) |
| `AUTOPILOT_TARGET_BRANCH` | `main` | Base branch for PRs |

---

## Permission Model

### The Problem

Claude Code normally prompts for permission before running tools (file writes, shell commands, etc.). In an interactive terminal, you approve each action. In cron or a CI pipeline, there is **no terminal** — Claude hangs indefinitely waiting for approval that never comes.

### TTY Detection

The dispatcher checks `[[ -t 0 ]]` (stdin is a TTY) at startup:

- **Interactive** (TTY detected): The pipeline runs normally. Claude prompts for permissions as usual. Useful for manual testing.
- **Non-interactive** (no TTY, e.g., cron): The pipeline checks whether `AUTOPILOT_CLAUDE_FLAGS` contains `--dangerously-skip-permissions`. If the flag is missing, the dispatcher logs a `CRITICAL` error and exits immediately — rather than letting Claude hang for 45 minutes.

### Enabling Unattended Operation

For cron/automated use, you **must** explicitly opt in:

```bash
# In autopilot.conf
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
```

Or via environment variable:

```bash
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions" autopilot-dispatch /path/to/project
```

This is intentionally not the default. The `--dangerously-skip-permissions` flag grants Claude unrestricted tool access — the security tradeoff should be a conscious decision, not a silent default.

### What This Means in Practice

| Mode | Permission flag needed? | What happens |
|------|------------------------|--------------|
| Manual run in terminal | No | Claude prompts interactively |
| Cron job | **Yes** | Pipeline exits with CRITICAL error if missing |
| Piped input (`echo \| autopilot-dispatch`) | **Yes** | Same as cron — no TTY detected |

---

## Account Setup

### Single Account (Default)

When both `AUTOPILOT_CODER_CONFIG_DIR` and `AUTOPILOT_REVIEWER_CONFIG_DIR` are empty (the default), all agents use the same Claude configuration — the system default `claude` command with no config directory override.

This is the simplest setup and works for most projects.

### Multi-Account Mode

For teams that want to separate coder and reviewer API usage (separate billing, rate limits, or API keys), set the config directory for each role:

```bash
# In autopilot.conf
AUTOPILOT_CODER_CONFIG_DIR="/Users/you/.claude-coder"
AUTOPILOT_REVIEWER_CONFIG_DIR="/Users/you/.claude-reviewer"
```

When set, Autopilot wraps Claude invocations with `CLAUDE_CONFIG_DIR=<dir>` for the appropriate role:

- **Coder config** (`AUTOPILOT_CODER_CONFIG_DIR`): Used by the coder, fixer, merger, test fixer, diagnostician, and summarizer agents.
- **Reviewer config** (`AUTOPILOT_REVIEWER_CONFIG_DIR`): Used by the reviewer agents. When empty, falls back to the coder config directory.

Each config directory should contain a valid Claude Code configuration (credentials, settings, etc.). Create them by running `claude` once with each directory:

```bash
CLAUDE_CONFIG_DIR=/Users/you/.claude-coder claude --version
CLAUDE_CONFIG_DIR=/Users/you/.claude-reviewer claude --version
```

### Custom Claude Binary

If you have a wrapper script or a specific Claude binary path:

```bash
AUTOPILOT_CLAUDE_CMD="/usr/local/bin/claude-custom"
```

The preflight check validates that the configured command is available on `PATH` (or at the specified path).

---

## Custom Reviewers

### Built-in Personas

Autopilot ships with five reviewer personas in the `reviewers/` directory:

| Persona | File | Focus |
|---------|------|-------|
| **general** | `reviewers/general.md` | Correctness, clarity, error handling, naming, API contracts |
| **dry** | `reviewers/dry.md` | Code duplication, missed abstractions, magic values |
| **performance** | `reviewers/performance.md` | Algorithmic complexity, resource leaks, redundant I/O |
| **security** | `reviewers/security.md` | Injection attacks, auth issues, secrets exposure, input validation |
| **design** | `reviewers/design.md` | Contract drift, dead parameters, broken math, validation gaps |

All five run by default on every PR.

### Selecting Reviewers

To run only specific reviewers, set `AUTOPILOT_REVIEWERS` to a comma-separated list:

```bash
# Run only security and general reviews
AUTOPILOT_REVIEWERS="general,security"
```

### Adding Custom Personas

Create a markdown file in the `reviewers/` directory with the reviewer's prompt:

```bash
# reviewers/accessibility.md
cat > reviewers/accessibility.md << 'EOF'
You are a senior accessibility reviewer. Review the following PR diff for:

1. Missing ARIA attributes on interactive elements
2. Images without alt text
3. Color contrast issues in CSS changes
4. Missing keyboard navigation support
5. Screen reader compatibility problems

For each issue found, provide:
- The file and approximate location
- What the problem is
- How to fix it

If you find no accessibility issues, respond with exactly: NO_ISSUES_FOUND
EOF
```

Then add it to your config:

```bash
AUTOPILOT_REVIEWERS="general,dry,performance,security,design,accessibility"
```

### Reviewer Output Format

Each reviewer persona should follow the output convention:

- **Issues found:** Numbered list of issues with file references and suggested fixes.
- **No issues:** Respond with exactly `NO_ISSUES_FOUND`. When all reviewers return this sentinel, the pipeline skips the fixer agent entirely (clean-review skip).

---

## Context Files

Reference documents that the coder agent should read before implementing each task.

```bash
AUTOPILOT_CONTEXT_FILES="docs/spec.md:docs/api-reference.md:docs/design-decisions.md"
```

- Paths are **colon-separated** (like Unix `PATH`).
- Relative paths are resolved from the project root.
- Absolute paths are used as-is.
- Non-existent files are silently skipped.
- Multiple files are concatenated with `---` separators.

Common uses:
- Project specification documents
- API references
- Architecture decision records
- Style guides

See [task-format.md](task-format.md) for more details on how context files integrate with tasks.

---

## Test Command

### Auto-Detection

When `AUTOPILOT_TEST_CMD` is empty (the default), Autopilot detects the test framework automatically by checking for:

1. `pytest` — if available on PATH
2. `npm test` — if `package.json` exists
3. `bats` — if available on PATH
4. `make test` — if `Makefile` exists with a `test` target

### Custom Test Command

Override auto-detection for projects with non-standard setups:

```bash
# Run a specific test suite
AUTOPILOT_TEST_CMD="make test-integration"

# Run tests with specific flags
AUTOPILOT_TEST_CMD="pytest tests/ -x --timeout=60"

# Run multiple test steps
AUTOPILOT_TEST_CMD="npm run lint && npm test"
```

When `AUTOPILOT_TEST_CMD` is set, the auto-detection allowlist is bypassed entirely.

---

## Spec Compliance Review

Autopilot periodically reviews merged PRs against your project specification to detect drift:

```bash
# Run spec review every 5 merged tasks (default)
AUTOPILOT_SPEC_REVIEW_INTERVAL=5

# Disable spec review
AUTOPILOT_SPEC_REVIEW_INTERVAL=0
```

When triggered, the spec reviewer fetches the last 5 merged PR diffs, compares them against the project spec, and files a GitHub issue if deviations are found.

---

## Example Configurations

### Minimal (Interactive Testing)

```bash
# autopilot.conf — bare minimum
# No config needed! Just run: autopilot-dispatch /path/to/project
```

### Standard Cron Setup

```bash
# autopilot.conf — typical unattended setup
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
AUTOPILOT_CONTEXT_FILES="docs/spec.md"
```

### Large Project with Custom Tests

```bash
# autopilot.conf
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
AUTOPILOT_TIMEOUT_CODER=3600
AUTOPILOT_TEST_CMD="make test-all"
AUTOPILOT_TEST_TIMEOUT=600
AUTOPILOT_MAX_RETRIES=3
AUTOPILOT_MAX_DIFF_BYTES=1000000
```

### Multi-Account with Selective Reviews

```bash
# autopilot.conf
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
AUTOPILOT_CODER_CONFIG_DIR="/Users/dev/.claude-coder"
AUTOPILOT_REVIEWER_CONFIG_DIR="/Users/dev/.claude-reviewer"
AUTOPILOT_REVIEWERS="general,security,design"
AUTOPILOT_SPEC_REVIEW_INTERVAL=10
```

### Local Overrides

Use `.autopilot/config.conf` for machine-specific settings that shouldn't be committed:

```bash
# .autopilot/config.conf — not committed to git
AUTOPILOT_CODER_CONFIG_DIR="/Users/me/.claude-account1"
AUTOPILOT_REVIEWER_CONFIG_DIR="/Users/me/.claude-account2"
```

---

## Inspecting Effective Config

When the dispatcher starts, it logs the effective configuration with source annotations to `.autopilot/logs/pipeline.log`:

```
  AUTOPILOT_CLAUDE_CMD=claude [default]
  AUTOPILOT_CLAUDE_FLAGS=--dangerously-skip-permissions [autopilot.conf]
  AUTOPILOT_TIMEOUT_CODER=3600 [env]
  AUTOPILOT_REVIEWERS=general,security [.autopilot/config.conf]
  ...
```

Each variable shows its value and where it came from: `[default]`, `[autopilot.conf]`, `[.autopilot/config.conf]`, or `[env]`.
