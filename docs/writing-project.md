# Writing project.md

`project.md` gives the agent high-level context: what the system is, why it
exists, and how its parts fit together. Autopilot adds it to the context of
every task, alongside CLAUDE.md.

---

## What it should contain

- What the system does, in plain language (3–5 sentences)
- Who uses it and how (the user-facing workflow)
- The major components and how they relate to each other: a brief sketch of the
  architecture, not a detailed design doc
- Key constraints or invariants that affect every task (e.g., "the webhook
  endpoint must respond in under 200ms — all heavy work happens asynchronously")
- The reasons behind design decisions, so the agent can decide an edge case
  that a task description does not cover

## What it should NOT contain

- Tech stack choices (those go in CLAUDE.md as conventions)
- Implementation details for specific components (those go in task descriptions)
- Configuration values, environment variables, or deployment specifics
- Anything that duplicates CLAUDE.md

## Length target

15–30 lines. A longer file usually contains implementation details that belong
elsewhere.

## Litmus test

An engineer who reads only project.md, without CLAUDE.md or any task
description, should be able to explain to a colleague what the system does.
That is the right level of detail.
