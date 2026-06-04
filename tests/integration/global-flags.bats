#!/usr/bin/env bats

# Tests for tmux's global flags that appear before the subcommand.
# Claude's Agent Teams uses 'tmux -L <name> <sub> ...' to isolate its
# swarm session onto a named socket; our shim has no socket concept
# so these flags are accepted silently.

load _setup

setup() { nt_int_setup; }

teardown() { nt_int_teardown; }

@test "-L <name> before -V is accepted" {
  run "$SHIM" -L claude-swarm -V
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux 3.0"* ]]
}

@test "-L <name> before has-session passes through to the subcommand" {
  run "$SHIM" -L claude-swarm has-session -t nothing
  [ "$status" -eq 1 ]   # cold-start: no such session
  [ -z "$output" ]
}

@test "-L without an argument errors loudly" {
  run "$SHIM" -L
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires an argument"* ]]
}

@test "-S <path> before subcommand is a no-op" {
  run "$SHIM" -S /tmp/some.sock -V
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux 3.0"* ]]
}

@test "-f <config> before subcommand is a no-op" {
  run "$SHIM" -f /tmp/nowhere.conf -V
  [ "$status" -eq 0 ]
}

@test "chained boolean globals (-u -2) before subcommand are accepted" {
  run "$SHIM" -u -2 -V
  [ "$status" -eq 0 ]
  [[ "$output" == *"tmux 3.0"* ]]
}

@test "-L before new-session still creates the session" {
  "$SHIM" -L my-socket new-session -d -s foo
  run bash -c "state_dump | jq -r '.sessions.foo.idx'"
  [ "$output" = "2" ]
}

@test "unknown flag before subcommand falls through as an unknown subcommand" {
  run "$SHIM" -Z something
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown subcommand"* ]]
}
