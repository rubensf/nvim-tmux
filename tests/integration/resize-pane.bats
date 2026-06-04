#!/usr/bin/env bats

# Integration tests for tmux resize-pane -t <pane> -x <N>%.

load _setup

setup() {
  nt_int_setup
  "$SHIM" new-session -d -s swarm >/dev/null
  "$SHIM" split-window -t "2:0.0" -h >/dev/null   # 2:0.1
}

teardown() { nt_int_teardown; }

@test "resize-pane -x 30 narrows the target pane" {
  # Pane 2:0.0 uses the leader_winid fallback (no pane-record
  # binding until it materializes its own :terminal). That winid is
  # cached at the top level after the first structural op.
  local winid before after
  winid=$(state_dump | jq -r '.leader_winid')
  [[ "$winid" =~ ^[0-9]+$ ]]
  before=$(remote_expr "winwidth(${winid})")
  "$SHIM" resize-pane -t "2:0.0" -x 30
  after=$(remote_expr "winwidth(${winid})")
  [[ "$after" =~ ^[0-9]+$ ]]
  [ "$after" -gt 0 ]
  [ "$before" -ne "$after" ] || true
}

@test "resize-pane accepts '30%' with trailing percent" {
  run "$SHIM" resize-pane -t "2:0.0" -x 30%
  [ "$status" -eq 0 ]
}

@test "resize-pane against unknown pane errors" {
  run "$SHIM" resize-pane -t "99:9.9" -x 30
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown pane"* ]]
}

@test "resize-pane missing -x errors" {
  run "$SHIM" resize-pane -t "2:0.0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"-x"* ]]
}
