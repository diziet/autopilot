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
check-deps:
	@echo "Checking dependencies..."
	@missing=0; warnings=0; \
	if command -v git >/dev/null 2>&1; then \
		echo "  ✓ git      $$(git --version | head -1)"; \
	else \
		echo "  ✗ git      MISSING — install via: xcode-select --install"; \
		missing=1; \
	fi; \
	if command -v jq >/dev/null 2>&1; then \
		echo "  ✓ jq       $$(jq --version 2>&1)"; \
	else \
		echo "  ✗ jq       MISSING — install via: brew install jq"; \
		missing=1; \
	fi; \
	if command -v gh >/dev/null 2>&1; then \
		echo "  ✓ gh       $$(gh --version | head -1)"; \
	else \
		echo "  ✗ gh       MISSING — install via: brew install gh"; \
		missing=1; \
	fi; \
	if command -v claude >/dev/null 2>&1; then \
		echo "  ✓ claude   (found on PATH)"; \
	else \
		echo "  ✗ claude   MISSING — see https://docs.anthropic.com/en/docs/claude-code"; \
		missing=1; \
	fi; \
	if command -v timeout >/dev/null 2>&1; then \
		echo "  ✓ timeout  (found on PATH)"; \
	else \
		echo "  ✗ timeout  MISSING"; \
		echo "    macOS does not include GNU timeout by default."; \
		echo "    Install via: brew install coreutils"; \
		echo "    Homebrew adds 'timeout' to /opt/homebrew/bin (Apple Silicon)"; \
		echo "    or /usr/local/bin (Intel). Ensure this is in your PATH."; \
		missing=1; \
	fi; \
	echo ""; \
	if [ "$$missing" -gt 0 ]; then \
		echo "ERROR: Missing required dependencies. Install them and re-run."; \
		exit 1; \
	fi; \
	echo "All dependencies found."

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
	@echo "     * * * * * autopilot-dispatch /path/to/project"
	@echo "     * * * * * sleep 15 && autopilot-dispatch /path/to/project"
	@echo "     * * * * * sleep 30 && autopilot-dispatch /path/to/project"
	@echo "     * * * * * sleep 45 && autopilot-dispatch /path/to/project"
	@echo "     * * * * * autopilot-review /path/to/project"
	@echo "     * * * * * sleep 15 && autopilot-review /path/to/project"
	@echo "     * * * * * sleep 30 && autopilot-review /path/to/project"
	@echo "     * * * * * sleep 45 && autopilot-review /path/to/project"
	@echo ""
	@echo "  For more info: $(CURDIR)/docs/getting-started.md"
	@echo ""
