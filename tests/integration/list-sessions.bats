#!/usr/bin/env bats

# Tests for `tmux list-sessions` (alias: `tmux ls`).

load _setup

setup() {
  nt_int_setup
TEST_TMP="$(mktemp -d -t nt-ls.XXXXXX)"
  export NVIM_TMUX_STATE_DIR="$TEST_TMP/state"
}

teardown() { nt_int_teardown; }

@test "list-sessions on empty state prints nothing, exits 0" {
  run "$SHIM" list-sessions
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list-sessions default format mimics tmux ('NAME: N windows')" {
  "$SHIM" new-session -d -s foo >/dev/null
  "$SHIM" new-window -t foo -n extra >/dev/null
  "$SHIM" new-session -d -s bar >/dev/null
  run "$SHIM" list-sessions
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "foo: 2 windows" ]
  [ "${lines[1]}" = "bar: 1 windows" ]
}

@test "list-sessions -F '#{session_name}' prints only names" {
  "$SHIM" new-session -d -s alpha >/dev/null
  "$SHIM" new-session -d -s beta  >/dev/null
  run "$SHIM" list-sessions -F '#{session_name}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "alpha" ]
  [ "${lines[1]}" = "beta" ]
}

@test "list-sessions -F '#{session_id}' prints \$<idx>" {
  "$SHIM" new-session -d -s alpha >/dev/null    # idx 2
  "$SHIM" new-session -d -s beta  >/dev/null    # idx 3
  run "$SHIM" list-sessions -F '#{session_id}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "\$2" ]
  [ "${lines[1]}" = "\$3" ]
}

@test "ls is an alias for list-sessions" {
  "$SHIM" new-session -d -s foo >/dev/null
  run "$SHIM" ls -F '#{session_name}'
  [ "$status" -eq 0 ]
  [ "$output" = "foo" ]
}

@test "list-sessions with unsupported format errors" {
  run "$SHIM" list-sessions -F '#{bogus}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported format"* ]]
}

@test "list-panes defaults format to #{pane_id} when -F is omitted" {
  "$SHIM" new-session -d -s foo >/dev/null
  run "$SHIM" list-panes -t foo
  [ "$status" -eq 0 ]
  [ "$output" = "2:0.0" ]
}

@test "list-panes -a enumerates panes across every session" {
  "$SHIM" new-session -d -s foo >/dev/null
  "$SHIM" new-session -d -s bar >/dev/null
  run "$SHIM" list-panes -a -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2:0.0" ]
  [ "${lines[1]}" = "3:0.0" ]
}
