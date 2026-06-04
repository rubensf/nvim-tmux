# Shared bootstrap for integration .bats files. Each test file does:
#
#     load _setup
#     setup() { nt_int_setup; }
#     teardown() { nt_int_teardown; }
#
# Then any helper function defined here (state_dump, remote_expr, ...)
# is available to the test bodies.

# Resolves the real nvim binary, preferring an explicit env override.
nt_int_resolve_nvim() {
  if [[ -n "${NVIM_TMUX_NVIM_BIN:-}" ]]; then
    echo "$NVIM_TMUX_NVIM_BIN"
  elif [[ -x /opt/homebrew/bin/nvim ]]; then
    echo /opt/homebrew/bin/nvim
  else
    command -v nvim || true
  fi
}

# Spawns a fresh headless nvim on a per-test socket, exports the env
# the shim needs, and waits for the socket to appear. Sets:
#   NVIM_BIN, SOCK, NVIM_PID, REPO_ROOT, SHIM
#   NVIM (rpc socket), NVIM_TMUX_NVIM_BIN
nt_int_setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  SHIM="$REPO_ROOT/bin/tmux"
  NVIM_BIN=$(nt_int_resolve_nvim)
  [ -n "$NVIM_BIN" ] && [ -x "$NVIM_BIN" ] || skip "no nvim binary found"
  export NVIM_TMUX_NVIM_BIN="$NVIM_BIN"

  TEST_TMP=$(mktemp -d -t nt-int.XXXXXX)
  SOCK="$TEST_TMP/nvim.sock"
  "$NVIM_BIN" --headless --listen "$SOCK" --clean >/dev/null 2>&1 &
  NVIM_PID=$!
  export NVIM="$SOCK"
  export NVIM_BIN SOCK
  unset NVIM_LISTEN_ADDRESS

  local waited=0
  while [[ ! -S "$SOCK" ]]; do
    ((waited >= 3000)) && {
      kill "$NVIM_PID" 2>/dev/null || true
      skip "nvim socket did not appear in 3s"
    }
    sleep 0.05
    waited=$((waited + 50))
  done

  # Make the lua state module reachable from the headless nvim. The shim
  # also does this internally on first state call, but doing it once here
  # lets test helpers (state_dump, remote_expr) skip the bootstrap.
  "$NVIM_BIN" --headless --server "$SOCK" \
    --remote-expr "execute('set runtimepath+=' . fnameescape('$REPO_ROOT'))" \
    </dev/null >/dev/null 2>&1
}

nt_int_teardown() {
  if [[ -n "${NVIM_PID:-}" ]] && kill -0 "$NVIM_PID" 2>/dev/null; then
    "$NVIM_BIN" --server "$SOCK" --remote-expr "execute('qa!')" >/dev/null 2>&1 || true
    sleep 0.1
    kill "$NVIM_PID" 2>/dev/null || true
    wait "$NVIM_PID" 2>/dev/null || true
  fi
  [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

# Evaluate a vim expression against the test nvim and echo the result.
remote_expr() {
  "$NVIM_BIN" --headless --server "$SOCK" --remote-expr "$1" </dev/null
}

# Dump the live nvim's state as JSON. Stand-in for the old
# `cat $NVIM_TMUX_STATE_DIR/state.json` -- pipe to `jq` as before.
# Exported so `run bash -c "state_dump | jq ..."` finds it in the
# subshell.
state_dump() {
  remote_expr "json_encode(get(g:, 'nvim_tmux', {}))"
}
export -f state_dump remote_expr

# Drive a method on the lua state module against the test nvim,
# bypassing the shim. Args after the method are wrapped as vim string
# literals.
nt_state() {
  local method="$1"; shift
  local args=()
  local a
  for a in "$@"; do
    local esc="${a//\'/\'\'}"
    args+=("'${esc}'")
  done
  local IFS=,
  remote_expr "v:lua.require'nvim-tmux'.${method}(${args[*]})"
}
