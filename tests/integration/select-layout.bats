#!/usr/bin/env bats

# Integration tests for tmux select-layout.
#
# MVP simplification: both main-vertical and tiled resolve to
# ':wincmd =' which equalizes all visible windows. Exact tmux-style
# visual arrangement is deferred; Claude only depends on the panes
# existing and being reachable.

load _setup

setup() {
  nt_int_setup
  "$SHIM" new-session -d -s swarm >/dev/null
  # Build a 3-pane layout: leader + 2 teammates, side-by-side.
  "$SHIM" split-window -t "2:0.0" -h >/dev/null
  "$SHIM" split-window -t "2:0.0" -h >/dev/null
}

teardown() { nt_int_teardown; }

win_count() { remote_expr "winnr('\$')"; }

@test "select-layout main-vertical succeeds with 3 panes" {
  [ "$(win_count)" = "3" ]
  run "$SHIM" select-layout -t "swarm:0" main-vertical
  [ "$status" -eq 0 ]
  [ "$(win_count)" = "3" ]
}

@test "select-layout tiled succeeds with 3 panes" {
  run "$SHIM" select-layout -t "swarm:0" tiled
  [ "$status" -eq 0 ]
  [ "$(win_count)" = "3" ]
}

@test "select-layout preserves all pane records in state" {
  local before after
  before=$(state_dump | jq -r '[.panes | keys[] | select(startswith("2:0."))] | sort | join(",")')
  "$SHIM" select-layout -t "swarm:0" main-vertical
  after=$(state_dump | jq -r '[.panes | keys[] | select(startswith("2:0."))] | sort | join(",")')
  [ "$before" = "$after" ]
}

@test "select-layout with an unknown layout errors" {
  run "$SHIM" select-layout -t "swarm:0" bogus-layout
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported layout"* ]]
}

@test "select-layout without a layout name errors" {
  run "$SHIM" select-layout -t "swarm:0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"layout name"* ]]
}
