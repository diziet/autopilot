# Getting Started with Autopilot

This guide covers installing Autopilot, setting up a first project, and running the pipeline end to end.

## Prerequisites

Install these tools before you install Autopilot:

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

If the shell cannot find `timeout`, add Homebrew's bin directory to your `PATH`:

```bash
# Apple Silicon
export PATH="/opt/homebrew/bin:$PATH"

# Intel Mac
export PATH="/usr/local/bin:$PATH"
```

Add the line for your Mac to `~/.zshrc` or `~/.bashrc` so that new shells have it.

### GitHub CLI Authentication

Authenticate the GitHub CLI with an account that can push to the repo and open PRs on it:

```bash
gh auth login
gh auth status   # Verify: should show "Logged in to github.com"
```

### Optional (Development)

These tools are needed only to run Autopilot's own test suite or to contribute:

| Tool | Install |
|------|---------|
| **bats-core** | `brew install bats-core` |
| **GNU parallel** | `brew install parallel` |
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

The installer:
- Checks that every required dependency is present, and prints an install hint for each missing one
- Symlinks all `autopilot-*` binaries (`autopilot-dispatch`, `autopilot-review`, `autopilot-schedule`, `autopilot-status`, `autopilot-init`, `autopilot-doctor`, `autopilot-start`) into `~/.local/bin/`
- Prints post-install instructions

To install to a different location:

```bash
PREFIX=/usr/local make install
```

### 3. Add to PATH

Add the install directory to your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add the same line to `~/.zshrc` or `~/.bashrc` so that new shells have it. Then check:

```bash
which autopilot-dispatch
# Should print: /Users/you/.local/bin/autopilot-dispatch
```

## First Project Walkthrough

This walkthrough sets up Autopilot on a sample project with 3 tasks.

### Option A: Interactive Setup with `autopilot-init`

This is the fastest way to set up a project. Run `autopilot-init` from your project directory:

```bash
cd /path/to/your/project
autopilot-init
```

`autopilot-init` runs these steps interactively:

1. **Prerequisites** — checks that `claude`, `gh`, `jq`, `git`, and `timeout` are installed
2. **Git repo** — initializes a git repo if needed; creates a GitHub remote if missing
3. **GitHub auth** — verifies `gh auth status`
4. **tasks.md** — scaffolds a sample task file with two example tasks
5. **autopilot.conf** — generates config with `--dangerously-skip-permissions` and optional test command
6. **CLAUDE.md** — scaffolds a default `CLAUDE.md` from a template (skipped if one with more than 10 lines already exists)
7. **.gitignore** — creates the file or appends the `.autopilot/` entry
8. **Account detection** — identifies `~/.claude-account1` and `~/.claude-account2` if present
9. **Scheduling** — installs launchd agents (macOS) or prints cron instructions (Linux)
10. **PAUSE file** — creates `.autopilot/PAUSE` so the pipeline starts in a paused state

After init completes, edit `tasks.md` with your actual tasks, then validate and start:

```bash
autopilot-doctor              # Validate setup (non-interactive)
autopilot-start               # Remove PAUSE file and begin
```

To verify the pipeline works end-to-end before scheduling, run the dispatcher once manually and watch the log:

```bash
autopilot-dispatch /path/to/your/project
tail -f .autopilot/logs/pipeline.log
```

`autopilot-init` skips files that already exist, so you can run it again.

### Option B: Manual Setup

#### 1. Navigate to Your Project

```bash
cd /path/to/your/project
```

Your project must be a git repository with a GitHub remote:

```bash
git remote -v
# Should show a github.com origin
```

#### 2. Create a Task File

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

Guidelines for tasks:
- **One task = one PR.** Keep each task focused and mergeable on its own.
- **Build foundations first.** Earlier tasks should establish patterns that later tasks follow.
- **Include acceptance criteria** when the definition of "done" isn't obvious.
- **Keep tasks completable in ~45 minutes** (one agent session).

#### 3. Create a Config File

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

#### 4. Add `.autopilot/` to `.gitignore`

```bash
echo '.autopilot/' >> .gitignore
git add .gitignore && git commit -m "chore: ignore autopilot state directory"
```

#### 5. Validate Setup with `autopilot-doctor`

Run the doctor command to check the setup:

```bash
autopilot-doctor /path/to/your/project
```

Doctor runs 11 non-interactive checks:
- Prerequisites on PATH (claude, gh, jq, git, timeout)
- GitHub CLI authentication
- Config file parsing
- Tasks file detection (warns if more than one file matches)
- `.gitignore` contains `.autopilot/`
- GitHub remote reachable
- `--dangerously-skip-permissions` in `AUTOPILOT_CLAUDE_FLAGS`
- Worktree symlink compatibility (warns if symlinks escape the repo root)
- Codex reviewer setup (if `codex` is in the reviewer list)
- Account directory detection (single vs multi-account)
- Claude API smoke test (verifies connectivity for each account)

Fix any reported issues before proceeding.

#### 6. Start the Pipeline

Use `autopilot-start` to validate and start in one step:

```bash
autopilot-start /path/to/your/project
```

This runs `autopilot-doctor` first, then removes the `.autopilot/PAUSE` file if all checks pass. Running it again is safe: it exits cleanly if the pipeline is already running.

> **Tip:** Before setting up scheduling, verify the pipeline works end-to-end by running the dispatcher once manually:
>
> ```bash
> autopilot-dispatch /path/to/your/project
> ```
>
> This picks up the first task, spawns a coder agent, runs tests, and creates a PR. Watch the log to confirm it completes successfully:

```bash
tail -f /path/to/your/project/.autopilot/logs/pipeline.log
```

### Schedule the Pipeline

Once the manual run works, set up scheduling so that the pipeline runs unattended.

#### Option A: launchd (Recommended on macOS)

Use `autopilot-schedule` to generate and install launchd agents:

```bash
autopilot-schedule /path/to/your/project
```

This installs two launchd agents, one for the dispatcher and one for the reviewer, that run every 15 seconds. To change the interval or the account:

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

To remove the agents:

```bash
autopilot-schedule --uninstall /path/to/your/project
```

#### Claude Binary Location

launchd agents do **not** inherit your shell `PATH` from `~/.zshrc` or `~/.bashrc`. If `claude` is installed in a non-standard location (e.g., `~/.local/bin/claude` or a Homebrew prefix), launchd cannot find it, and the job exits with code 127 ("command not found").

**Solution A: Re-run `autopilot-schedule` (recommended)**

`autopilot-schedule` detects the location of `claude` at install time and adds that directory to the generated plist's `PATH`. Re-running it records the new location:

```bash
autopilot-schedule --uninstall /path/to/your/project
autopilot-schedule /path/to/your/project
```

**Solution B: Set `AUTOPILOT_CLAUDE_CMD` to an absolute path**

If detection fails (e.g., `claude` is not on your current shell PATH either), set the full path in `autopilot.conf`:

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

> **Not recommended on macOS.** Three macOS-specific issues make cron unreliable:
> 1. **EINTR on crontab writes** — `crontab -e` and piped writes fail with "Interrupted system call" (EINTR). macOS cron doesn't retry on EINTR the way Linux cron does (`SA_RESTART`). Reading (`crontab -l`) works, but writes to `/var/at/tmp/` are interrupted by signals. The failure is intermittent and hard to debug.
> 2. **Full Disk Access** — even when writes succeed, `crontab -e` silently reverts edits unless your terminal app (iTerm2, Terminal.app) has Full Disk Access granted in System Settings → Privacy & Security → Full Disk Access. SSH and tmux sessions are also affected.
> 3. **SIP environment restrictions** — cron jobs cannot access user-installed binaries, Homebrew paths, or keychain credentials without explicit `PATH=` workarounds.
>
> Use launchd (Option A) instead. Cron is documented here for Linux and other systems without launchd.

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

The scheduled jobs now work through your task list.

## Pausing and Resuming

### Pause the Pipeline

Create a PAUSE file to stop the pipeline. The file's content selects one of two modes:

```bash
# Hard pause — stop immediately on next tick
echo "reason" > /path/to/your/project/.autopilot/PAUSE

# Soft pause — finish current phase, then stop
touch /path/to/your/project/.autopilot/PAUSE
```

- **Hard pause** (non-empty file): Both the dispatcher and reviewer exit immediately on the next tick.
- **Soft pause** (empty file): The current phase (e.g., a coder run) finishes, and the pipeline stops before it starts the next phase.

You do not need to edit the schedule: each tick checks the PAUSE file before it does any work.

### Resume the Pipeline

Use `autopilot-start` to validate setup and resume:

```bash
autopilot-start /path/to/your/project
```

Or remove the PAUSE file by hand; the pipeline continues from where it stopped:

```bash
rm /path/to/your/project/.autopilot/PAUSE
```

The next tick reads the saved state and continues from it.

### Check Current State

Use the status checker for an overview:

```bash
autopilot-status /path/to/your/project
```

Or view raw state and logs directly:

```bash
cat /path/to/your/project/.autopilot/state.json | jq .
tail -50 /path/to/your/project/.autopilot/logs/pipeline.log
```

## Verifying Your Setup

After `autopilot doctor` passes, run the **live test** to check the whole pipeline end to end:

```bash
autopilot live-test run
```

This creates a throwaway Python project with 6 trivial tasks and runs the full Autopilot pipeline (dispatch, review, fix, merge) on it with Claude Haiku. It checks that:

- Claude Code can implement tasks and create PRs
- Reviewers run and post comments
- The fixer addresses feedback
- PRs merge successfully

**Cost:** ~$0.05 (Haiku pricing).
**Runtime:** ~30 minutes target, 60 minutes maximum.

The live test uses its own config overrides (see `examples/live-test-autopilot.conf`) so it won't interfere with your project's settings.

To also create a real GitHub repository for the test (verifies `gh` push and PR operations):

```bash
autopilot live-test run --github
```

Check results at any time:

```bash
autopilot live-test status
```

The last result also appears in `autopilot doctor` and `autopilot-status` output.

## Troubleshooting

### "timeout: command not found"

**Cause:** GNU `timeout` is not installed or not in PATH.

**Fix (macOS):**
```bash
brew install coreutils
```

Then add `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel) to your PATH. For cron, add a `PATH=` line at the top of your crontab.

### "claude: command not found"

**Cause:** Claude Code CLI is not installed or not in the cron PATH.

**Fix:** Install Claude Code CLI following [Anthropic's docs](https://docs.anthropic.com/en/docs/claude-code), then verify:
```bash
which claude
claude --version
```

Add its directory to the `PATH=` line in your crontab.

### "CRITICAL: Non-interactive without --dangerously-skip-permissions"

**Cause:** The dispatcher detected that it is running from cron (no TTY), and `AUTOPILOT_CLAUDE_FLAGS` does not include `--dangerously-skip-permissions`.

**Fix:** Add to your `autopilot.conf`:
```bash
AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
```

Unattended runs require this flag. Without it, Claude hangs while it waits for interactive permission approval.

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

Autopilot removes stale locks itself. A lock is stale if the owning process is dead or the lock file is older than `AUTOPILOT_STALE_LOCK_MINUTES`. By default, that threshold is the longest agent timeout plus 5 minutes (typically ~50 minutes). An explicit value in the config overrides it.

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

Common causes: the task is too large or ambiguous, the test suite has flaky tests, or a dependency is missing.

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
- Permissions — make the entry point scripts executable (`chmod +x`)

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

**Check the diff size.** For a diff over <!-- fact:max-diff-kb -->500<!-- /fact --> KB, only the diff-reduction reviewer runs, on the list of changed files and the first <!-- fact:diff-sample-bytes -->200,000<!-- /fact --> bytes of the diff. The configured reviewers do not run. To change the limit:
```bash
AUTOPILOT_MAX_DIFF_BYTES=1000000
```

## Worktree Isolation

By default (`AUTOPILOT_USE_WORKTREES=true`), each task runs in its own git worktree at `.autopilot/worktrees/task-N/`. This means:

- **Your working tree stays clean** — Autopilot never touches your checked-out branch
- **You can keep working** while the pipeline runs in the background
- **Agent crashes can't leave your tree dirty** — each worktree is isolated

After creating a worktree, Autopilot auto-detects and installs project dependencies. See [configuration.md — Worktree Dependency Installation](configuration.md#worktree-dependency-installation) for supported ecosystems. For projects with custom build steps, set `AUTOPILOT_WORKTREE_SETUP_CMD`:

```bash
# In autopilot.conf
AUTOPILOT_WORKTREE_SETUP_CMD="make setup"
```

### When to Disable Worktrees

Set `AUTOPILOT_USE_WORKTREES=false` if your project uses:
- Relative symlinks that point outside the repository
- Git submodules with relative paths
- Other setups incompatible with `git worktree`

`autopilot-init` detects escaping symlinks and auto-disables worktrees. See [architecture.md — Symlink Safety](architecture.md#symlink-safety) for the full detection mechanism.

---

## Multi-Account Setup

Autopilot works best with two separate Claude Code accounts. The dispatcher, which spawns the coder and fixer agents, runs on one account. The reviewer runs on a second account. These agents often run at the same time: the reviewer analyzes a PR while the coder implements the next task. Separate accounts keep them from competing for one API rate limit, and keep their billing apart.

### Why Two Accounts?

| Agent | Account | Runs When |
|-------|---------|-----------|
| Coder, Fixer, Test Fixer | Account 1 | Implementing or fixing a task |
| Reviewer, Merger | Account 2 | Reviewing or merging a PR |

With one account, a long coder session can use up the rate limit right when the reviewer needs to post comments, or the reverse. Two accounts remove this contention.

### How `CLAUDE_CONFIG_DIR` Works

Each Claude Code account has its own config directory (typically `~/.claude-account1/` and `~/.claude-account2/`). Each directory contains:

- `settings.json` — Claude Code settings and preferences
- API credentials and session state
- Account-specific configuration

When Autopilot spawns a Claude agent, it sets the `CLAUDE_CONFIG_DIR` environment variable to that agent's account directory. Claude Code reads its credentials and settings from that directory.

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

The `autopilot-schedule` script assigns accounts to launchd agents. When you specify an account number, it checks whether `~/.claude-account{N}/` exists and, if so, adds `CLAUDE_CONFIG_DIR` to the generated plist's environment variables.

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

Each generated launchd plist sets a `CLAUDE_CONFIG_DIR` environment variable to the resolved account directory (e.g., `/Users/you/.claude-account2`). The entry point scripts (`autopilot-dispatch`, `autopilot-review`) inherit it from the launchd environment. They do not take an account number as a command-line argument.

### Config File Alternative

Instead of the launchd account setting, or as well as it, you can set the account directories in `autopilot.conf`:

```bash
AUTOPILOT_CODER_CONFIG_DIR="/Users/you/.claude-account1"
AUTOPILOT_REVIEWER_CONFIG_DIR="/Users/you/.claude-account2"
```

The code that spawns agents reads these variables however the pipeline was started (launchd, cron, or manual). See [Configuration Reference — Account Setup](configuration.md#account-setup) for details.

## Next Steps

- **[Configuration Reference](configuration.md)** — All `AUTOPILOT_*` variables, account setup, permission model
- **[Task File Format](task-format.md)** — Both heading formats, context files, writing tips
- **[examples/autopilot.conf](../examples/autopilot.conf)** — Example config with all options documented
- **[examples/tasks.example.md](../examples/tasks.example.md)** — Starter task file template
