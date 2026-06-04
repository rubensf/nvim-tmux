#!/usr/bin/env bats

# Integration tests for the nvim_expr transport helper against a real
# headless nvim. The test body calls it directly, so we source the shim
# (its main-guard keeps it from dispatching) after nt_int_setup spawns
# the nvim.

load _setup

setup() {
  nt_int_setup
  # shellcheck source=../../bin/tmux
  . "$SHIM"
  set +euo pipefail
}

teardown() { nt_int_teardown; }

@test "nvim_expr returns an integer result" {
  run nvim_expr '1 + 2'
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "nvim_expr returns a string result" {
  run nvim_expr 'v:version > 0 ? "ok" : "fail"'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "nvim_expr surfaces a vim error as non-zero exit" {
  run nvim_expr 'this_is_not_a_var'
  [ "$status" -ne 0 ]
}

@test "nvim_expr can run Ex commands via execute()" {
  nvim_expr "execute('vsplit')" >/dev/null
  [ "$(nvim_expr 'winnr("$")')" = "2" ]
}

@test "nvim_expr fails non-zero when the server socket is bogus" {
  NVIM=/tmp/definitely-not-a-real-socket-$$ run nvim_expr '1 + 1'
  [ "$status" -ne 0 ]
}
