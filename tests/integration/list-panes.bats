#!/usr/bin/env bats

# Tests for `tmux list-panes`.
#
# Target shapes Claude passes:
#   -t <session>:<window>    one specific window
#   -t <session>             all windows in the session
# Format: -F '#{pane_id}' -> one pane id per line.

load _setup

setup() {
  nt_int_setup
TEST_TMP="$(mktemp -d -t nvim-tmux-bats.XXXXXX)"
  export NVIM_TMUX_STATE_DIR="$TEST_TMP/state"
}

teardown() { nt_int_teardown; }

# Seed an extra pane in sess "foo" window 0 by splitting its existing
# pane. Drives the shim's split-window code path -- target uses the
# numeric pane-id form ("2:0.0") since session "foo" was created first
# and got idx 2.
add_pane() {
  "$SHIM" split-window -t "2:0.0" -h >/dev/null
}

@test "list-panes -t foo:0 -F '#{pane_id}' lists the single seeded pane" {
  "$SHIM" new-session -d -s foo
  run "$SHIM" list-panes -t foo:0 -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "2:0.0" ]
}

@test "list-panes -t foo:0 lists multiple panes in insertion order" {
  "$SHIM" new-session -d -s foo
  add_pane foo 0 1
  add_pane foo 0 2
  run "$SHIM" list-panes -t foo:0 -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2:0.0" ]
  [ "${lines[1]}" = "2:0.1" ]
  [ "${lines[2]}" = "2:0.2" ]
}

@test "list-panes -t foo lists panes across all windows in the session" {
  "$SHIM" new-session -d -s foo
  "$SHIM" new-window -t foo -n w1
  run "$SHIM" list-panes -t foo -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" = "2" ]
  [[ "$output" == *"2:0.0"* ]]
  [[ "$output" == *"2:1.0"* ]]
}

@test "list-panes against unknown session errors" {
  run "$SHIM" list-panes -t ghost -F '#{pane_id}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]]
}

@test "list-panes against unknown window in known session errors" {
  "$SHIM" new-session -d -s foo
  run "$SHIM" list-panes -t foo:99 -F '#{pane_id}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]]
}

@test "list-panes without -t errors" {
  "$SHIM" new-session -d -s foo
  run "$SHIM" list-panes -F '#{pane_id}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"-t"* ]]
}

@test "list-panes without -F defaults to #{pane_id}" {
  "$SHIM" new-session -d -s foo
  run "$SHIM" list-panes -t foo:0
  [ "$status" -eq 0 ]
  [ "$output" = "2:0.0" ]
}

@test "list-panes unsupported format errors" {
  "$SHIM" new-session -d -s foo
  run "$SHIM" list-panes -t foo:0 -F '#{pane_title}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"format"* ]]
}

@test "list-panes -t <session>:<window-NAME> resolves by name (Claude swarm path)" {
  # Mimic Claude's external-mode call: new-session with -n swarm-view,
  # then list-panes against "claude-swarm:swarm-view".
  "$SHIM" new-session -d -s claude-swarm -n swarm-view
  run "$SHIM" list-panes -t claude-swarm:swarm-view -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "2:0.0" ]
}

@test "list-panes window-ref accepts either name or idx" {
  "$SHIM" new-session -d -s foo -n main
  run "$SHIM" list-panes -t foo:0 -F '#{pane_id}'
  [ "$status" -eq 0 ]; [ "$output" = "2:0.0" ]
  run "$SHIM" list-panes -t foo:main -F '#{pane_id}'
  [ "$status" -eq 0 ]; [ "$output" = "2:0.0" ]
}
