#!/usr/bin/env bats

# Unit tests for nvim_socket (env discovery) and _nvim_bin.
# The nvim_expr transport helper needs a real nvim and lives under
# tests/integration/.

setup() {
  # Source the shim for its function definitions; its main-guard keeps
  # it from dispatching. Relax strict mode so bats isn't affected.
  # shellcheck source=../../bin/tmux
  . "$BATS_TEST_DIRNAME/../../bin/tmux"
  set +euo pipefail
}

@test "nvim_socket prefers \$NVIM over \$NVIM_LISTEN_ADDRESS" {
  NVIM=/tmp/nv.primary NVIM_LISTEN_ADDRESS=/tmp/nv.legacy run nvim_socket
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/nv.primary" ]
}

@test "nvim_socket falls back to \$NVIM_LISTEN_ADDRESS when \$NVIM is unset" {
  unset NVIM
  NVIM_LISTEN_ADDRESS=/tmp/nv.legacy run nvim_socket
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/nv.legacy" ]
}

@test "nvim_socket errors with remediation hint when nothing is set" {
  unset NVIM NVIM_LISTEN_ADDRESS
  run nvim_socket
  [ "$status" -ne 0 ]
  [[ "$output" == *":terminal"* ]]
}

@test "_nvim_bin defaults to 'nvim' when override is unset" {
  unset NVIM_TMUX_NVIM_BIN
  run _nvim_bin
  [ "$status" -eq 0 ]
  [ "$output" = "nvim" ]
}

@test "_nvim_bin honors \$NVIM_TMUX_NVIM_BIN override" {
  NVIM_TMUX_NVIM_BIN=/opt/foo/nvim run _nvim_bin
  [ "$status" -eq 0 ]
  [ "$output" = "/opt/foo/nvim" ]
}
