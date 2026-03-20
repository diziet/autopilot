# Writing tasks.md

An ordered list of implementation tasks, each producing a working, testable
commit. Processed sequentially by autopilot — one task per PR.

---

## File Structure

```markdown
# <Project Name> — Tasks

## Task 1: <Short title>

**Objective:**
<What this task must achieve, stated as outcomes.>

**Suggested path:**
<Design direction and guidance. Not a spec.>

**Tests:** `spec/path/to/spec_file.rb`
<List of key behavioral scenarios — not exhaustive.>

---

## Task 2: ...
```

## Writing the Objective

The objective is the most important part of each task. It defines success.

**Rules:**

- State what the task must achieve, not how to achieve it
- Include the *why* when it's not obvious — this helps the agent make good
  decisions on ambiguous cases (e.g., "engineers @mention specifically to
  re-run after failures, so blocking that would undermine the feature")
- Define behavioral requirements, not implementation requirements (e.g.,
  "duplicate webhooks for the same PR+commit are ignored" not "check Redis
  key `review:<repo>:<pr>:<sha>` before proceeding")
- If the task has hard constraints that must not be violated, state them
  explicitly in the objective (e.g., "the concurrency slot must always be
  released, even if the orchestration fails partway through")
- One task, one concern. If the objective has two unrelated goals, split
  the task

**Length target:** 3–8 sentences. If it's longer, the task scope is probably
too big.

## Writing the Suggested Path

The suggested path gives the agent a design direction without mandating
specifics. It's a recommendation, not a contract.

**Rules:**

- Frame as guidance: "One approach is..." / "The natural flow is..." / "You'll
  also need X since later tasks depend on it"
- Give design direction, not implementation instructions. Say "include the
  trigger type in whatever key structure you use" not "use Redis key format
  `review:<repo>:<pr>:<sha>:<trigger>`"
- Name the patterns, not the code. Say "the begin/ensure pattern is critical
  for release" not "wrap in begin; ensure ConcurrencyLimiter.release!; end"
- Mention dependencies on other tasks only when the agent needs to know what
  already exists (e.g., "the Redis wrapper from Task 3 handles all Redis
  operations")
- Warn about specific pitfalls that are non-obvious (e.g., "don't pass
  context as a CLI argument — at 500KB it will hit ARG_MAX limits, write to
  a temp file instead")
- Call out where the agent has flexibility and where it doesn't. If you don't
  care how something is implemented, don't describe how. If a specific
  approach matters, say why it matters
- Optimization tasks should define success as a relative improvement ("reduce
  by 40%") or include a fallback ("under 60s, or document what prevents it").
  Hard absolute targets without escape hatches waste retry budget when the
  target is infeasible
- When writing tasks that add monitoring, logging, or background processes,
  include in the objective: "verify the feature produces visible output in at
  least one real scenario." A background job that exits cleanly but does
  nothing is worse than one that crashes, because it creates false confidence
- When a task involves data flowing between modules (written in one, read in
  another), the objective should name both modules and the data path. A task
  scoped to only one side of the interface will pass tests that mock the other
  side, hiding integration bugs

**What makes a suggested path too prescriptive:**

- Exact file paths and class names
- Exact method signatures
- Exact data formats (key schemas, JSON structures)
- Exact variable names or constants
- Step-by-step implementation sequences that read like pseudocode

**What's appropriately prescriptive:**

- "Use a temp file, not a CLI argument" (specific pitfall with a clear reason)
- "Retry in parallel, not sequentially" (design choice that affects behavior)
- "You'll need list operations on Redis since the review queue uses a list"
  (dependency that would be hard to discover from the objective alone)
- "Use process group kill, not just PID kill, since the CLI spawns child
  processes" (non-obvious operational concern)

**Length target:** 3–6 sentences. If it's a full paragraph of implementation
steps, it's too detailed.

## Writing Tests

Tests validate the objective, not the suggested path. If the agent implements
the objective differently than the suggested path describes, the tests should
still pass.

**Rules:**

- List behavioral scenarios, not implementation checks. Say "same SHA with
  different trigger is allowed" not "verify dedup key includes trigger
  component"
- Name the spec file explicitly so the agent knows where to put tests
- The test list is not exhaustive. List only the non-obvious scenarios that
  encode a design decision or requirement the agent couldn't infer from the
  objective alone. The agent will write basic happy/sad path tests on its own
  — don't waste task description space on those. (Reinforce this convention
  in CLAUDE.md so the agent knows the listed tests are a floor, not a
  ceiling.)
- Don't specify assertions in detail — the scenario description should make
  the expected behavior obvious
- For bug fix tasks, describe the observable bug in the objective, not which
  file to modify. The agent will find the right place to add regression tests

## Task Ordering

- Dependencies flow downward: Task N can use anything from Tasks 1..N-1
- Earlier tasks build foundation; later tasks compose those foundations
- The first 3–5 tasks should establish the core patterns that everything
  else follows. These are the tasks you supervise most closely, because the
  entire codebase inherits their choices
- Group related tasks together, but don't combine them into one task

## Task Scope

Each task should be completable in a single Claude Code session without
context exhaustion. Rules of thumb:

- One service object or one controller or one configuration module per task
- Extending an existing file (adding methods) is fine if the additions are
  cohesive
- If a task description needs more than ~15 sentences across objective +
  suggested path, it's probably too big
- Prompt engineering tasks (writing agent prompts) are legitimate tasks, but
  note that unit tests for prompts are structural checks only — real
  validation happens by running the prompts against actual PRs

## Common Mistakes

**The over-specified task:** The suggested path is so detailed that it's
effectively pseudocode. The agent implements it literally, including parts
that don't make sense in context. The reviewers don't catch it because the
code matches the description. Prevention: if you can predict the exact diff
the agent will produce from your task description, it's too prescriptive.

**The under-specified task:** The objective is vague ("set up the webhook
controller") and the suggested path is empty. The agent makes choices you
didn't expect. Prevention: always include the *why* in the objective, and
mention non-obvious constraints. It's fine to be vague about *how* as long
as you're precise about *what* and *why*.

**The implicit dependency:** Task 12 assumes task 8 implemented something a
certain way, but the task description references the assumption without
stating it. Prevention: if task 12 depends on a specific interface from task
8, the agent should discover that interface by reading the code, not by
reading task 8's description.

**The spec-code drift:** After task 5 executes, the code doesn't match what
task 10's description assumes. The task descriptions reference a design that
no longer exists. Prevention: write objectives about outcomes, not about the
state of the codebase. The agent reads the actual code for that.

---

## Examples

Three example tasks at different levels of the system — a foundation service,
a domain-logic service, and a high-level orchestration task. Each example
includes a note explaining why specific test scenarios were listed and others
were omitted.

### Example: Foundation task

```markdown
## Task 3: Redis Connection

**Objective:**

Set up a Redis connection pool and a thin service wrapper so the rest of the
app has a clean, centralized interface for all Redis operations. The wrapper
should be the only place in the codebase that talks to Redis directly — every
other service goes through it. Tests should use a real Redis connection against
a test-only database.

**Suggested path:**

Use the `redis-client` gem with `connection_pool`. Expose the pool as a
constant from an initializer. The wrapper can be a service object with class
methods for the basics (get, set with TTL, delete, exists, increment,
decrement). You'll also need list operations (push, blocking pop, length)
since the review queue in later tasks uses a Redis list. Keep it simple —
this is a thin pass-through, not an abstraction layer.

**Tests:** `spec/services/redis_store_spec.rb`

- TTL-based expiry works
- List push then pop returns the value
```

Why these tests: basic get/set/delete/exists tests are not listed because the
agent will write those regardless. The listed scenarios highlight the two
things it might miss: TTL behavior and list operations (which are needed by
later tasks but not obvious from the objective).

### Example: Domain-logic task

```markdown
## Task 13: Deduplication Service

**Objective:**

Prevent duplicate reviews for the same PR at the same commit from the same
trigger type. An automatic review (PR opened) should not block a later
@mention re-review on the same commit — engineers @mention specifically to
re-run after failures or prompt changes, so blocking that would undermine
the feature. Failed reviews should be retryable. State lives in Redis with
automatic expiry so there's no unbounded key growth.

**Suggested path:**

A service object with class methods for: checking if a review should proceed,
marking a review as in-progress, marking it complete, and marking it failed
(which allows retry). Include the trigger type in whatever key structure you
use so that automatic and mention-triggered reviews don't collide. Use TTLs
for expiry — something short for in-progress (guards against crashes) and
longer for complete (prevents re-review within a reasonable window).

**Tests:** `spec/services/dedup_spec.rb`

- Same SHA with different trigger is allowed (mention after auto-review)
- Review after failure is allowed (retry)
- Keys expire automatically
```

Why these tests: the agent will naturally test "first review is allowed" and
"duplicate is blocked" — those are the obvious happy/sad paths. The listed
scenarios encode non-obvious design decisions: trigger-based separation,
retry-after-failure semantics, and TTL expiry.

### Example: Orchestration task

```markdown
## Task 21: Orchestrator

**Objective:**

Implement the core coordination logic that runs a single review end-to-end.
Given a repo, PR number, SHA, and trigger, the orchestrator should: fetch
the full PR context, run all 5 review agents in parallel, retry failed
agents with backoff, format the results, and post them to the PR as GitHub
comments. The general review summary always posts. Specialized agent comments
post only when they have findings above the confidence threshold.

The concurrency limiter must always be released, even if the orchestration
fails partway through. If the concurrency limit is reached, the review
should be marked failed so it can be retried later.

**Suggested path:**

A class method that the worker calls with the review parameters. The natural
flow: acquire concurrency slot, build GitHub client, assemble context, spawn
one thread per agent, collect results, retry failures (in parallel, with
backoff — something like 2s then 5s+jitter), format and post, mark complete,
release slot. The begin/ensure pattern is critical for the concurrency
release.

Separate the general result from the specialized results when posting — the
general agent produces the summary comment, and each specialized agent with
findings gets its own comment.

**Tests:** `spec/services/orchestrator_spec.rb`

- Concurrency slot is released even on exception
- General agent failure still produces a summary
- All agents clean → summary only, no agent comments
```

Why these tests: the agent will test the basic flow (agents run, results
post) and retry logic on its own. The listed scenarios encode hard
constraints (ensure release) and non-obvious behavior (general failure still
posts, clean agents produce no extra comments).
