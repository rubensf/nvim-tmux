#!/usr/bin/env bats

# Integration tests for tmux select-pane.

load _setup

setup() {
  nt_int_setup
  "$SHIM" new-session -d -s swarm >/dev/null
  "$SHIM" split-window -t "2:0.0" -h >/dev/null       # creates 2:0.1
}

teardown() { nt_int_teardown; }

current_winid() { remote_expr "win_getid()"; }

@test "select-pane focuses the target pane's nvim window" {
  # Pane 2:0.0 resolves via leader_winid (top-level cache);
  # pane 2:0.1 has its own binding from split-window.
  local leader_winid pane1_winid
  leader_winid=$(state_dump | jq -r '.leader_winid')
  pane1_winid=$(state_dump | jq -r '.panes["2:0.1"].nvim_winid')
  [[ "$leader_winid" =~ ^[0-9]+$ ]]
  [ "$pane1_winid" != "null" ]

  "$SHIM" select-pane -t "2:0.0"
  [ "$(current_winid)" = "$leader_winid" ]

  "$SHIM" select-pane -t "2:0.1"
  [ "$(current_winid)" = "$pane1_winid" ]
}

@test "select-pane -T sets the title as the pane window's winbar" {
  "$SHIM" select-pane -t "2:0.1" -T "teammate-foo"
  local winid
  winid=$(state_dump | jq -r '.panes["2:0.1"].nvim_winid')
  run remote_expr "getwinvar(${winid}, '&winbar')"
  [ "$output" = "teammate-foo" ]
}

@test "select-pane -P style is accepted and ignored" {
  run "$SHIM" select-pane -t "2:0.0" -P 'bg=red'
  [ "$status" -eq 0 ]
}

@test "select-pane against unknown pane errors" {
  run "$SHIM" select-pane -t "99:9.9"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown pane"* ]]
}

@test "select-pane without -t errors" {
  run "$SHIM" select-pane -T "only-title"
  [ "$status" -ne 0 ]
  [[ "$output" == *"-t"* ]]
}
