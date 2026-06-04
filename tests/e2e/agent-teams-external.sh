#!/usr/bin/env bash
#
# End-to-end smoke test for the "external" Agent Teams flow.
#
# Simulates the tmux subcommand sequence Claude 2.1.114 issues when it
# detects no ambient $TMUX and must bootstrap its own session:
#
#   new-session -d -s claude-swarm-view -n leader -P -F '#{pane_id}'
#   send-keys   -t <leader>   'leader-init'   Enter
#   split-window -t <leader>  -h -P -F '#{pane_id}'
#   send-keys   -t <teammate> 'teammate-1'    Enter
#   (repeat split + send for teammate-2)
#   select-layout -t claude-swarm-view:0 main-vertical
#   list-panes
#   kill-pane   -t <teammate-1>
#
# This script spawns a headless nvim as the target, drives bin/tmux
# against it, and asserts observable state after each step.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SHIM="$REPO_ROOT/bin/tmux"

# Resolve the real nvim binary (bypass any fish/zsh wrappers).
if [[ -n "${NVIM_TMUX_NVIM_BIN:-}" ]]; then
  NVIM_BIN="$NVIM_TMUX_NVIM_BIN"
elif [[ -x /opt/homebrew/bin/nvim ]]; then
  NVIM_BIN=/opt/homebrew/bin/nvim
else
  NVIM_BIN=$(command -v nvim || true)
fi
if [[ -z "$NVIM_BIN" || ! -x "$NVIM_BIN" ]]; then
  echo "SKIP: no nvim binary found" >&2
  exit 0
fi
export NVIM_TMUX_NVIM_BIN="$NVIM_BIN"

TEST_TMP=$(mktemp -d -t nt-e2e.XXXXXX)
SOCK="$TEST_TMP/nvim.sock"

cleanup() {
  if [[ -n "${NVIM_PID:-}" ]] && kill -0 "$NVIM_PID" 2>/dev/null; then
    "$NVIM_BIN" --server "$SOCK" --remote-expr "execute('qa!')" >/dev/null 2>&1 || true
    sleep 0.1
    kill "$NVIM_PID" 2>/dev/null || true
    wait "$NVIM_PID" 2>/dev/null || true
  fi
  [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# --- Spawn target nvim ---------------------------------------------------

"$NVIM_BIN" --headless --listen "$SOCK" --clean >/dev/null 2>&1 &
NVIM_PID=$!
export NVIM="$SOCK"
unset NVIM_LISTEN_ADDRESS

waited=0
while [[ ! -S "$SOCK" ]]; do
  if ((waited >= 3000)); then
    echo "FAIL: nvim socket did not appear in 3s" >&2
    exit 1
  fi
  sleep 0.05
  waited=$((waited + 50))
done

remote_expr() {
  "$NVIM_BIN" --headless --server "$SOCK" --remote-expr "$1" </dev/null
}

state_dump() {
  "$NVIM_BIN" --headless --server "$SOCK" --remote-expr "json_encode(get(g:, 'nvim_tmux', {}))" </dev/null
}

assert_eq() {
  local want="$1" got="$2" label="$3"
  if [[ "$want" != "$got" ]]; then
    echo "FAIL [$label]: want='$want' got='$got'" >&2
    exit 1
  fi
  echo "ok [$label] -> $got"
}

assert_contains() {
  local needle="$1" haystack="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL [$label]: '$haystack' does not contain '$needle'" >&2
    exit 1
  fi
  echo "ok [$label] -> contains '$needle'"
}

# --- Agent Teams flow ----------------------------------------------------

echo
echo "=== 1. new-session claude-swarm-view"
leader_pane=$("$SHIM" new-session -d -s claude-swarm-view -n leader -P -F '#{pane_id}')
assert_eq "2:0.0" "$leader_pane" "leader pane id"

echo
echo "=== 2. send-keys to leader (auto-spawns :terminal on first send)"
"$SHIM" send-keys -t "$leader_pane" 'echo' Space 'leader-init' Enter
sleep 0.3
leader_bufnr=$(state_dump | jq -r '.panes["2:0.0"].nvim_bufnr')
leader_buf=$(remote_expr "join(getbufline(${leader_bufnr}, 1, '\$'), '\n')")
assert_contains "leader-init" "$leader_buf" "leader buffer sees echo output"

echo
echo "=== 3. split + send two teammates"
tm1=$("$SHIM" split-window -t "$leader_pane" -h -P -F '#{pane_id}')
assert_eq "2:0.1" "$tm1" "teammate-1 pane id"
"$SHIM" send-keys -t "$tm1" 'echo' Space 'teammate-1' Enter

tm2=$("$SHIM" split-window -t "$leader_pane" -h -P -F '#{pane_id}')
assert_eq "2:0.2" "$tm2" "teammate-2 pane id"
"$SHIM" send-keys -t "$tm2" 'echo' Space 'teammate-2' Enter

sleep 0.3
tm1_bufnr=$(state_dump | jq -r '.panes["2:0.1"].nvim_bufnr')
tm1_buf=$(remote_expr "join(getbufline(${tm1_bufnr}, 1, '\$'), '\n')")
assert_contains "teammate-1" "$tm1_buf" "teammate-1 buffer sees its echo"

tm2_bufnr=$(state_dump | jq -r '.panes["2:0.2"].nvim_bufnr')
tm2_buf=$(remote_expr "join(getbufline(${tm2_bufnr}, 1, '\$'), '\n')")
assert_contains "teammate-2" "$tm2_buf" "teammate-2 buffer sees its echo"

echo
echo "=== 4. select-layout main-vertical (equalizes; 3 windows remain)"
"$SHIM" select-layout -t claude-swarm-view:0 main-vertical
wincount=$(remote_expr "winnr('\$')")
# 4 = leader + one materialized window per of {2:0.0, 2:0.1, 2:0.2}.
# Each pane gets its own nvim window when its :terminal spawns.
assert_eq "4" "$wincount" "4 nvim windows after layout"

echo
echo "=== 5. list-panes enumerates all three"
panes=$("$SHIM" list-panes -t claude-swarm-view:0 -F '#{pane_id}' | tr '\n' ' ')
assert_eq "2:0.0 2:0.1 2:0.2 " "$panes" "list-panes output"

echo
echo "=== 6. kill-pane teammate-1"
"$SHIM" kill-pane -t "$tm1"
wincount=$(remote_expr "winnr('\$')")
# 4 -> 3 after killing teammate-1's :terminal window.
assert_eq "3" "$wincount" "3 nvim windows after kill"
state_tm1=$(state_dump | jq -r '.panes["2:0.1"]')
assert_eq "null" "$state_tm1" "teammate-1 pruned from state"

echo
echo "=== 7. kill-pane idempotent"
"$SHIM" kill-pane -t "$tm1"
echo "ok [idempotent kill returned 0]"

echo
echo "=== 8. has-session positive"
if "$SHIM" has-session -t claude-swarm-view; then
  echo "ok [has-session -t claude-swarm-view exits 0]"
else
  echo "FAIL: has-session should find claude-swarm-view"
  exit 1
fi

echo
echo "=== 9. has-session negative"
if ! "$SHIM" has-session -t ghost 2>/dev/null; then
  echo "ok [has-session -t ghost exits non-zero]"
else
  echo "FAIL: has-session ghost should not exist"
  exit 1
fi

echo
echo "=== PASS: Agent Teams external-mode smoke test"
