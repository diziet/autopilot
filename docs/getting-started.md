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

For unattended operation (launchd or cron), you **must** enable permission skipping:

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

Before setting up automatic scheduling, run the dispatcher once manually to verify everything works:

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

### 6. Schedule the Pipeline

Once you've verified the pipeline works, set up automatic scheduling for fully autonomous operation.

#### Option A: launchd (Recommended on macOS)

Use `autopilot-schedule` to generate and install launchd agents:

```bash
autopilot-schedule /path/to/your/project
```

This installs two launchd agents (dispatcher + reviewer) that run every 15 seconds. Customize the interval or account:

```bash
autopilot-schedule --interval 30 --account 2 /path/to/your/project
```

Check agent status:

```bash
launchctl list | grep autopilot
```

View logs:

```bash
tail -f /path/to/your/project/.autopilot/logs/dispatcher.stdout.log
```

To remove:

```bash
autopilot-schedule --uninstall /path/to/your/project
```

#### Claude Binary Location

launchd agents do **not** inherit your shell `PATH` from `~/.zshrc` or `~/.bashrc`. If `claude` is installed in a non-standard location (e.g., `~/.local/bin/claude` or a Homebrew prefix), launchd won't find it — resulting in exit code 127 ("command not found").

**Solution A: Re-run `autopilot-schedule` (recommended)**

`autopilot-schedule` auto-detects the location of `claude` at install time and embeds the correct directory in the generated plist's `PATH`. Simply re-running it picks up any new install location:

```bash
autopilot-schedule --uninstall /path/to/your/project
autopilot-schedule /path/to/your/project
```

**Solution B: Set `AUTOPILOT_CLAUDE_CMD` to an absolute path**

If auto-detection doesn't work (e.g., `claude` is not on your current shell PATH either), set the full path explicitly in `autopilot.conf`:

```bash
# In autopilot.conf — use the absolute path to the claude binary
AUTOPILOT_CLAUDE_CMD="/Users/you/.local/bin/claude"
```

Find your claude location with:

```bash
which claude
# Example output: /Users/you/.local/bin/claude
```

#### Option B: Cron

If you prefer cron, use 15-second ticks with sleep offsets:

```bash
crontab -e
```

Add these lines (replace `/path/to/your/project` with your actual path):

```crontab
PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

* * * * * autopilot-dispatch /path/to/your/project
* * * * * sleep 15 && autopilot-dispatch /path/to/your/project
* * * * * sleep 30 && autopilot-dispatch /path/to/your/project
* * * * * sleep 45 && autopilot-dispatch /path/to/your/project

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

Both the dispatcher and reviewer check for this file before doing any work and exit silently. No schedule editing needed.

### Resume the Pipeline

Remove the PAUSE file to continue from where the pipeline left off:

```bash
rm /path/to/your/project/.autopilot/PAUSE
```

The next scheduler tick will pick up the current state and continue.

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

After `AUTOPILOT_MAX_RETRIES` (default: 5) failures, Autopilot runs a diagnosis agent and writes findings to `.autopilot/logs/diagnosis-task-N.md`. Read the diagnosis for hints:

```bash
cat /path/to/your/project/.autopilot/logs/diagnosis-task-*.md
```

Common causes: task is too large or ambiguous, test suite has flaky tests, missing dependencies.

### Scheduled Jobs Not Running

**If using launchd:**
```bash
# Check agent status
launchctl list | grep autopilot

# View stderr for errors
cat /path/to/your/project/.autopilot/logs/dispatcher.stderr.log

# Reload agents
autopilot-schedule --uninstall /path/to/your/project
autopilot-schedule /path/to/your/project
```

**If using cron:**
```bash
crontab -l    # List current cron jobs
log show --predicate 'process == "cron"' --last 1h  # Check cron logs (macOS)
```

**Common issues:**
- Missing `PATH` — launchd plists include PATH automatically; for cron, add a `PATH=` line
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

## Multi-Account Setup

Autopilot works best with two separate Claude Code accounts. The dispatcher (which spawns coder and fixer agents) runs on one account, while the reviewer runs on a second account. Because these agents often run concurrently — the reviewer analyzing a PR while the coder implements the next task — separate accounts avoid API rate-limit contention and keep billing distinct.

### Why Two Accounts?

| Agent | Account | Runs When |
|-------|---------|-----------|
| Coder, Fixer, Test Fixer | Account 1 | Implementing or fixing a task |
| Reviewer, Merger | Account 2 | Reviewing or merging a PR |

Without separate accounts, a long coder session can exhaust rate limits right when the reviewer needs to post comments — or vice versa. Two accounts eliminate this contention entirely.

### How `CLAUDE_CONFIG_DIR` Works

Each Claude Code account has its own config directory (typically `~/.claude-account1/` and `~/.claude-account2/`). Each directory contains:

- `settings.json` — Claude Code settings and preferences
- API credentials and session state
- Account-specific configuration

When Autopilot spawns a Claude agent, it sets the `CLAUDE_CONFIG_DIR` environment variable to point to the appropriate account's directory. This tells Claude Code which credentials and settings to use.

### Setting Up Two Accounts

1. **Create config directories** for each account:

```bash
mkdir -p ~/.claude-account1 ~/.claude-account2
```

2. **Initialize each account** by running Claude once with each config directory:

```bash
CLAUDE_CONFIG_DIR=~/.claude-account1 claude --version
CLAUDE_CONFIG_DIR=~/.claude-account2 claude --version
```

3. **Authenticate** each account (if using different API keys):

```bash
CLAUDE_CONFIG_DIR=~/.claude-account1 claude
# Complete login/setup for account 1

CLAUDE_CONFIG_DIR=~/.claude-account2 claude
# Complete login/setup for account 2
```

### How `autopilot-schedule` Assigns Accounts

The `autopilot-schedule` script assigns accounts to launchd agents. When you specify an account number, it checks whether `~/.claude-account{N}/` exists and, if so, injects `CLAUDE_CONFIG_DIR` into the generated plist's environment variables.

**Single account for both roles (default):**

```bash
autopilot-schedule /path/to/project
# Both dispatcher and reviewer use account 1
```

**Same account, different number:**

```bash
autopilot-schedule --account 2 /path/to/project
# Both dispatcher and reviewer use account 2
```

**Separate accounts per role (recommended):**

```bash
autopilot-schedule --dispatcher-account 1 --reviewer-account 2 /path/to/project
# Dispatcher (coder/fixer) uses account 1
# Reviewer (reviewer/merger) uses account 2
```

Each generated launchd plist includes a `CLAUDE_CONFIG_DIR` environment variable pointing to the resolved account directory (e.g., `/Users/you/.claude-account2`). The entry point scripts (`autopilot-dispatch`, `autopilot-review`) inherit this from the launchd environment — they do not take an account number as a command-line argument.

### Config File Alternative

Instead of (or in addition to) the launchd account mechanism, you can set account directories directly in `autopilot.conf`:

```bash
AUTOPILOT_CODER_CONFIG_DIR="/Users/you/.claude-account1"
AUTOPILOT_REVIEWER_CONFIG_DIR="/Users/you/.claude-account2"
```

These config variables are used by the agent-spawning code regardless of how the pipeline was launched (launchd, cron, or manual). See [Configuration Reference — Account Setup](configuration.md#account-setup) for details.

## Next Steps

- **[Configuration Reference](configuration.md)** — All `AUTOPILOT_*` variables, account setup, permission model
- **[Task File Format](task-format.md)** — Both heading formats, context files, writing tips
- **[examples/autopilot.conf](../examples/autopilot.conf)** — Example config with all options documented
- **[examples/tasks.example.md](../examples/tasks.example.md)** — Starter task file template
