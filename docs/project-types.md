# Supported Project Types

Reference for auto-detected test and lint frameworks, manual configuration for unsupported languages, and test output parsing.

## Auto-Detected Test Frameworks

When `AUTOPILOT_TEST_CMD` is empty (the default), Autopilot probes the project directory and picks the **first match** in this order:

| Priority | Framework | Detection Logic | Command Run |
|----------|-----------|-----------------|-------------|
| 1 | **pytest** | `conftest.py` or `tests/conftest.py` exists; or `pyproject.toml` contains "pytest"; or any `requirements*.txt` contains "pytest" | `pytest -p no:cov` |
| 2 | **npm test** | `package.json` exists with a non-empty `scripts.test` field | `npm test` |
| 3 | **bats** | Any `*.bats` file exists in `tests/` | `bats tests/` |
| 4 | **make test** | `Makefile` exists with a `test:` target | `make test` |

**Precedence matters.** If your project has both `conftest.py` and a `package.json` with a test script, pytest wins. The first successful match is used and remaining checks are skipped.

**Coverage disabled.** Auto-detected pytest runs with `-p no:cov` to avoid coverage plugin overhead during pipeline runs. If you need coverage, set `AUTOPILOT_TEST_CMD` explicitly.

If none of the checks match, the test gate reports "no test command detected" and the pipeline continues without running tests.

---

## Auto-Detected Lint Commands

Lint detection is simpler than test detection. Autopilot checks for a single condition:

| Framework | Detection Logic | Command Run |
|-----------|-----------------|-------------|
| **make lint** | `Makefile` exists with a `lint:` target | `make lint` |

If no `Makefile` with a `lint:` target is found, the lint hook is a **no-op** (`true`) — it silently succeeds without running anything.

There is no `AUTOPILOT_LINT_CMD` config variable. To use a custom lint command, add a `lint:` target to your Makefile that calls the linter you want:

```makefile
lint:
	npx eslint src/
	# or: ruff check .
	# or: cargo clippy
```

---

## Manual Configuration for Unsupported Languages

For languages and frameworks not auto-detected, set `AUTOPILOT_TEST_CMD` in `autopilot.conf`:

| Language | Framework | Example `AUTOPILOT_TEST_CMD` |
|----------|-----------|------------------------------|
| Ruby | RSpec | `bundle exec rspec` |
| Rust | Cargo | `cargo test` |
| Go | go test | `go test ./...` |
| Java | Gradle | `./gradlew test` |
| Java | Maven | `mvn test` |
| JavaScript | Jest | `npx jest` |
| JavaScript | Vitest | `npx vitest run` |
| Python | unittest | `python -m unittest discover` |
| Elixir | ExUnit | `mix test` |

### Configuration Examples

**Rust project:**

```bash
# autopilot.conf
AUTOPILOT_TEST_CMD="cargo test"
```

**Go project:**

```bash
# autopilot.conf
AUTOPILOT_TEST_CMD="go test ./..."
```

**Ruby/RSpec project:**

```bash
# autopilot.conf
AUTOPILOT_TEST_CMD="bundle exec rspec"
```

**Java/Gradle project:**

```bash
# autopilot.conf
AUTOPILOT_TEST_CMD="./gradlew test"
```

**Combined lint and test:**

```bash
# autopilot.conf
AUTOPILOT_TEST_CMD="npm run lint && npx jest"
```

When `AUTOPILOT_TEST_CMD` is set, auto-detection is bypassed entirely.

---

## Test Output Parsing

Autopilot parses test output to produce structured summaries (pass/fail counts) in PR comments and metrics. Two output formats are currently recognized:

### Recognized Formats

| Format | Framework | What's Parsed |
|--------|-----------|---------------|
| **TAP** (Test Anything Protocol) | bats | Lines starting with `ok <N>` and `not ok <N>` |
| **pytest summary** | pytest | The `=== N passed, M failed in X.XXs ===` summary line |

**TAP parsing** counts `ok` lines as passes and `not ok` lines as failures. This works with any TAP-producing tool, not just bats.

**pytest parsing** extracts passed, failed, and error counts from the summary line. Errors are counted as failures. If the caller doesn't provide a duration, the parser also extracts pytest's own duration from the summary.

### Unrecognized Formats

For all other test frameworks (Go, Rust, Ruby, Java, Jest, etc.), Autopilot:

- Still detects **pass vs. fail** based on the command's exit code (0 = pass, non-zero = fail)
- Includes raw test output (tail) in PR comments via `AUTOPILOT_TEST_OUTPUT_TAIL` (default: 80 lines)
- Does **not** produce structured pass/fail counts — the PR comment shows output without a `N passed, M failed` summary
- Includes test output in fixer prompts (up to `AUTOPILOT_MAX_TEST_OUTPUT` lines, default: 500) so the fixer agent can see exactly what failed

### Timeout Detection

If a test command exceeds its timeout, Autopilot reports the timeout regardless of output format. The summary shows `0 passed, 0 failed` with a timeout indicator.

---

## Related Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_TEST_CMD` | `""` (auto-detect) | Custom test command — bypasses auto-detection |
| `AUTOPILOT_TEST_TIMEOUT` | `300` | Timeout for test command in coder Stop hooks |
| `AUTOPILOT_TIMEOUT_TEST_GATE` | `300` | Timeout for the full test gate pipeline phase |
| `AUTOPILOT_TEST_OUTPUT_TAIL` | `80` | Lines of test output in PR comments |
| `AUTOPILOT_MAX_TEST_OUTPUT` | `500` | Lines of test output in fixer/test-fixer prompts |

**Note:** `AUTOPILOT_TEST_TIMEOUT` and `AUTOPILOT_TIMEOUT_TEST_GATE` serve different scopes. `TEST_TIMEOUT` controls the test command inside coder Stop hooks (runs frequently during editing). `TIMEOUT_TEST_GATE` controls the full test gate pipeline phase (includes setup, test execution, and result parsing). When both default to 300s, the gate-level timeout takes precedence — if overhead pushes the gate past its limit, the per-test timeout indicator may not fire. Set `TIMEOUT_TEST_GATE` higher than `TEST_TIMEOUT` if you need the per-test timeout message.

See [Configuration Reference](configuration.md) for the full list of variables.
