# Supported Project Types

Reference for auto-detected test and lint frameworks, manual configuration for unsupported languages, and test output parsing.

## Auto-Detected Test Frameworks

When `AUTOPILOT_TEST_CMD` is empty (the default), Autopilot probes the project directory and picks the **first match** in this order:

| Priority | Framework | Detection Logic | Command Run |
|----------|-----------|-----------------|-------------|
| 1 | **pytest** | `conftest.py` or `tests/conftest.py` exists; or `pyproject.toml` contains "pytest"; or any `requirements*.txt` contains "pytest" | `pytest -p no:cov` |
| 2 | **npm test** | `package.json` exists with a non-empty `scripts.test` field | `npm test` |
| 3 | **bats** | Any `*.bats` file exists in `tests/` | `bats tests/` |
| 4 | **Cargo** | `Cargo.toml` exists | `cargo test` |
| 5 | **Go** | `go.mod` exists | `go test ./...` |
| 6 | **RSpec** | `Gemfile` exists and contains "rspec" | `bundle exec rspec` |
| 7 | **Rake** | `Gemfile` and `Rakefile` exist | `bundle exec rake test` |
| 8 | **Gradle** | `gradlew` script exists | `./gradlew test` |
| 9 | **Maven** | `pom.xml` exists | `mvn test` |
| 10 | **make test** | `Makefile` exists with a `test:` target | `make test` |

**Precedence matters.** If your project has both `conftest.py` and a `package.json` with a test script, pytest wins. The first successful match is used and remaining checks are skipped.

**Coverage disabled.** Auto-detected pytest runs with `-p no:cov` to avoid coverage plugin overhead during pipeline runs. If you need coverage, set `AUTOPILOT_TEST_CMD` explicitly.

If none of the checks match, the test gate reports "no test command detected" and the pipeline continues without running tests.

---

## Auto-Detected Lint Commands

Autopilot auto-detects the lint tool by checking for project files in this order:

| Priority | Tool | Detection Logic | Command Run |
|----------|------|-----------------|-------------|
| 1 | **ruff** | `ruff.toml`, `.ruff.toml`, or `pyproject.toml` with `[tool.ruff]` | `ruff check .` |
| 2 | **flake8** | `.flake8`, `setup.cfg` with `[flake8]`, or `tox.ini` with `[flake8]` | `flake8` |
| 3 | **ESLint** | `.eslintrc.*` config file, or `package.json` with `eslintConfig` | `npx eslint .` |
| 4 | **Cargo clippy** | `Cargo.toml` exists | `cargo clippy` |
| 5 | **golangci-lint** | `.golangci.yml` or `.golangci.yaml` exists | `golangci-lint run` |
| 6 | **RuboCop** | `.rubocop.yml` exists | `bundle exec rubocop` |
| 7 | **make lint** | `Makefile` exists with a `lint:` target | `make lint` |

If none of the checks match, the lint hook is a **no-op** (`true`) — it silently succeeds without running anything.

There is no `AUTOPILOT_LINT_CMD` config variable. To use a custom lint command, add a `lint:` target to your Makefile (which is detected at priority 7):

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

Autopilot parses test output to produce structured summaries (pass/fail counts, duration) in PR comments and metrics. Seven output formats are recognized:

### Recognized Formats

| Format | Framework | What's Parsed |
|--------|-----------|---------------|
| **TAP** (Test Anything Protocol) | bats | Lines starting with `ok <N>` and `not ok <N>` |
| **pytest summary** | pytest | The `=== N passed, M failed in X.XXs ===` summary line |
| **Jest/Vitest** | Jest, Vitest | `Tests: N passed, M failed` and `Time:` lines |
| **RSpec** | RSpec | `N examples, M failures` summary line |
| **Go test** | go test | `ok`/`FAIL` lines with package paths and `--- FAIL` lines |
| **Cargo test** | Rust | `test result: ok/FAILED. N passed; M failed` summary |
| **JUnit/Maven** | Gradle, Maven | `Tests run: N, Failures: M, Errors: E` summary |

**TAP parsing** counts `ok` lines as passes and `not ok` lines as failures. This works with any TAP-producing tool, not just bats.

**pytest parsing** extracts passed, failed, and error counts from the summary line. Errors are counted as failures.

**Framework detection** is automatic when using auto-detected test commands — the parser matches based on the test command name (e.g., `cargo test` → Cargo parser). For custom `AUTOPILOT_TEST_CMD` values, Autopilot tries all parsers in sequence and uses the first that matches.

### Unrecognized Formats

For test output that doesn't match any recognized format, Autopilot:

- Still detects **pass vs. fail** based on the command's exit code (0 = pass, non-zero = fail)
- Includes raw test output (tail) in PR comments via `AUTOPILOT_TEST_OUTPUT_TAIL` (default: 80 lines)
- Shows a `"Tests: completed (no structured output detected)"` message instead of pass/fail counts
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
