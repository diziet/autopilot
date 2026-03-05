# Project Tasks

A task list for Autopilot. Each `## Task N` section describes one unit of work
that the pipeline will implement, test, review, and merge as a single PR.

## Previously Completed Tasks

<!-- Autopilot moves completed task summaries here automatically. -->

---

## Task 1: Set up project scaffold

Create the initial project structure with README.md, .gitignore, and a basic
directory layout (src/, tests/). Add a Makefile with `test` and `lint` targets.
Include a trivial passing test to verify the test framework works.

## Task 2: Add core data model

Define the primary data structures used throughout the application. Include
type definitions, validation logic, and unit tests for each model.

## Task 3: Implement main feature

Build the core feature described in the project spec. Follow the architecture
patterns established in Task 1. Write tests alongside the implementation.

Acceptance criteria:
- Feature works as described in docs/spec.md
- All new functions have type hints and docstrings
- Test coverage for happy path and error cases

## Task 4: Add error handling and edge cases

Review the implementation from Task 3 and add:
- Input validation at system boundaries
- Proper error messages with context
- Edge case handling (empty input, large input, malformed data)
- Tests for each error path

## Task 5: Final polish and documentation

- Update README.md with usage examples
- Add inline documentation where needed
- Run the full test suite and fix any issues
- Ensure linting passes cleanly

---

<!-- Tips for writing effective tasks:

1. One task = one PR. Keep tasks focused and independently mergeable.
2. Earlier tasks should set up foundations that later tasks build on.
3. Include acceptance criteria when the definition of "done" isn't obvious.
4. Reference docs with AUTOPILOT_CONTEXT_FILES for specs the coder needs.
5. Keep tasks small enough to complete in one agent session (~45 min).
6. If a task needs info from prior tasks, include it in "Previously Completed".
-->
