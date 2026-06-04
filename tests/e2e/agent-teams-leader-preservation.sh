#!/usr/bin/env bash
#
# End-to-end: simulate Claude 2.1.114's external-mode Agent Teams flow
# faithfully and verify the bugs we've hit stay fixed:
#
#   * First teammate's send-keys MUST NOT replace the leader's terminal
#     buffer. (This was the "first spawn replaced the first view"
#     regression.)
#   * Each teammate pane gets a distinct nvim buffer + terminal job
#     channel. (Prevents teammates from pointing at the same chan_id.)
#   * When the process inside a teammate :terminal exits naturally
#     (user types `exit`), the TermClose autocmd wipes the buffer and
#     the window collapses. No "[Process exited]" residue.
#
# All shim invocations include `-L claude-swarm` (Claude's global-flag
# shape) to exercise the dispatcher's global-flag stripper.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SHIM="$REPO_ROOT/bin/tmux"

if [[ -n "${NVIM_TMUX_NVIM_BIN:-}" ]]; then
  NVIM_BIN="$NVIM_TMUX_NVIM_BIN"
elif [[ -x /opt/homebrew/bin/nvim ]]; then
  NVIM_BIN=/opt/homebrew/bin/nvim
else
  NVIM_BIN=$(command -v nvim || true)
fi
[[ -n "$NVIM_BIN" && -x "$NVIM_BIN" ]] || { echo "SKIP: no nvim" >&2; exit 0; }
export NVIM_TMUX_NVIM_BIN="$NVIM_BIN"

TEST_TMP=$(mktemp -d -t nt-leader-e2e.XXXXXX)
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

"$NVIM_BIN" --headless --listen "$SOCK" --clean >/dev/null 2>&1 &
NVIM_PID=$!
export NVIM="$SOCK"
unset NVIM_LISTEN_ADDRESS

waited=0
while [[ ! -S "$SOCK" ]]; do
  ((waited >= 3000)) && { echo "FAIL: nvim socket did not appear" >&2; exit 1; }
  sleep 0.05
  waited=$((waited + 50))
done

remote_expr() {
  "$NVIM_BIN" --headless --server "$SOCK" --remote-expr "$1" </dev/null
}

state_dump() {
  "$NVIM_BIN" --headless --server "$SOCK" --remote-expr "json_encode(get(g:, 'nvim_tmux', {}))" </dev/null
}

pass() { printf 'ok   [%s] -> %s\n' "$1" "$2"; }
fail() { printf 'FAIL [%s] want=%q got=%q\n' "$1" "$2" "$3" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] && pass "$3" "$1" || fail "$3" "$1" "$2"; }
assert_ne() {
  [[ "$1" != "$2" ]] && pass "$3" "($1 != $2)" || fail "$3" "(distinct)" "(both=$1)"
}

# Open a dummy :terminal in the leader window first (like real nvim
# after `:terminal` was run manually by the user). This gives us a
# real leader bufnr we can watch for stomping.
echo "=== Leader bootstrap: :terminal inside nvim"
"$NVIM_BIN" --headless --server "$SOCK" --remote-expr "execute('terminal')" </dev/null >/dev/null
leader_winid_pre=$(remote_expr "win_getid()")
leader_bufnr_pre=$(remote_expr "bufnr('%')")
pass "leader winid"  "$leader_winid_pre"
pass "leader bufnr"  "$leader_bufnr_pre"

echo
echo "=== 1. tmux -L claude-swarm new-session (external mode)"
leader_pane=$("$SHIM" -L claude-swarm new-session -d -s claude-swarm -n swarm-view -P -F '#{pane_id}')
assert_eq "2:0.0" "$leader_pane" "new-session pane id"
# list-panes with NAME-based target (Claude's exact shape)
panes=$("$SHIM" -L claude-swarm list-panes -t "claude-swarm:swarm-view" -F '#{pane_id}' | tr '\n' ' ')
assert_eq "2:0.0 " "$panes" "list-panes (name-based target)"

echo
echo "=== 2. display-message #{window_panes} on the swarm (first-teammate branch)"
count=$("$SHIM" -L claude-swarm display-message -t "claude-swarm:swarm-view" -p '#{window_panes}')
assert_eq "1" "$count" "pane count"

echo
echo "=== 3. setPaneTitle + first send-keys -- leader buffer must NOT be replaced"
"$SHIM" -L claude-swarm select-pane -t "2:0.0" -T "teammate-foo"
"$SHIM" -L claude-swarm send-keys  -t "2:0.0" 'echo' Space 'teammate-foo-running' Enter
sleep 0.3

# Inspect the leader window: same bufnr as before?
leader_bufnr_post=$(remote_expr "winbufnr(${leader_winid_pre})")
assert_eq "$leader_bufnr_pre" "$leader_bufnr_post" "leader bufnr unchanged"

# Teammate got its own window, buffer, and chan_id?
tm1_bufnr=$(state_dump | jq -r '.panes["2:0.0"].nvim_bufnr')
tm1_chan=$(state_dump | jq -r '.panes["2:0.0"].nvim_chan_id')
tm1_winid=$(state_dump | jq -r '.panes["2:0.0"].nvim_winid')
assert_ne "$tm1_bufnr" "$leader_bufnr_pre" "teammate bufnr distinct from leader"
assert_ne "$tm1_winid" "$leader_winid_pre" "teammate winid distinct from leader"
[[ "$tm1_chan" =~ ^[0-9]+$ ]] || fail "teammate chan_id numeric" "^[0-9]+\$" "$tm1_chan"
pass "teammate chan_id" "$tm1_chan"

# Teammate output visible in its OWN buffer?
tm1_buf=$(remote_expr "join(getbufline(${tm1_bufnr}, 1, '\$'), '\n')")
[[ "$tm1_buf" == *"teammate-foo-running"* ]] && pass "teammate buffer content" "contains echo output" \
  || fail "teammate buffer content" "echo" "$tm1_buf"

# Leader buffer should NOT have teammate-foo-running in it.
leader_buf=$(remote_expr "join(getbufline(${leader_bufnr_pre}, 1, '\$'), '\n')")
[[ "$leader_buf" != *"teammate-foo-running"* ]] && pass "leader buffer clean" "no teammate echo" \
  || fail "leader buffer clean" "no echo" "$leader_buf"

echo
echo "=== 4. Second teammate via split-window (fromClaude's else branch)"
tm2=$("$SHIM" -L claude-swarm split-window -t "2:0.0" -h -P -F '#{pane_id}')
assert_eq "2:0.1" "$tm2" "teammate-2 pane id"
"$SHIM" -L claude-swarm select-pane -t "$tm2" -T "teammate-bar"
"$SHIM" -L claude-swarm send-keys  -t "$tm2" 'echo' Space 'teammate-bar-running' Enter
sleep 0.3

tm2_bufnr=$(state_dump | jq -r '.panes["2:0.1"].nvim_bufnr')
tm2_chan=$(state_dump | jq -r '.panes["2:0.1"].nvim_chan_id')
assert_ne "$tm2_bufnr" "$tm1_bufnr" "teammate-2 bufnr != teammate-1"
assert_ne "$tm2_chan"  "$tm1_chan"  "teammate-2 chan_id != teammate-1"

tm2_buf=$(remote_expr "join(getbufline(${tm2_bufnr}, 1, '\$'), '\n')")
[[ "$tm2_buf" == *"teammate-bar-running"* ]] && pass "teammate-2 buffer content" "contains its echo" \
  || fail "teammate-2 buffer content" "echo" "$tm2_buf"

echo
echo "=== 5. Window count: leader + two teammates = 3"
wincount=$(remote_expr "winnr('\$')")
assert_eq "3" "$wincount" "3 nvim windows"

echo
echo "=== 6. 'exit' in teammate-1 -- TermClose autocmd wipes the buffer"
"$SHIM" -L claude-swarm send-keys -t "2:0.0" 'exit' Enter
# Give the shell / autocmd time to fire.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  present=$(remote_expr "bufexists(${tm1_bufnr})")
  [[ "$present" == "0" ]] && break
  sleep 0.2
done
assert_eq "0" "$present" "teammate-1 buffer deleted on exit"

wincount_after_exit=$(remote_expr "winnr('\$')")
assert_eq "2" "$wincount_after_exit" "down to 2 windows after natural exit"

echo
echo "=== 7. kill-pane on teammate-2 -- forced buffer delete + window collapse"
"$SHIM" -L claude-swarm kill-pane -t "$tm2"
present_tm2=$(remote_expr "bufexists(${tm2_bufnr})")
assert_eq "0" "$present_tm2" "teammate-2 buffer deleted on kill-pane"
wincount_after_kill=$(remote_expr "winnr('\$')")
assert_eq "1" "$wincount_after_kill" "just the leader remaining"

# Sanity: leader still alive and its buffer still the original bufnr.
leader_bufnr_final=$(remote_expr "winbufnr(${leader_winid_pre})")
assert_eq "$leader_bufnr_pre" "$leader_bufnr_final" "leader still intact at end"

echo
echo "=== PASS: leader preserved across full Agent Teams lifecycle"
