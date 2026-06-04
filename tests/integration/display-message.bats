#!/usr/bin/env bats

# Tests for `tmux display-message -p <format>`.
#
# Claude calls this in three shapes:
#   tmux display-message -p '#{pane_id}'
#   tmux display-message -p '#{window_id}'
#   tmux display-message -t <target> -p '#{window_id}'
#
# Phase 1 ships a stub: returns the hardcoded leader identity regardless
# of the -t target. Phase 2 upgrades display-message to consult state.

load _setup

setup() {
  nt_int_setup
}

teardown() { nt_int_teardown; }

@test "display-message -p '#{pane_id}' returns leader pane id" {
  run "$SHIM" display-message -p '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "1:0.0" ]
}

@test "display-message -p '#{window_id}' returns leader window id" {
  run "$SHIM" display-message -p '#{window_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "1:0" ]
}

@test "display-message -t <pane-id> -p '#{window_id}' returns that pane's window id" {
  run "$SHIM" display-message -t "3:1.5" -p '#{window_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "3:1" ]
}

@test "display-message -t <pane-id> -p '#{pane_id}' echoes the target pane id" {
  run "$SHIM" display-message -t "3:1.5" -p '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "3:1.5" ]
}

@test "display-message -t <window-id> -p '#{window_id}' echoes the target window id" {
  run "$SHIM" display-message -t "3:1" -p '#{window_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "3:1" ]
}

@test "display-message without -p errors" {
  run "$SHIM" display-message
  [ "$status" -eq 1 ]
  [[ "$output" == *"-p"* || "$output" == *"format"* ]]
}

@test "display-message with unsupported format errors" {
  run "$SHIM" display-message -p '#{pane_title}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"#{pane_title}"* ]]
}

@test "display-message output goes to stdout" {
  run bash -c '"$1" display-message -p "#{pane_id}" 2>/dev/null' _ "$SHIM"
  [ "$output" = "1:0.0" ]
}

# --- #{window_panes} -------------------------------------------------

@test "display-message -t <window> -p '#{window_panes}' counts panes" {
  "$SHIM" new-session -d -s swarm >/dev/null         # session idx 2, 1 pane
  run "$SHIM" display-message -t "2:0" -p '#{window_panes}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "display-message -t <pane> -p '#{window_panes}' counts the pane's window" {
  "$SHIM" new-session -d -s swarm >/dev/null
  run "$SHIM" display-message -t "2:0.0" -p '#{window_panes}'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "display-message '#{window_panes}' reflects splits recorded in state" {
  "$SHIM" new-session -d -s swarm >/dev/null
  nt_state split_pane "2:0.0" >/dev/null
  nt_state split_pane "2:0.0" >/dev/null
  run "$SHIM" display-message -t "2:0" -p '#{window_panes}'
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "display-message '#{window_panes}' errors on unknown target window" {
  run "$SHIM" display-message -t "99:9" -p '#{window_panes}'
  [ "$status" -ne 0 ]
}
