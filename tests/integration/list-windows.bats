#!/usr/bin/env bats

# Tests for `tmux list-windows`.
#
# Target: -t <session>. Formats: #{window_name} or #{window_id}.
# One entry per window, sorted by window idx.

load _setup

setup() {
  nt_int_setup
TEST_TMP="$(mktemp -d -t nvim-tmux-bats.XXXXXX)"
  export NVIM_TMUX_STATE_DIR="$TEST_TMP/state"
  "$SHIM" new-session -d -s foo -n main
  "$SHIM" new-window -t foo -n side
  "$SHIM" new-window -t foo -n log
}

teardown() { nt_int_teardown; }

@test "list-windows -F '#{window_name}' prints names in idx order" {
  run "$SHIM" list-windows -t foo -F '#{window_name}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "main" ]
  [ "${lines[1]}" = "side" ]
  [ "${lines[2]}" = "log" ]
}

@test "list-windows -F '#{window_id}' prints window ids in idx order" {
  run "$SHIM" list-windows -t foo -F '#{window_id}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2:0" ]
  [ "${lines[1]}" = "2:1" ]
  [ "${lines[2]}" = "2:2" ]
}

@test "list-windows against unknown session errors" {
  run "$SHIM" list-windows -t ghost -F '#{window_name}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]]
}

@test "list-windows without -t errors" {
  run "$SHIM" list-windows -F '#{window_name}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"-t"* ]]
}

@test "list-windows without -F errors" {
  run "$SHIM" list-windows -t foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"-F"* ]]
}

@test "list-windows unsupported format errors" {
  run "$SHIM" list-windows -t foo -F '#{session_id}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"format"* ]]
}
