# Writing project.md

High-level context that helps the agent understand what the system is, why it
exists, and how the pieces fit together. This is injected into every task's
context alongside CLAUDE.md.

---

## What it should contain

- What the system does, in plain language (3–5 sentences)
- Who uses it and how (the user-facing workflow)
- The major components and how they relate to each other (a brief architectural
  sketch, not a detailed design doc)
- Key constraints or invariants that affect every task (e.g., "the webhook
  endpoint must respond in under 200ms — all heavy work happens asynchronously")
- Anything the agent needs to understand the *why* behind design decisions, so
  it can make reasonable calls when a task description doesn't cover an edge
  case

## What it should NOT contain

- Tech stack choices (those go in CLAUDE.md as conventions)
- Implementation details for specific components (those go in task descriptions)
- Configuration values, environment variables, or deployment specifics
- Anything that duplicates CLAUDE.md

## Length target

15–30 lines. If it's longer, you're probably including implementation details
that belong elsewhere.

## Litmus test

If you removed CLAUDE.md and all task descriptions, could an engineer read
project.md alone and explain what the system does to a colleague? That's the
right level of detail.
