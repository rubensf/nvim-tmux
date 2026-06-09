#!/usr/bin/env bats

# Integration tests for tmux send-keys + auto-spawned :terminal.
# Drives the full stack against a real headless nvim.

load _setup

setup() {
  nt_int_setup
  "$SHIM" new-session -d -s swarm >/dev/null
  "$SHIM" split-window -t "2:0.0" -h >/dev/null         # creates pane 2:0.1
}

teardown() { nt_int_teardown; }

@test "first send-keys auto-spawns a :terminal and records chan_id" {
  run bash -c "state_dump | jq -r '.panes[\"2:0.1\"].nvim_chan_id'"
  [ "$output" = "null" ]

  "$SHIM" send-keys -t "2:0.1" 'echo' Space 'hello' Enter
  run bash -c "state_dump | jq -r '.panes[\"2:0.1\"].nvim_chan_id'"
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "send-keys produces output in the terminal buffer" {
  "$SHIM" send-keys -t "2:0.1" 'echo' Space 'send-keys-works' Enter
  sleep 0.3
  local bufnr content
  bufnr=$(state_dump | jq -r '.panes["2:0.1"].nvim_bufnr')
  content=$(remote_expr "join(getbufline(${bufnr}, 1, '\$'), '\n')")
  [[ "$content" == *"send-keys-works"* ]]
}

@test "send-keys reuses the same chan_id across multiple calls" {
  "$SHIM" send-keys -t "2:0.1" 'echo' Space 'one' Enter
  local first second
  first=$(state_dump | jq -r '.panes["2:0.1"].nvim_chan_id')
  "$SHIM" send-keys -t "2:0.1" 'echo' Space 'two' Enter
  second=$(state_dump | jq -r '.panes["2:0.1"].nvim_chan_id')
  [ "$first" = "$second" ]
}

@test "send-keys Enter alone emits a newline" {
  "$SHIM" send-keys -t "2:0.1" Enter
  run bash -c "state_dump | jq -r '.panes[\"2:0.1\"].nvim_chan_id'"
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "send-keys rejects unknown key literals" {
  run "$SHIM" send-keys -t "2:0.1" Tab
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported key literal"* ]]
}

@test "send-keys with a bad literal does not leave a terminal behind" {
  local wins_before
  wins_before=$(remote_expr "winnr('\$')")
  run "$SHIM" send-keys -t "2:0.1" Tab
  [ "$status" -ne 0 ]
  # No channel recorded, no extra window materialized.
  run bash -c "state_dump | jq -r '.panes[\"2:0.1\"].nvim_chan_id'"
  [ "$output" = "null" ]
  [ "$(remote_expr "winnr('\$')")" = "$wins_before" ]
}

@test "natural terminal exit removes the pane from state" {
  "$SHIM" send-keys -t "2:0.1" 'exit' Enter
  # TermClose cleanup is deferred onto nvim's event loop; poll for it.
  local waited=0
  while state_dump | jq -e '.panes["2:0.1"]' >/dev/null 2>&1; do
    ((waited >= 5000)) && break
    sleep 0.1
    waited=$((waited + 100))
  done
  run bash -c "state_dump | jq '.panes | has(\"2:0.1\")'"
  [ "$output" = "false" ]
  run "$SHIM" list-panes -t "swarm:0" -F '#{pane_id}'
  [[ "$output" != *"2:0.1"* ]]
}

@test "send-keys -l (literal mode) errors" {
  run "$SHIM" send-keys -t "2:0.1" -l 'x'
  [ "$status" -ne 0 ]
  [[ "$output" == *"-l"* ]]
}

@test "send-keys against unknown pane errors" {
  run "$SHIM" send-keys -t "99:9.9" 'x' Enter
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown pane"* ]]
}

@test "send-keys without -t errors" {
  run "$SHIM" send-keys 'echo' Enter
  [ "$status" -ne 0 ]
  [[ "$output" == *"-t"* ]]
}

@test "send-keys with no tokens errors" {
  run "$SHIM" send-keys -t "2:0.1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"token"* ]]
}

@test "send-keys recovers when the pane's window was closed behind the shim's back" {
  # Simulate the user :close-ing the split between split-window and the
  # first send-keys. open_terminal must NOT clobber the current window;
  # it should materialize a fresh split and rebind state.
  local stale leader_buf_before
  stale=$(state_dump | jq -r '.panes["2:0.1"].nvim_winid')
  remote_expr "nvim_win_close(${stale}, v:true)" >/dev/null
  leader_buf_before=$(remote_expr "winbufnr(win_getid())")

  "$SHIM" send-keys -t "2:0.1" 'echo' Space 'recovered' Enter

  # State rebound to a live window distinct from the stale id.
  local rebound
  rebound=$(state_dump | jq -r '.panes["2:0.1"].nvim_winid')
  [ "$rebound" != "$stale" ]
  [ "$(remote_expr "win_id2win(${rebound})")" != "0" ]
  # The previously-current window's buffer was not replaced.
  [ "$(remote_expr "bufexists(${leader_buf_before})")" = "1" ]
}
