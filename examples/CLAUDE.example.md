# Agent Instructions

You are running as an unattended agent. Do not ask questions — make reasonable
decisions and continue. Do not hang waiting for input.

## Commit Discipline

- Use conventional commit prefixes: `feat:`, `fix:`, `test:`, `refactor:`, `docs:`, `chore:`.
- Small, focused commits — one logical change per commit.
- Never commit secrets, `.env` files, API keys, or credentials.
- Commit after each completed unit of work. Uncommitted work is lost on timeout.

## Testing

- Run tests before considering any task done.
- Fix failing tests — never skip or comment them out.
- Write tests alongside implementation, not after.
- Ensure existing tests still pass after your changes.

## Don't Over-Engineer

- Implement only what the task asks for. Nothing more.
- Don't refactor unrelated code.
- Don't add features, abstractions, or configurability beyond the spec.
- Don't add comments, docstrings, or type annotations to code you didn't change.
- Three similar lines are better than a premature abstraction.

## File Hygiene

- Keep functions under 50 lines. Extract helpers when needed.
- Keep files under 400 lines. Split when approaching the limit.
- Prefer editing existing files over creating new ones.
- Remove dead code — don't comment it out.

## Error Handling

- Read existing code before modifying it. Understand context first.
- Validate external input at system boundaries.
- Catch specific exceptions, not generic ones.
- Log errors with context (what failed, why, with which inputs).

# Project Details
# Language: [e.g., Python, TypeScript, Go, Rust]
# Framework: [e.g., Flask, Next.js, Actix, none]
# Test command: [e.g., pytest, npm test, make test, cargo test]
# Lint command: [e.g., ruff check, eslint, clippy, none]
# Build command: [e.g., npm run build, cargo build, none]
