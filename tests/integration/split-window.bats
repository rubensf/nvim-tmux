#!/usr/bin/env bats

# Integration tests for tmux split-window against a real headless nvim.
# Drives bin/tmux directly -- the full stack (dispatcher -> state -> nvim
# bridge) participates.

load _setup

setup() {
  nt_int_setup
  "$SHIM" new-session -d -s swarm >/dev/null
}

teardown() { nt_int_teardown; }

win_count() { remote_expr "winnr('\$')"; }

@test "split-window -t 2:0.0 -h goes from 1 window to 2" {
  [ "$(win_count)" = "1" ]
  run "$SHIM" split-window -t "2:0.0" -h
  [ "$status" -eq 0 ]
  [ "$(win_count)" = "2" ]
}

@test "split-window -P -F '#{pane_id}' prints the new pane id" {
  run "$SHIM" split-window -t "2:0.0" -h -P -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "2:0.1" ]
}

@test "split-window records nvim_winid in state" {
  "$SHIM" split-window -t "2:0.0" -h >/dev/null
  run bash -c "state_dump | jq -r '.panes[\"2:0.1\"].nvim_winid'"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "first split-window caches leader_winid at the top level" {
  run bash -c "state_dump | jq -r '.leader_winid // \"null\"'"
  [ "$output" = "null" ]
  "$SHIM" split-window -t "2:0.0" -h >/dev/null
  run bash -c "state_dump | jq -r '.leader_winid'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "two splits create three nvim windows" {
  "$SHIM" split-window -t "2:0.0" -h >/dev/null
  "$SHIM" split-window -t "2:0.0" -v >/dev/null
  [ "$(win_count)" = "3" ]
}

@test "split-window -v (stacked) creates a horizontal-border split" {
  "$SHIM" split-window -t "2:0.0" -v >/dev/null
  [ "$(win_count)" = "2" ]
  local new_winid h
  new_winid=$(state_dump | jq -r '.panes["2:0.1"].nvim_winid')
  h=$(remote_expr "winheight(${new_winid})")
  [[ "$h" =~ ^[0-9]+$ ]]
  [ "$h" -gt 0 ]
}

@test "split-window -l 30% resizes to ~30% of the PRE-split parent width" {
  # With a single window, the parent's pre-split width is &columns.
  local total expected new_winid new_w
  total=$(remote_expr "&columns")
  expected=$(( total * 30 / 100 ))
  "$SHIM" split-window -t "2:0.0" -h -l 30 >/dev/null
  new_winid=$(state_dump | jq -r '.panes["2:0.1"].nvim_winid')
  new_w=$(remote_expr "winwidth(${new_winid})")
  [[ "$new_w" =~ ^[0-9]+$ ]]
  # Allow a couple of columns of slack for the window separator.
  [ "$new_w" -ge $(( expected - 2 )) ]
  [ "$new_w" -le $(( expected + 2 )) ]
}

@test "split-window with unknown flag errors" {
  run "$SHIM" split-window -t "2:0.0" -Z
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "split-window without -t errors" {
  run "$SHIM" split-window -h
  [ "$status" -ne 0 ]
  [[ "$output" == *"-t"* ]]
}

@test "split-window without -h/-v errors" {
  run "$SHIM" split-window -t "2:0.0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"-h"* || "$output" == *"-v"* ]]
}
