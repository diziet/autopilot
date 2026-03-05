# Getting Started with Autopilot

This guide walks you through installing Autopilot, setting up your first project, and running the pipeline end-to-end.

## Prerequisites

Before installing Autopilot, ensure you have the following tools:

### Required

| Tool | Check | Install |
|------|-------|---------|
| **Claude Code CLI** | `claude --version` | [Anthropic docs](https://docs.anthropic.com/en/docs/claude-code) |
| **GitHub CLI** | `gh --version` | `brew install gh` or [cli.github.com](https://cli.github.com/) |
| **jq** | `jq --version` | `brew install jq` |
| **git** | `git --version` | Pre-installed on macOS/Linux |
| **GNU timeout** | `timeout --version` | See below |

### GNU `timeout` on macOS

macOS does not ship with GNU `timeout`. Install it via Homebrew:

```bash
brew install coreutils
```

This installs `gtimeout` and adds a `timeout` symlink to `/opt/homebrew/bin/` (Apple Silicon) or `/usr/local/bin/` (Intel). Verify it works:

```bash
timeout --version
# Should print: timeout (GNU coreutils) 9.x
```

If `timeout` is not found, ensure Homebrew's bin directory is in your `PATH`:

```bash
# Apple Silicon
export PATH="/opt/homebrew/bin:$PATH"

# Intel Mac
export PATH="/usr/local/bin:$PATH"
```

Add this to your `~/.zshrc` or `~/.bashrc` to make it permanent.

### GitHub CLI Authentication

The GitHub CLI must be authenticated with a repo that has push and PR permissions:

```bash
gh auth login
gh auth status   # Verify: should show "Logged in to github.com"
```

### Optional (Development)

If you plan to run Autopilot's own test suite or contribute:

| Tool | Install |
|------|---------|
| **bats-core** | `brew install bats-core` |
| **ShellCheck** | `brew install shellcheck` |

## Installation

### 1. Clone the Repository

```bash
git clone https://github.com/diziet/autopilot.git ~/.autopilot
```

### 2. Run the Installer

```bash
cd ~/.autopilot
make install
```

This will:
- Check that all required dependencies are present (with install hints for anything missing)
- Symlink `autopilot-dispatch` and `autopilot-review` into `~/.local/bin/`
- Print post-install instructions

To install to a different location:

```bash
PREFIX=/usr/local make install
```

### 3. Add to PATH

Ensure the install directory is in your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add this to your `~/.zshrc` or `~/.bashrc` to make it permanent. Verify:

```bash
which autopilot-dispatch
# Should print: /Users/you/.local/bin/autopilot-dispatch
```

## First Project Walkthrough

Let's set up Autopilot on a sample project with 3 tasks.

### 1. Navigate to Your Project

```bash
cd /path/to/your/project
```

Your project must be a git repository with a GitHub remote:

```bash
git remote -v
# Should show a github.com origin
```

### 2. Create a Task File

Copy the example template:

```bash
cp ~/.autopilot/examples/tasks.example.md tasks.md
```

Edit `tasks.md` with your tasks. Each `## Task N` section becomes one PR:

```markdown
# Project Tasks

## Task 1: Set up project scaffold

Create the initial project structure with README.md, .gitignore, and a basic
directory layout. Add a Makefile with test and lint targets. Include a
trivial passing test.

## Task 2: Add core module

Implement the main module with input validation and error handling.
Write unit tests for all public functions.

## Task 3: Add CLI entry point

Create a CLI that uses the core module. Add --help output
and integration tests.
```

Tips for effective tasks:
- **One task = one PR.** Keep tasks focused and independently mergeable.
- **Build foundations first.** Earlier tasks should establish patterns that later tasks follow.
- **Include acceptance criteria** when the definition of "done" isn't obvious.
- **Keep tasks completable in ~45 minutes** (one agent session).

### 3. Create a Config File

Copy the example config:

```bash
cp ~/.autopilot/examples/autopilot.conf autopilot.conf
```

For unattended (cron) operation, you **must** enable permission skipping:

```bash
# In autopilot.conf, uncomment and set:
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
```

If your project has reference docs the coder should read, add them:

```bash
# In autopilot.conf:
AUTOPILOT_CONTEXT_FILES="docs/spec.md:docs/api-reference.md"
```

### 4. Add `.autopilot/` to `.gitignore`

```bash
echo '.autopilot/' >> .gitignore
git add .gitignore && git commit -m "chore: ignore autopilot state directory"
```

### 5. Test with a Manual Run

Before setting up cron, run the dispatcher once manually to verify everything works:

```bash
autopilot-dispatch /path/to/your/project
```

This will:
- Run preflight checks (dependencies, git status, auth)
- Read the first task from `tasks.md`
- Spawn a coder agent to implement it
- Create a PR when the coder finishes

Watch the log for progress:

```bash
tail -f /path/to/your/project/.autopilot/logs/pipeline.log
```

### 6. Set Up Cron

Once you've verified the pipeline works, add cron jobs for fully autonomous operation. Autopilot uses 15-second ticks for fast state transitions:

```bash
crontab -e
```

Add these lines (replace `/path/to/your/project` with your actual path):

```crontab
# Autopilot PATH — must include tool locations
PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# Dispatcher — drives the state machine
* * * * * autopilot-dispatch /path/to/your/project
* * * * * sleep 15 && autopilot-dispatch /path/to/your/project
* * * * * sleep 30 && autopilot-dispatch /path/to/your/project
* * * * * sleep 45 && autopilot-dispatch /path/to/your/project

# Reviewer — detects pr_open state and runs reviews
* * * * * autopilot-review /path/to/your/project
* * * * * sleep 15 && autopilot-review /path/to/your/project
* * * * * sleep 30 && autopilot-review /path/to/your/project
* * * * * sleep 45 && autopilot-review /path/to/your/project
```

The pipeline will now run autonomously, working through your task list.

## Pausing and Resuming

### Pause the Pipeline

Create a PAUSE file to stop both the dispatcher and reviewer immediately:

```bash
touch /path/to/your/project/.autopilot/PAUSE
```

Both cron jobs check for this file before doing any work and exit silently. No crontab editing needed.

### Resume the Pipeline

Remove the PAUSE file to continue from where the pipeline left off:

```bash
rm /path/to/your/project/.autopilot/PAUSE
```

The next cron tick will pick up the current state and continue.

### Check Current State

View the pipeline's current state:

```bash
cat /path/to/your/project/.autopilot/state.json | jq .
```

View the log:

```bash
tail -50 /path/to/your/project/.autopilot/logs/pipeline.log
```

## Troubleshooting

### "timeout: command not found"

**Cause:** GNU `timeout` is not installed or not in PATH.

**Fix (macOS):**
```bash
brew install coreutils
```

Then ensure `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel) is in your PATH. For cron, add a `PATH=` line at the top of your crontab.

### "claude: command not found"

**Cause:** Claude Code CLI is not installed or not in the cron PATH.

**Fix:** Install Claude Code CLI following [Anthropic's docs](https://docs.anthropic.com/en/docs/claude-code), then verify:
```bash
which claude
claude --version
```

Add its directory to the `PATH=` line in your crontab.

### "CRITICAL: Non-interactive without --dangerously-skip-permissions"

**Cause:** The dispatcher detected it's running from cron (no TTY) but `AUTOPILOT_CLAUDE_FLAGS` doesn't include `--dangerously-skip-permissions`.

**Fix:** Add to your `autopilot.conf`:
```bash
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
```

This is required for unattended operation. Without it, Claude would hang waiting for interactive permission approval.

### Pipeline Appears Stuck

**Symptoms:** No state changes for a long time, no new log entries.

**Check for stale locks:**
```bash
ls -la /path/to/your/project/.autopilot/locks/
cat /path/to/your/project/.autopilot/locks/pipeline.lock
# Shows the PID of the process holding the lock
```

If the process is dead, remove the lock:
```bash
rm /path/to/your/project/.autopilot/locks/pipeline.lock
```

Autopilot auto-cleans locks older than 45 minutes (configurable via `AUTOPILOT_STALE_LOCK_MINUTES`), but you can remove them manually if needed.

### Task Keeps Retrying

**Symptoms:** The same task has been retried multiple times.

**Check the retry count:**
```bash
cat /path/to/your/project/.autopilot/state.json | jq '.retry_count'
```

After `AUTOPILOT_MAX_RETRIES` (default: 5) failures, Autopilot runs a diagnosis agent and writes findings to `.autopilot/diagnosis-task-N.md`. Read the diagnosis for hints:

```bash
cat /path/to/your/project/.autopilot/diagnosis-task-*.md
```

Common causes: task is too large or ambiguous, test suite has flaky tests, missing dependencies.

### Cron Jobs Not Running

**Verify cron is active:**
```bash
crontab -l    # List current cron jobs
```

**Check cron logs (macOS):**
```bash
log show --predicate 'process == "cron"' --last 1h
```

**Common issues:**
- Missing `PATH=` line in crontab — cron has a minimal PATH by default
- Wrong project path — use absolute paths, not `~` or `$HOME`
- Permissions — ensure the entry point scripts are executable (`chmod +x`)

### Tests Fail but Code Looks Correct

**Check the test output in the PR comments.** Autopilot posts the last 80 lines of test output (configurable via `AUTOPILOT_TEST_OUTPUT_TAIL`) when tests fail.

**Check if the test command is correct:**
```bash
# See what Autopilot auto-detected:
grep "test_cmd" /path/to/your/project/.autopilot/logs/pipeline.log
```

Override auto-detection by setting `AUTOPILOT_TEST_CMD` in your config:
```bash
AUTOPILOT_TEST_CMD="make test"
```

### Review Comments Are Not Being Posted

**Check reviewer configuration:**
```bash
grep AUTOPILOT_REVIEWERS /path/to/your/project/autopilot.conf
```

**Check diff size.** Very large diffs (over 500 KB) are skipped. Adjust with:
```bash
AUTOPILOT_MAX_DIFF_BYTES=1000000
```

## Next Steps

- **[examples/autopilot.conf](../examples/autopilot.conf)** — Full configuration reference with all options
- **[examples/tasks.example.md](../examples/tasks.example.md)** — Task file template with writing tips
