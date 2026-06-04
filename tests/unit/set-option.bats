#!/usr/bin/env bats

# Tests for `tmux set-option`. Documented MVP no-op -- must exit 0 on
# the pane/window-scoped forms Claude invokes.

setup() {
  SHIM="$BATS_TEST_DIRNAME/../../bin/tmux"
  [ -x "$SHIM" ] || skip "bin/tmux not executable"
  TEST_TMP="$(mktemp -d -t nt-setopt.XXXXXX)"
  export NVIM_TMUX_STATE_DIR="$TEST_TMP/state"
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
}

@test "set-option -p -t pane pane-border-style fg=red returns 0 (no-op)" {
  run "$SHIM" set-option -p -t "1:0.0" pane-border-style "fg=red"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "set-option -w -t window pane-border-status off returns 0 (no-op)" {
  run "$SHIM" set-option -w -t "1:0" pane-border-status off
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "set-option -g a-global-option value returns 0 (no-op)" {
  run "$SHIM" set-option -g status off
  [ "$status" -eq 0 ]
}

@test "set-option with unknown flag is silently accepted (no-op)" {
  run "$SHIM" set-option -Z bogus-flag
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
