#!/usr/bin/env bats

# Tests for `tmux -V` / `tmux --version`.
#
# Claude's detection path does `which tmux` and then parses `tmux -V`.
# The output must start with `tmux <major>.<minor>` so any downstream
# version-parsing regex accepts it; the nvim-tmux suffix identifies
# the shim for humans.

setup() {
  SHIM="$BATS_TEST_DIRNAME/../../bin/tmux"
  [ -x "$SHIM" ] || skip "bin/tmux not executable"
}

@test "-V prints a tmux-compatible version string" {
  run "$SHIM" -V
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^tmux\ [0-9]+\.[0-9]+ ]]
}

@test "-V includes the nvim-tmux identifier" {
  run "$SHIM" -V
  [[ "$output" == *"nvim-tmux"* ]]
}

@test "--version is an alias for -V" {
  run "$SHIM" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^tmux\ [0-9]+\.[0-9]+ ]]
}

@test "-V prints to stdout not stderr" {
  run bash -c '"$1" -V 2>/dev/null' _ "$SHIM"
  [[ "$output" =~ ^tmux\ [0-9]+\.[0-9]+ ]]
}
