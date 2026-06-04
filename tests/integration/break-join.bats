#!/usr/bin/env bats

# Integration tests for break-pane + join-pane against a real headless
# nvim. Key correctness criterion: the :terminal process survives the
# hide/restore cycle -- the buffer's chan_id stays the same.

load _setup

setup() {
  nt_int_setup
  # Two-pane session, the second running a :terminal.
  "$SHIM" new-session -d -s swarm >/dev/null
  "$SHIM" split-window -t "2:0.0" -h >/dev/null
  "$SHIM" send-keys -t "2:0.1" 'echo' Space 'before-hide' Enter
  sleep 0.3
}

teardown() { nt_int_teardown; }

@test "break-pane closes the nvim window but keeps the :terminal buffer alive" {
  local bufnr_before chan_before win_count_before
  bufnr_before=$(state_dump | jq -r '.panes["2:0.1"].nvim_bufnr')
  chan_before=$(state_dump | jq -r '.panes["2:0.1"].nvim_chan_id')
  win_count_before=$(remote_expr "winnr('\$')")

  # Claude's hidePane sequence: create the hidden holding session first.
  "$SHIM" new-session -d -s stash >/dev/null
  "$SHIM" break-pane -d -s "2:0.1" -t "stash:"

  local win_count_after still_alive chan_after
  win_count_after=$(remote_expr "winnr('\$')")
  [ "$win_count_after" -lt "$win_count_before" ]

  still_alive=$(remote_expr "bufexists(${bufnr_before})")
  [ "$still_alive" = "1" ]
  chan_after=$(remote_expr "getbufvar(${bufnr_before}, 'terminal_job_id')")
  [ "$chan_after" = "$chan_before" ]

  # State hides the pane in place: record stays in its origin slot,
  # flagged hidden, and disappears from list-panes.
  run bash -c "state_dump | jq -r '.panes[\"2:0.1\"].hidden'"
  [ "$output" = "true" ]
  run bash -c "state_dump | jq -r '.panes[\"2:0.1\"].hidden_session'"
  [ "$output" = "stash" ]
  run "$SHIM" list-panes -t "swarm:0"
  [ "$output" = "2:0.0" ]
}

@test "join-pane restores the hidden buffer into a fresh split" {
  local bufnr chan
  bufnr=$(state_dump | jq -r '.panes["2:0.1"].nvim_bufnr')
  chan=$(state_dump | jq -r '.panes["2:0.1"].nvim_chan_id')

  "$SHIM" new-session -d -s stash >/dev/null
  "$SHIM" break-pane -d -s "2:0.1" -t "stash:"

  # Create a second live window to restore into.
  "$SHIM" new-window -t swarm -n workspace >/dev/null  # gives 2:1.0

  # Real tmux join-pane is silent without -P; ours must be too.
  run "$SHIM" join-pane -h -s "2:0.1" -t "swarm:workspace"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$SHIM" list-panes -t "swarm:workspace"
  [[ "$output" == *"2:1.1"* ]]

  run bash -c "state_dump | jq -r '.panes[\"2:1.1\"].nvim_bufnr'"
  [ "$output" = "$bufnr" ]
  run bash -c "state_dump | jq -r '.panes[\"2:1.1\"].nvim_chan_id'"
  [ "$output" = "$chan" ]

  local new_winid buf_in_win
  new_winid=$(state_dump | jq -r '.panes["2:1.1"].nvim_winid')
  buf_in_win=$(remote_expr "winbufnr(${new_winid})")
  [ "$buf_in_win" = "$bufnr" ]

  # The origin slot is vacated by the join.
  run bash -c "state_dump | jq -r '.panes[\"2:0.1\"]'"
  [ "$output" = "null" ]
}

@test "break-pane without -s errors" {
  run "$SHIM" break-pane -d -t "stash:"
  [ "$status" -ne 0 ]
  [[ "$output" == *"-s"* ]]
}

@test "break-pane without -t errors" {
  run "$SHIM" break-pane -d -s "2:0.1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"-t"* ]]
}

@test "join-pane without -s errors" {
  run "$SHIM" join-pane -h -t "swarm:0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"-s"* ]]
}

@test "join-pane with unknown hidden pane errors" {
  "$SHIM" new-session -d -s stash >/dev/null
  run "$SHIM" join-pane -h -s "99:9.9" -t "swarm:0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no preserved buffer"* ]]
}

@test "join-pane with session-only target errors without orphaning a window" {
  "$SHIM" new-session -d -s stash >/dev/null
  "$SHIM" break-pane -d -s "2:0.1" -t "stash:"
  local wins_before
  wins_before=$(remote_expr "winnr('\$')")
  # "swarm:" has no window component -- must fail BEFORE any split.
  run "$SHIM" join-pane -h -s "2:0.1" -t "swarm:"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown target window"* ]]
  [ "$(remote_expr "winnr('\$')")" = "$wins_before" ]
}
