#!/usr/bin/env bats

# Tests for `tmux new-session`.
#
# Contract-level: registers a new session with an initial window and
# pane in state.json. Honors `-P -F <format>` by printing the new pane
# id in the requested format.

load _setup

setup() {
  nt_int_setup
TEST_TMP="$(mktemp -d -t nvim-tmux-bats.XXXXXX)"
  export NVIM_TMUX_STATE_DIR="$TEST_TMP/state"
}

teardown() { nt_int_teardown; }

@test "new-session -d -s foo registers the session" {
  run "$SHIM" new-session -d -s foo
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c "state_dump | jq -r '.sessions.foo.idx'"
  [ "$output" = "2" ]
}

@test "new-session seeds initial window 0 with pane 0" {
  "$SHIM" new-session -d -s foo
  run bash -c "state_dump | jq -r '.windows[\"2:0\"] | type'"
  [ "$output" = "object" ]
  run bash -c "state_dump | jq -r '.panes[\"2:0.0\"] | type'"
  [ "$output" = "object" ]
  run bash -c "state_dump | jq -r '.panes[\"2:0.0\"].nvim_winid'"
  [ "$output" = "null" ]
}

@test "new-session bumps next_session_idx" {
  "$SHIM" new-session -d -s foo
  run bash -c "state_dump | jq -r '.next_session_idx'"
  [ "$output" = "3" ]
}

@test "new-session -P -F '#{pane_id}' prints the new pane id" {
  run "$SHIM" new-session -d -s foo -P -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "2:0.0" ]
}

@test "new-session -P -F '#{window_id}' prints the new window id" {
  run "$SHIM" new-session -d -s foo -P -F '#{window_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "2:0" ]
}

@test "new-session -n win sets the initial window name" {
  "$SHIM" new-session -d -s foo -n bar
  run bash -c "state_dump | jq -r '.windows[\"2:0\"].name'"
  [ "$output" = "bar" ]
}

@test "new-session without -n defaults window name" {
  "$SHIM" new-session -d -s foo
  run bash -c "state_dump | jq -r '.windows[\"2:0\"].name'"
  [ "$output" != "null" ]
  [ -n "$output" ]
}

@test "new-session duplicate name errors" {
  "$SHIM" new-session -d -s foo
  run "$SHIM" new-session -d -s foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"session already exists"* ]]
}

@test "new-session without -s errors" {
  run "$SHIM" new-session -d
  [ "$status" -ne 0 ]
  [[ "$output" == *"-s"* ]]
}

@test "new-session with -P but no -F errors (unsupported format)" {
  run "$SHIM" new-session -d -s foo -P
  [ "$status" -ne 0 ]
}

@test "new-session with unknown flag errors" {
  run "$SHIM" new-session -d -s foo -Z
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "next new-session after one allocates idx 3" {
  "$SHIM" new-session -d -s first
  run "$SHIM" new-session -d -s second -P -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "3:0.0" ]
}
