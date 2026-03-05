# Autopilot

Autonomous PR pipeline that works through a project's task list using Claude Code agents. One agent implements, another reviews, and PRs are merged automatically when quality gates pass.

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [GitHub CLI](https://cli.github.com/) (`gh`)
- [jq](https://jqlang.github.io/jq/) (`jq`)
- [bats-core](https://github.com/bats-core/bats-core) (testing)
- [ShellCheck](https://www.shellcheck.net/) (linting)
- GNU `timeout` (macOS: `brew install coreutils`)

## Install

```bash
git clone https://github.com/diziet/autopilot.git ~/.autopilot
cd ~/.autopilot && make install
```

## Run

```bash
cd /path/to/your/project
autopilot-dispatch /path/to/project
```

See `docs/getting-started.md` for full setup instructions.

## Test

```bash
make test    # Run bats test suite
make lint    # Run shellcheck on all .sh files
```
