# Autopilot task runner. `make help` lists every target with its role.
#
# The product in bin/ and lib/ is pure bash. The repo tooling in scripts/*.py uses python3 from the
# system (standard library only) and gh.
#
# TODO: the repo pins no tool versions (bash, bats, parallel, jq, shellcheck, python3, git, gh), so
# `make doctor` checks presence only. Add pins here and check them in scripts/doctor.sh in a
# reviewed change.

SHELL := /bin/bash
PREFIX ?= $(HOME)/.local
.DEFAULT_GOAL := check

PY := python3
# Machine-wide gate lock: gates in concurrent worktrees queue instead of competing for cores.
LOCKED := $(PY) scripts/gate_lock.py --
# Tools the gate needs, as <command>:<brew formula> pairs. doctor checks them; install-dev installs
# the missing ones.
DEV_TOOLS := bash:bash bats:bats-core parallel:parallel jq:jq shellcheck:shellcheck python3:python git:git gh:gh
# `make test-tooling t=<module>` runs one tooling test module, for example t=test_merge.
t ?=
# `make branches-gc args="--delete"`.
args ?=

# Shell files to lint: bin/ and lib/, plus the repo tooling in scripts/ and .githooks/.
SH_FILES := $(wildcard bin/*.sh lib/*.sh scripts/*.sh .githooks/*)
# Entry points in bin/ have no .sh extension.
BIN_FILES := $(wildcard bin/autopilot-*)

.PHONY: help check test lint install install-launchd uninstall-launchd check-deps live-test live-test-github \
        install-dev doctor hooks-install test-tooling gate gate-wiring-check worktree sync merge branches-gc

help: ## Advisory: list the targets and their roles, parsed from the double-hash comment on each rule
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

check: ## Blocking gate (run by gate): lint and test in parallel; fails if either fails
	@make lint & lint_pid=$$!; make test & test_pid=$$!; \
	wait $$lint_pid; lint_rc=$$?; wait $$test_pid; test_rc=$$?; \
	if [ $$lint_rc -ne 0 ] || [ $$test_rc -ne 0 ]; then exit 1; fi

BATS_CMD = bats --jobs $${AUTOPILOT_TEST_JOBS:-20} --no-parallelize-within-files tests/
# On macOS, the test temp files go on a 1 GB RAM disk, which reduces I/O contention under parallel
# load. If the RAM disk cannot be created, the suite uses the regular disk. 1 GB is about 10 times
# the observed peak usage of about 80 MB, which leaves room for the suite to grow.
test: ## Blocking gate (run by check): the bats suite, 20 parallel jobs unless AUTOPILOT_TEST_JOBS is set
	@command -v bats >/dev/null 2>&1 || { echo "Error: bats not found. Install with: brew install bats-core"; exit 1; }
	@command -v parallel >/dev/null 2>&1 || { echo "Error: parallel not found (required by bats --jobs). Install with: brew install parallel"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "Error: jq not found. Install with: brew install jq"; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "Error: git not found. Install Xcode CLI tools: xcode-select --install"; exit 1; }
	@cat tests/*.bats tests/helpers/*.bash lib/*.sh > /dev/null 2>&1 || true
	@. "$(CURDIR)/lib/ramdisk.sh"; \
	_result=""; \
	_result=$$(create_ramdisk) || true; \
	_dev=$$(echo "$$_result" | awk '{print $$1}'); \
	_mount=$$(echo "$$_result" | awk '{print $$2}'); \
	if [ -n "$$_mount" ] && [ -d "$$_mount" ]; then \
		TMPDIR="$$_mount" $(BATS_CMD); \
		_rc=$$?; detach_ramdisk "$$_dev"; exit $$_rc; \
	else \
		if [ "$$(uname)" = "Darwin" ] && [ -z "$$_result" ]; then \
			echo "Warning: RAM disk setup failed, falling back to disk" >&2; \
		fi; \
		$(BATS_CMD); \
	fi

# shellcheck runs once per file, 6 files at a time. One invocation for all files triggers
# exponential cross-file analysis: over 12 min and 2.5 GB of RAM for 41 files.
lint: ## Blocking gate (run by check): shellcheck on the shell files in bin/, lib/, scripts/ and .githooks/
	@command -v shellcheck >/dev/null 2>&1 || { echo "Error: shellcheck not found. Install with: brew install shellcheck"; exit 1; }
	@files=""; \
	for f in $(SH_FILES) $(BIN_FILES); do \
		[ -f "$$f" ] && files="$$files $$f"; \
	done; \
	if [ -n "$$files" ]; then \
		printf '%s\n' $$files | xargs -P6 -n1 shellcheck; \
	else \
		echo "No shell files to lint."; \
	fi

# scripts/check-deps.sh reads the dependency list and install hints from lib/preflight.sh.
check-deps: ## Sanctioned path for checking the product's runtime dependencies; exits non-zero when one is missing
	@$(SHELL) "$(CURDIR)/scripts/check-deps.sh"

live-test: ## Advisory, run by hand: the live test suite on this machine; creates no GitHub repo
	"$(CURDIR)/bin/autopilot-live-test" run

live-test-github: ## Advisory, run by hand: the live test suite with a new GitHub repo
	"$(CURDIR)/bin/autopilot-live-test" run --github

install: check-deps ## Sanctioned path for installing the product: link every bin/autopilot-* into PREFIX/bin (default ~/.local/bin)
	@mkdir -p "$(PREFIX)/bin"
	@count=0; \
	for f in bin/autopilot-*; do \
		[ -f "$$f" ] || continue; \
		[ "$$(basename $$f)" = "autopilot-*" ] && continue; \
		chmod +x "$$f"; \
		ln -sf "$(CURDIR)/$$f" "$(PREFIX)/bin/$$(basename $$f)"; \
		echo "  Linked $$f → $(PREFIX)/bin/$$(basename $$f)"; \
		count=$$((count + 1)); \
	done; \
	if [ "$$count" -eq 0 ]; then \
		echo "No autopilot binaries found in bin/ — nothing to install."; \
		exit 1; \
	fi
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  Autopilot installed successfully!"
	@echo "════════════════════════════════════════════════════════════"
	@echo ""
	@echo "Next steps:"
	@echo ""
	@echo "  1. Ensure $(PREFIX)/bin is in your PATH:"
	@echo "     export PATH=\"$(PREFIX)/bin:\$$PATH\""
	@echo ""
	@echo "  2. Set up a project:"
	@echo "     cd /path/to/your/project"
	@echo "     cp $(CURDIR)/examples/autopilot.conf autopilot.conf"
	@echo "     cp $(CURDIR)/examples/tasks.example.md tasks.md"
	@echo "     echo '.autopilot/' >> .gitignore"
	@echo ""
	@echo "  3. Configure for unattended use (required for cron):"
	@echo "     Edit autopilot.conf and set:"
	@echo "     AUTOPILOT_CLAUDE_FLAGS=\"--dangerously-skip-permissions\""
	@echo ""
	@echo "  4. Validate your setup:"
	@echo "     autopilot-doctor /path/to/project"
	@echo ""
	@echo "  5. Schedule with launchd (recommended on macOS):"
	@echo "     autopilot-schedule /path/to/project"
	@echo ""
	@echo "     Or use make install-launchd:"
	@echo "     make install-launchd PROJECT=/path/to/project"
	@echo ""
	@echo "  For more info: $(CURDIR)/README.md"
	@echo ""

DISPATCHER_ACCOUNT ?= 1
REVIEWER_ACCOUNT ?= 1
INTERVAL ?= 15
# Usage: make install-launchd PROJECT=/path/to/project [DISPATCHER_ACCOUNT=1] [REVIEWER_ACCOUNT=1] [INTERVAL=15]
install-launchd: ## Sanctioned path for scheduling a project on macOS: install its launchd plists; needs PROJECT=
	@if [ -z "$(PROJECT)" ]; then \
		echo "Error: PROJECT is required."; \
		echo "Usage: make install-launchd PROJECT=/path/to/project [DISPATCHER_ACCOUNT=1] [REVIEWER_ACCOUNT=1] [INTERVAL=15]"; \
		exit 1; \
	fi
	@chmod +x "$(CURDIR)/bin/autopilot-schedule"
	"$(CURDIR)/bin/autopilot-schedule" --interval "$(INTERVAL)" --dispatcher-account "$(DISPATCHER_ACCOUNT)" --reviewer-account "$(REVIEWER_ACCOUNT)" "$(PROJECT)"

# Usage: make uninstall-launchd PROJECT=/path/to/project [DISPATCHER_ACCOUNT=1] [REVIEWER_ACCOUNT=1]
uninstall-launchd: ## Sanctioned path for unscheduling a project on macOS: remove its launchd plists; needs PROJECT=
	@if [ -z "$(PROJECT)" ]; then \
		echo "Error: PROJECT is required."; \
		echo "Usage: make uninstall-launchd PROJECT=/path/to/project [DISPATCHER_ACCOUNT=1] [REVIEWER_ACCOUNT=1]"; \
		exit 1; \
	fi
	@chmod +x "$(CURDIR)/bin/autopilot-schedule"
	"$(CURDIR)/bin/autopilot-schedule" --uninstall --dispatcher-account "$(DISPATCHER_ACCOUNT)" --reviewer-account "$(REVIEWER_ACCOUNT)" "$(PROJECT)"

# ---- Dev setup and preflight ----------------------------------------------------------------
install-dev: ## Sanctioned path for one-time dev setup: brew-install missing gate tools (never upgrades), hooks, then doctor. `install` installs the product
	@for pair in $(DEV_TOOLS); do \
		cmd="$${pair%%:*}"; formula="$${pair#*:}"; \
		command -v "$$cmd" >/dev/null 2>&1 || HOMEBREW_NO_INSTALL_UPGRADE=1 brew install "$$formula" || exit 1; \
	done
	@$(MAKE) -s hooks-install doctor

doctor: ## Advisory preflight (seconds, no build, no side effects): gate tools on PATH, hooks installed
	@DEV_TOOLS="$(DEV_TOOLS)" bash scripts/doctor.sh

hooks-install: ## Sanctioned path for pointing core.hooksPath at .githooks (shared by every worktree of this repo)
	git config core.hooksPath .githooks
	@echo "hooks: core.hooksPath=.githooks"

# ---- Gates ----------------------------------------------------------------------------------
test-tooling: ## Blocking gate: unittest suite for the repo tooling in scripts/; t=<module> runs one module
	PYTHONPATH=scripts:tests/tooling $(PY) -m unittest $(if $(t),$(t),discover -s tests/tooling -t tests/tooling)

gate: ## Blocking gate: gate-wiring-check, test-tooling, then check, under the gate lock; `make merge` runs the same stages
	$(LOCKED) bash scripts/gate.sh

gate-wiring-check: ## Blocking gate: every test file runs, no orphan script, every blocking target reached from gate
	$(PY) scripts/check_gate_wiring.py

# ---- Workflow -------------------------------------------------------------------------------
worktree: ## Sanctioned path for starting work: make worktree b=feat/name (sibling tree from origin/main, hooks installed)
	@bash scripts/worktree.sh "$(b)"

sync: ## Sanctioned path for updating the current branch: fetch and fast-forward; refuses a divergent local main
	@bash scripts/sync.sh

# TODO: a report-only watcher that re-runs the gate on each new origin/main commit and notifies on
# failure and recovery. Two PRs can each pass the gate and merge into a failing main.
merge: ## Sanctioned path for landing this repo's PRs: make merge pr=N [keep=1] [dry_run=1]; the only merge path
	$(PY) scripts/merge.py --pr "$(pr)" $(if $(keep),--keep,) $(if $(dry_run),--dry-run,)

branches-gc: ## Advisory: triage local branches and worktrees (merged, superseded, open-PR, checked-out); args="--delete" removes the merged class
	$(PY) scripts/branches_gc.py $(args)
