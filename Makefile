# Autopilot — Makefile
# Targets: test, lint, install, check-deps

SHELL := /bin/bash
PREFIX ?= $(HOME)/.local

# Find all .sh files in bin/ and lib/ for linting
SH_FILES := $(wildcard bin/*.sh lib/*.sh)
# Also lint entry points (no .sh extension) if they exist
BIN_FILES := $(wildcard bin/autopilot-*)

.PHONY: test lint install check-deps

## Run the bats test suite
test:
	@command -v bats >/dev/null 2>&1 || { echo "Error: bats not found. Install with: brew install bats-core"; exit 1; }
	bats tests/

## Run shellcheck on all shell files in bin/ and lib/
lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "Error: shellcheck not found. Install with: brew install shellcheck"; exit 1; }
	@files=""; \
	for f in $(SH_FILES) $(BIN_FILES); do \
		[ -f "$$f" ] && files="$$files $$f"; \
	done; \
	if [ -n "$$files" ]; then \
		shellcheck $$files; \
	else \
		echo "No shell files to lint."; \
	fi

## Verify required dependencies are installed (exits non-zero on missing critical deps)
## Delegates to lib/preflight.sh for the dependency list and install hints.
check-deps:
	@$(SHELL) "$(CURDIR)/scripts/check-deps.sh"

## Install autopilot binaries to PREFIX (default: ~/.local)
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
	@echo "  4. Add cron jobs (15-second ticks):"
	@echo "     crontab -e"
	@echo "     PATH=$(PREFIX)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
	@echo "     * * * * * autopilot-dispatch /path/to/project"
	@echo "     * * * * * sleep 15 && autopilot-dispatch /path/to/project"
	@echo "     * * * * * sleep 30 && autopilot-dispatch /path/to/project"
	@echo "     * * * * * sleep 45 && autopilot-dispatch /path/to/project"
	@echo "     * * * * * autopilot-review /path/to/project"
	@echo "     * * * * * sleep 15 && autopilot-review /path/to/project"
	@echo "     * * * * * sleep 30 && autopilot-review /path/to/project"
	@echo "     * * * * * sleep 45 && autopilot-review /path/to/project"
	@echo ""
	@echo "  For more info: $(CURDIR)/README.md"
	@echo ""
