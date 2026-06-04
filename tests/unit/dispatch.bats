#!/usr/bin/env bats

# Unit tests for the top-level dispatcher in bin/tmux.
#
# These tests exercise argv parsing, subcommand routing, and the shared
# error/exit-code behavior. Per-subcommand semantics live in their own
# bats files (tmux-version.bats, has-session.bats, etc.).

setup() {
  SHIM="$BATS_TEST_DIRNAME/../../bin/tmux"
  [ -x "$SHIM" ] || skip "bin/tmux not executable"
}

@test "no arguments prints usage and exits non-zero" {
  run "$SHIM"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nvim-tmux"* ]]
}

@test "unknown subcommand errors with nvim-tmux prefix and exits 1" {
  run "$SHIM" completely-made-up-subcommand
  [ "$status" -eq 1 ]
  [[ "$output" == *"nvim-tmux:"* ]]
  [[ "$output" == *"unknown subcommand"* ]]
}

@test "unknown subcommand includes the bad name in the message" {
  run "$SHIM" bogus-cmd
  [[ "$output" == *"bogus-cmd"* ]]
}

@test "stderr is where errors go (stdout stays clean)" {
  run bash -c '"$1" bogus-cmd 2>/dev/null' _ "$SHIM"
  # stdout should be empty (everything went to stderr)
  [ -z "$output" ]
}
