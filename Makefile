# nvim-tmux Makefile
#
# Development targets for the tmux shim. `install-dev` installs
# bats-core and shellcheck via Homebrew (macOS) or apt (Linux).
# Other targets assume those tools are on PATH and print a helpful
# pointer if not.

SHELL          := /usr/bin/env bash
REPO_ROOT      := $(shell pwd)
SHIM           := $(REPO_ROOT)/bin/tmux
UNIT_TESTS     := $(wildcard tests/unit/*.bats)
INT_TESTS      := $(wildcard tests/integration/*.bats)
E2E_TESTS      := $(wildcard tests/e2e/*.sh)

.PHONY: help test test-unit test-int test-e2e lint lint-sh \
        install-dev check-bats check-shellcheck

help:
	@echo "nvim-tmux -- make targets:"
	@echo ""
	@echo "  Testing:"
	@echo "    test         All tests (unit + integration + e2e)"
	@echo "    test-unit    Bash unit tests under tests/unit/"
	@echo "    test-int     Headless-nvim integration tests (tests/integration/)"
	@echo "    test-e2e     End-to-end scripts against a real claude binary"
	@echo ""
	@echo "  Linting:"
	@echo "    lint         shellcheck"
	@echo "    lint-sh      shellcheck on bin/tmux"
	@echo ""
	@echo "  Dev setup:"
	@echo "    install-dev  Install bats-core + shellcheck via brew (macOS) or apt (Linux)"

# --- Tool presence guards -------------------------------------------------

check-bats:
	@command -v bats >/dev/null 2>&1 || { \
	  echo >&2 "nvim-tmux: 'bats' not on PATH. Run 'make install-dev' or install bats-core."; \
	  exit 1; \
	}

check-shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo >&2 "nvim-tmux: 'shellcheck' not on PATH. Run 'make install-dev'."; \
	  exit 1; \
	}

# --- Tests ----------------------------------------------------------------

test: test-unit test-int test-e2e

test-unit: check-bats
	@if [ -n "$(UNIT_TESTS)" ]; then \
	  bats $(UNIT_TESTS); \
	else \
	  echo "nvim-tmux: no unit tests found (tests/unit/*.bats)"; \
	fi

test-int: check-bats
	@if [ -n "$(INT_TESTS)" ]; then \
	  bats $(INT_TESTS); \
	else \
	  echo "nvim-tmux: no integration tests yet (tests/integration/*.bats)"; \
	fi

test-e2e:
	@if [ -n "$(E2E_TESTS)" ]; then \
	  for t in $(E2E_TESTS); do \
	    echo "--- $$t"; bash $$t || exit 1; \
	  done; \
	else \
	  echo "nvim-tmux: no e2e tests yet (tests/e2e/*.sh)"; \
	fi

# --- Linting --------------------------------------------------------------

lint: lint-sh

lint-sh: check-shellcheck
	shellcheck -S style $(SHIM)

# --- Dev setup --------------------------------------------------------------

install-dev:
	@if command -v brew >/dev/null 2>&1; then \
	  brew list bats-core >/dev/null 2>&1 || brew install bats-core; \
	  brew list shellcheck >/dev/null 2>&1 || brew install shellcheck; \
	elif command -v apt-get >/dev/null 2>&1; then \
	  sudo apt-get update && sudo apt-get install -y bats shellcheck; \
	else \
	  echo >&2 "nvim-tmux: no supported package manager found (brew, apt). Install bats + shellcheck manually."; \
	  exit 1; \
	fi
