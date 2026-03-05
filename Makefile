# Autopilot — Makefile
# Targets: test, lint, install

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

## Verify required dependencies are installed
check-deps:
	@echo "Checking dependencies..."
	@command -v claude >/dev/null 2>&1 || echo "WARNING: claude not found"
	@command -v gh    >/dev/null 2>&1 || echo "WARNING: gh not found"
	@command -v jq    >/dev/null 2>&1 || echo "WARNING: jq not found"
	@command -v git   >/dev/null 2>&1 || echo "WARNING: git not found"
	@command -v timeout >/dev/null 2>&1 || echo "WARNING: timeout not found (macOS: brew install coreutils)"
	@echo "Dependency check complete."

## Install autopilot binaries to PREFIX (default: ~/.local)
install: check-deps
	@mkdir -p "$(PREFIX)/bin"
	@count=0; \
	for f in bin/autopilot-*; do \
		[ -f "$$f" ] || continue; \
		ln -sf "$(CURDIR)/$$f" "$(PREFIX)/bin/$$(basename $$f)"; \
		echo "Linked $$f -> $(PREFIX)/bin/$$(basename $$f)"; \
		count=$$((count + 1)); \
	done; \
	if [ "$$count" -eq 0 ]; then \
		echo "No autopilot binaries found in bin/ — nothing to install."; \
	else \
		echo ""; \
		echo "Autopilot installed. Ensure $(PREFIX)/bin is in your PATH."; \
	fi
