#!/usr/bin/env bats

# Tests for `tmux new-window`.
#
# Adds a new window to an existing session. Allocates window idx,
# creates an initial pane, returns the new pane id on `-P -F <fmt>`.

load _setup

setup() {
  nt_int_setup
TEST_TMP="$(mktemp -d -t nvim-tmux-bats.XXXXXX)"
  export NVIM_TMUX_STATE_DIR="$TEST_TMP/state"
  # Every test needs a pre-existing session.
  "$SHIM" new-session -d -s foo
}

teardown() { nt_int_teardown; }

@test "new-window -t foo -n bar registers window 1 under foo" {
  run "$SHIM" new-window -t foo -n bar
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c "state_dump | jq -r '.windows[\"2:1\"].name'"
  [ "$output" = "bar" ]
}

@test "new-window seeds initial pane 0 keyed <sess>:<win>.0" {
  "$SHIM" new-window -t foo -n bar
  run bash -c "state_dump | jq -r '.panes[\"2:1.0\"] | type'"
  [ "$output" = "object" ]
  run bash -c "state_dump | jq -r '.windows[\"2:1\"] | type'"
  [ "$output" = "object" ]
}

@test "new-window bumps next_window" {
  "$SHIM" new-window -t foo -n bar
  run bash -c "state_dump | jq -r '.sessions.foo.next_window'"
  [ "$output" = "2" ]
}

@test "new-window -P -F '#{pane_id}' prints the new pane id" {
  run "$SHIM" new-window -t foo -n bar -P -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "2:1.0" ]
}

@test "new-window -P -F '#{window_id}' prints the new window id" {
  run "$SHIM" new-window -t foo -n bar -P -F '#{window_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "2:1" ]
}

@test "new-window against unknown session errors" {
  run "$SHIM" new-window -t ghost -n bar
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown session"* ]]
}

@test "new-window without -t errors" {
  run "$SHIM" new-window -n bar
  [ "$status" -ne 0 ]
  [[ "$output" == *"-t"* ]]
}

@test "successive new-window calls allocate sequential indices" {
  "$SHIM" new-window -t foo -n w1
  run "$SHIM" new-window -t foo -n w2 -P -F '#{window_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "2:2" ]
}
