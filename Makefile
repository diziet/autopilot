# Autopilot — Makefile
# Targets: check, test, lint, install, install-launchd, uninstall-launchd, check-deps

SHELL := /bin/bash
PREFIX ?= $(HOME)/.local

# Find all .sh files in bin/ and lib/ for linting
SH_FILES := $(wildcard bin/*.sh lib/*.sh)
# Also lint entry points (no .sh extension) if they exist
BIN_FILES := $(wildcard bin/autopilot-*)

.PHONY: check test lint install install-launchd uninstall-launchd check-deps live-test live-test-github

## Run lint and test in parallel, fail if either fails
check:
	@make lint & lint_pid=$$!; make test & test_pid=$$!; \
	wait $$lint_pid; lint_rc=$$?; wait $$test_pid; test_rc=$$?; \
	if [ $$lint_rc -ne 0 ] || [ $$test_rc -ne 0 ]; then exit 1; fi

## Run the bats test suite (parallel, default 20 jobs)
## On macOS, creates a RAM disk for test temp files to reduce I/O contention.
test:
	@command -v bats >/dev/null 2>&1 || { echo "Error: bats not found. Install with: brew install bats-core"; exit 1; }
	@command -v parallel >/dev/null 2>&1 || { echo "Error: parallel not found (required by bats --jobs). Install with: brew install parallel"; exit 1; }
	@command -v timeout >/dev/null 2>&1 || { echo "Error: timeout not found. Install with: brew install coreutils"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "Error: jq not found. Install with: brew install jq"; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "Error: git not found. Install Xcode CLI tools: xcode-select --install"; exit 1; }
	@cat tests/*.bats tests/helpers/*.bash lib/*.sh > /dev/null 2>&1 || true
	@if [ "$$(uname)" = "Darwin" ] && command -v hdiutil >/dev/null 2>&1; then \
		_rd=$$(hdiutil attach -nomount ram://2097152 2>/dev/null | awk '{print $$1}') && \
		diskutil erasevolume HFS+ AutopilotTests "$$_rd" >/dev/null 2>&1 && \
		TMPDIR=/Volumes/AutopilotTests bats --jobs $${AUTOPILOT_TEST_JOBS:-20} --no-parallelize-within-files tests/; \
		_rc=$$?; hdiutil detach "$$_rd" >/dev/null 2>&1; exit $$_rc; \
	else \
		bats --jobs $${AUTOPILOT_TEST_JOBS:-20} --no-parallelize-within-files tests/; \
	fi

## Run shellcheck on all shell files in bin/ and lib/
## Files are linted individually in parallel — one giant invocation causes
## exponential cross-file analysis (12+ min, 2.5GB RAM for 41 files).
lint:
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

## Verify required dependencies are installed (exits non-zero on missing critical deps)
## Delegates to lib/preflight.sh for the dependency list and install hints.
check-deps:
	@$(SHELL) "$(CURDIR)/scripts/check-deps.sh"

## Run the live test suite (local-only, no GitHub repo created)
live-test:
	"$(CURDIR)/bin/autopilot-live-test" run

## Run the live test suite with GitHub repo creation
live-test-github:
	"$(CURDIR)/bin/autopilot-live-test" run --github

## Install autopilot binaries (dispatch, review, doctor, start, etc.) to PREFIX (default: ~/.local)
## All bin/autopilot-* files are symlinked automatically.
install: check-deps
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

## Install launchd plists for a project (macOS)
## Usage: make install-launchd PROJECT=/path/to/project [DISPATCHER_ACCOUNT=1] [REVIEWER_ACCOUNT=1] [INTERVAL=15]
DISPATCHER_ACCOUNT ?= 1
REVIEWER_ACCOUNT ?= 1
INTERVAL ?= 15
install-launchd:
	@if [ -z "$(PROJECT)" ]; then \
		echo "Error: PROJECT is required."; \
		echo "Usage: make install-launchd PROJECT=/path/to/project [DISPATCHER_ACCOUNT=1] [REVIEWER_ACCOUNT=1] [INTERVAL=15]"; \
		exit 1; \
	fi
	@chmod +x "$(CURDIR)/bin/autopilot-schedule"
	"$(CURDIR)/bin/autopilot-schedule" --interval "$(INTERVAL)" --dispatcher-account "$(DISPATCHER_ACCOUNT)" --reviewer-account "$(REVIEWER_ACCOUNT)" "$(PROJECT)"

## Uninstall launchd plists for a project (macOS)
## Usage: make uninstall-launchd PROJECT=/path/to/project [DISPATCHER_ACCOUNT=1] [REVIEWER_ACCOUNT=1]
uninstall-launchd:
	@if [ -z "$(PROJECT)" ]; then \
		echo "Error: PROJECT is required."; \
		echo "Usage: make uninstall-launchd PROJECT=/path/to/project [DISPATCHER_ACCOUNT=1] [REVIEWER_ACCOUNT=1]"; \
		exit 1; \
	fi
	@chmod +x "$(CURDIR)/bin/autopilot-schedule"
	"$(CURDIR)/bin/autopilot-schedule" --uninstall --dispatcher-account "$(DISPATCHER_ACCOUNT)" --reviewer-account "$(REVIEWER_ACCOUNT)" "$(PROJECT)"
