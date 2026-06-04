#!/usr/bin/env bats

# Integration tests for tmux kill-pane: closes the nvim window and
# removes the pane record, idempotently.

load _setup

setup() {
  nt_int_setup
  "$SHIM" new-session -d -s swarm >/dev/null
}

teardown() { nt_int_teardown; }

win_count() { remote_expr "winnr('\$')"; }

@test "kill-pane closes the nvim window for the target pane" {
  "$SHIM" split-window -t "2:0.0" -h >/dev/null      # 1 -> 2 windows
  [ "$(win_count)" = "2" ]
  "$SHIM" kill-pane -t "2:0.1"
  [ "$(win_count)" = "1" ]
}

@test "kill-pane removes the pane record from state" {
  "$SHIM" split-window -t "2:0.0" -h >/dev/null
  "$SHIM" kill-pane -t "2:0.1"
  run bash -c "state_dump | jq -r '.panes[\"2:0.1\"]'"
  [ "$output" = "null" ]
}

@test "kill-pane is idempotent (second call is a no-op success)" {
  "$SHIM" split-window -t "2:0.0" -h >/dev/null
  "$SHIM" kill-pane -t "2:0.1"
  run "$SHIM" kill-pane -t "2:0.1"
  [ "$status" -eq 0 ]
}

@test "kill-pane removes the window when its last pane dies" {
  "$SHIM" new-window -t swarm -n scratch >/dev/null    # allocates 2:1.0
  "$SHIM" kill-pane -t "2:1.0"
  run bash -c "state_dump | jq -r '.windows[\"2:1\"]'"
  [ "$output" = "null" ]
}

@test "kill-pane removes the session when its last pane dies" {
  "$SHIM" new-session -d -s scratch >/dev/null         # allocates 3:0.0
  "$SHIM" kill-pane -t "3:0.0"
  run bash -c "state_dump | jq -r '.sessions.scratch'"
  [ "$output" = "null" ]
}

@test "kill-pane without -t errors" {
  run "$SHIM" kill-pane
  [ "$status" -ne 0 ]
  [[ "$output" == *"-t"* ]]
}
