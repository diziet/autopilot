# Task File Format

How to write task files for Autopilot. Each task becomes one PR. The pipeline reads the next task, spawns a coder agent, runs the tests, reviews the code, and merges the PR.

## File Detection

Autopilot looks for the task file in this order:

1. **`AUTOPILOT_TASKS_FILE`** — if set in config, Autopilot uses that path, relative to the project root
2. **`tasks.md`** — in the project root
3. **`*implementation*guide*.md`** — a glob that matches files such as `Implementation-Guide.md` or `implementation_guide_v2.md`

### Ambiguity Warning

When the glob fallback (step 3) matches **multiple files**, Autopilot uses the first match and prints a warning:

```
WARNING: Multiple task files found: Implementation-Guide.md, implementation_guide_v2.md.
Using: Implementation-Guide.md. Set AUTOPILOT_TASKS_FILE to be explicit.
```

The warning goes to stderr, because it appears before pipeline initialization, when logging is not yet available. To remove the ambiguity, set `AUTOPILOT_TASKS_FILE`:

```bash
# In autopilot.conf
AUTOPILOT_TASKS_FILE="docs/implementation-plan.md"
```

`autopilot-doctor` also checks for this ambiguity and reports it as a warning.

---

## Supported Formats

Autopilot recognizes two heading styles. Use one style for the whole file; do not mix them.

### Format 1: `## Task N` (Recommended)

A level-2 heading: `Task`, a number, and optionally a colon and a title.

```markdown
# Project Tasks

## Task 1: Set up project scaffold

Create the initial project structure with README.md, .gitignore, and a basic
directory layout (src/, tests/). Add a Makefile with test and lint targets.
Include a trivial passing test.

## Task 2: Add configuration loader

Implement lib/config.sh with the following features:
- Parse KEY=VALUE config files
- Support environment variable overrides
- Log effective config at startup

## Task 3: Add core business logic

Build the main feature described in docs/spec.md. Follow the patterns
established in Tasks 1-2.

Acceptance criteria:
- All new functions have type hints and docstrings
- Test coverage for happy path and error cases
- Linting passes cleanly
```

### Format 2: `### PR N`

A level-3 heading: `PR` and a number. This format suits a task list that is a subsection of a larger document.

```markdown
### PR 1: Initial scaffold

Set up directories and basic tooling.

### PR 2: Config system

Parse config files with precedence handling.

### PR 3: Core feature

Implement the main feature with tests.
```

### Format Detection

Autopilot detects the format by checking these patterns in order:

- Lines starting with `## Task ` followed by a digit → `task_n` format
- Lines starting with `### PR ` followed by a digit → `pr_n` format

If neither pattern matches, the format is unknown and parsing returns an error.

---

## Task Structure

A task section is every line from its heading up to the next heading of the same type, or to the end of the file.

```markdown
## Task 4: Add error handling
                              ← heading: detected by parser
Review the implementation from Task 3 and add:
- Input validation at system boundaries
- Proper error messages with context
- Edge case handling (empty input, large input)
- Tests for each error path
                              ← body: fed to the coder agent

## Task 5: ...               ← next heading: marks end of Task 4
```

The full section (heading + body) is passed to the coder agent as its implementation prompt.

### Task Numbering

- Numbers must be unique within the file.
- A number matches only as a whole number: looking for Task 1 does not match Task 10.
- Autopilot processes tasks in number order (1, 2, 3, ...).
- Gaps in numbering are allowed (1, 2, 5 — tasks 3 and 4 are skipped).

### PR Title Extraction

Autopilot takes the PR title from the first of these sources that gives one:

1. **Task heading** — the title in the task heading. For example, `## Task 3: Add CLI entry point` becomes `Task 3: Add CLI entry point`. In the `### PR N` format, the prefix becomes `Task N`.
2. **TITLE: prefix** — searches the coder's output for a line starting with `TITLE:`.
3. **Oldest commit** — the message of the oldest commit on the task branch that is not on the target branch.
4. **Generic fallback** — `Task N`, when no source above gives a title.

---

## Previously Completed Tasks

Add a section for completed task summaries at the top of your file. Autopilot uses these summaries to give the coder agent context about what has already been built:

```markdown
# Project Tasks

## Previously Completed Tasks

### Task 1: Set up project scaffold
Created directory layout with src/, tests/, Makefile. Added pytest
as test framework with a passing smoke test.

### Task 2: Add configuration loader
Implemented lib/config.py with YAML parsing, env var overrides,
and typed config dataclass. Tests cover all precedence levels.

---

## Task 3: Add core business logic

Build the main feature...
```

`AUTOPILOT_MAX_SUMMARY_LINES` (default: 50 lines) and `AUTOPILOT_MAX_SUMMARY_ENTRY_LINES` (default: 20 lines per entry) limit how much summary text the pipeline includes.

---

## Context Files

Context files are reference documents that the coder should read before it implements each task. They are set in `AUTOPILOT_CONTEXT_FILES`, not in the task file.

### Configuration

Set `AUTOPILOT_CONTEXT_FILES` in `autopilot.conf` or as an environment variable:

```bash
# Single file
AUTOPILOT_CONTEXT_FILES="docs/spec.md"

# Multiple files (colon-separated, like Unix PATH)
AUTOPILOT_CONTEXT_FILES="docs/spec.md:docs/api-reference.md:docs/style-guide.md"
```

### Path Resolution

- **Relative paths** are resolved from the project root directory.
- **Absolute paths** are used as-is.
- **Non-existent files** are skipped without an error.

```bash
# Mix of relative and absolute paths
AUTOPILOT_CONTEXT_FILES="docs/spec.md:/shared/team-standards.md:ARCHITECTURE.md"
```

### How Context Is Used

When the coder agent starts, the contents of all context files are joined, separated by `---`, and included with the task description. Typical context files contain:

- **Project specifications** — what the code should do
- **API references** — endpoints, schemas, contracts
- **Architecture decisions** — patterns to follow or avoid
- **Style guides** — naming conventions, code organization rules

### Context vs. CLAUDE.md

| | `CLAUDE.md` | Context files |
|---|---|---|
| **Purpose** | Project conventions for the agent | Reference material for implementation |
| **Scope** | Always loaded by Claude Code | Loaded per task by Autopilot |
| **Content** | Coding standards, project rules | Specs, API docs, design docs |
| **Set via** | File in project root | `AUTOPILOT_CONTEXT_FILES` config |

Use `CLAUDE.md` for rules the agent should always follow. Use context files for reference documents about what to build.

---

## Writing Effective Tasks

### One Task = One PR

Each task should produce one mergeable PR on its own. Do not write a task that depends on uncommitted work from another task.

**Good:**
```markdown
## Task 3: Add user authentication endpoint

Create POST /api/auth/login that accepts email + password, validates
credentials against the users table, and returns a JWT token. Include
tests for valid login, invalid password, and missing user.
```

**Avoid:**
```markdown
## Task 3: Add auth, session management, and admin panel

Build the entire auth system including login, signup, password reset,
session tokens, remember-me, OAuth integration, and admin dashboard.
```

### Build Foundations First

Order tasks so that earlier ones establish patterns that later ones follow:

1. Project scaffold and tooling
2. Core data models and configuration
3. Main features (building on the foundation)
4. Error handling and edge cases
5. Polish and documentation

### Include Acceptance Criteria

When the definition of "done" isn't obvious, list specific criteria:

```markdown
## Task 7: Add rate limiting

Implement rate limiting on all API endpoints.

Acceptance criteria:
- Rate limit of 100 requests per minute per IP
- Returns 429 with Retry-After header when exceeded
- Configurable via RATE_LIMIT_RPM environment variable
- Unit tests for rate tracking and limit enforcement
- Integration test for the 429 response
```

### Keep Tasks Completable in One Session

The default coder timeout is 45 minutes (`AUTOPILOT_TIMEOUT_CODER=2700`). Scope each task to finish within that time. Split a task that is too large:

**Too large:**
```markdown
## Task 4: Implement the entire REST API
```

**Better — split into focused tasks:**
```markdown
## Task 4: Add GET /api/users endpoint with pagination

## Task 5: Add POST /api/users endpoint with validation

## Task 6: Add PUT/DELETE /api/users/:id endpoints
```

### Reference Prior Tasks

When a task builds on earlier work, mention what was done:

```markdown
## Task 6: Add caching to the API

Task 4 added the users endpoint and Task 5 added the products endpoint.
Add Redis caching to both endpoints with a 5-minute TTL. The Redis
connection config was set up in Task 2 (lib/config.py).
```

The "Previously Completed Tasks" section gives the coder this context automatically. Explicit references in the task description also tell the coder which earlier work the task depends on.

---

## Complete Example

A task file for a small web service:

```markdown
# Widget API — Implementation Tasks

## Previously Completed Tasks

<!-- Autopilot moves completed summaries here -->

---

## Task 1: Project scaffold

Create a Python project with:
- src/widgets/ package with __init__.py
- tests/ directory with conftest.py
- Makefile with test (pytest) and lint (ruff) targets
- requirements.txt with fastapi, uvicorn, pytest
- .gitignore for Python projects

## Task 2: Configuration module

Implement src/widgets/config.py:
- Load from environment variables with defaults
- DATABASE_URL (default: sqlite:///widgets.db)
- API_PORT (default: 8000)
- LOG_LEVEL (default: INFO)
- Typed dataclass for all config values
- Tests in tests/test_config.py

## Task 3: Widget data model

Implement src/widgets/models.py:
- Widget dataclass with id, name, description, price, created_at
- Validation: name 1-100 chars, price > 0
- JSON serialization/deserialization
- Tests for validation rules and serialization

## Task 4: Database layer

Implement src/widgets/db.py using the config from Task 2:
- create_widget, get_widget, list_widgets, delete_widget
- SQLite with parameterized queries
- Migration in migrations/001_initial.sql
- Tests using in-memory SQLite

## Task 5: API endpoints

Implement src/widgets/api.py using the service from Task 4:
- GET /widgets — list all (with pagination)
- GET /widgets/:id — get one (404 if missing)
- POST /widgets — create (400 on validation error)
- DELETE /widgets/:id — delete (404 if missing)
- Tests for all endpoints and error cases
```
