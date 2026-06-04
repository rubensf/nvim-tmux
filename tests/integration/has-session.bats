#!/usr/bin/env bats

# Tests for `tmux has-session -t <name>`.
#
# Phase 1 ships the stub: no sessions exist, so every call returns 1.
# Phase 2 upgrades state_has_session to consult the real state file.

load _setup

setup() {
  nt_int_setup
}

teardown() { nt_int_teardown; }

@test "has-session -t NAME returns 1 when no session exists (cold start)" {
  run "$SHIM" has-session -t nothing-here
  [ "$status" -eq 1 ]
}

@test "has-session -t NAME produces no output on stdout" {
  run "$SHIM" has-session -t some-name
  [ -z "$output" ]
}

@test "has-session without -t errors on missing required flag" {
  run "$SHIM" has-session
  [ "$status" -eq 1 ]
  [[ "$output" == *"nvim-tmux:"* ]]
  [[ "$output" == *"-t"* || "$output" == *"target"* ]]
}

@test "has-session with unknown flag errors with the bad flag name" {
  run "$SHIM" has-session -t foo --nonsense
  [ "$status" -eq 1 ]
  [[ "$output" == *"--nonsense"* ]]
}

@test "has-session returns 0 after the session has been created" {
  "$SHIM" new-session -d -s foo
  run "$SHIM" has-session -t foo
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "has-session returns 1 for a different session name" {
  "$SHIM" new-session -d -s foo
  run "$SHIM" has-session -t bar
  [ "$status" -eq 1 ]
}

@test "has-session matches hidden sessions as well (post break-pane)" {
  # Drive the production hide path: new-session for the hidden holding
  # session, then break-pane to move a pane into it. has-session should
  # find the holding session afterwards.
  "$SHIM" new-session -d -s scratch >/dev/null
  "$SHIM" new-session -d -s holding >/dev/null
  "$SHIM" break-pane -d -s "2:0.0" -t "holding:" >/dev/null
  run "$SHIM" has-session -t holding
  [ "$status" -eq 0 ]
}

@test "has-session dies loudly when the nvim RPC fails (not a silent 'no')" {
  # A dead socket must NOT read as "session does not exist".
  NVIM="/tmp/definitely-dead-socket-$$" run "$SHIM" has-session -t whatever
  [ "$status" -ne 0 ]
  [[ "$output" == *"RPC failed"* ]]
}
