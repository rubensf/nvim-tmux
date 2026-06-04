# Contracts

Authoritative cross-module interfaces. Any change to this file is a deliberate act that all dependent modules must pick up in the same merge.

The two modules: `bin/tmux` (bash — argv parsing, one RPC per subcommand) and `lua/nvim-tmux/init.lua` (Lua, running inside the target nvim — state, window/terminal actions, plugin setup). `plugin/nvim-tmux.lua` is a 14-line auto-load stub.

## 1. State Schema

**Owner:** the state section of `lua/nvim-tmux/init.lua`.
**Location:** `vim.g.nvim_tmux` inside the target nvim — in-memory only. No file, no locks, no PID discovery. State scopes to the nvim instance, is mutated atomically per RPC call (nvim's event loop is single-threaded; each Lua call runs to completion), and vanishes when nvim exits — by design; the shim does not promise survival across restarts.

**The store is FLAT — ids double as table keys:**

```
{
  next_session_idx = 2,        -- monotonic; first user session gets idx 2
  leader_winid     = <int>,    -- cached on first use via win_getid()
  sessions = { [name]    = { idx = <int>, next_window = <int> } },
  windows  = { ["S:W"]   = { name = <string>, next_pane = <int> } },
  panes    = { ["S:W.P"] = { nvim_winid, nvim_bufnr, nvim_chan_id,
                             hidden, hidden_session } },
}
```

**Keys:**

- `sessions[name]` — keyed by the tmux session name Claude used (e.g. `"claude-swarm-view"`). `idx` is the numeric prefix used in pane ids.
- `windows["S:W"]` — keyed by `<session.idx>:<window.idx>`. Window indices start at 0.
- `panes["S:W.P"]` — keyed by the full pane id. Per-pane fields:
  - `nvim_winid` — nvim window id, or `vim.NIL` before a window is bound.
  - `nvim_bufnr` — nvim buffer number, or `vim.NIL` before `:terminal` spawns.
  - `nvim_chan_id` — terminal job channel id (the `chansend` target), or `vim.NIL`.
  - `hidden` — `true` after `break-pane`; the record stays under its origin id (no cross-key move) and `list_panes`/`count_panes` skip it.
  - `hidden_session` — the `break-pane -t` destination name while hidden, else `vim.NIL`.

**Invariants:**

- The pane id encodes the hierarchy: `"S:W.P"` = session idx `S`, window idx `W`, pane idx `P`. The leader pane is the constant `1:0.0`.
- Counters (`next_session_idx`, `next_window`, `next_pane`) are monotonic — indices are **never reused**, even after kill.
- Mutations read `vim.g.nvim_tmux` into a local, mutate, and assign the whole table back. Nested writes (`vim.g.nvim_tmux.panes[...] = ...`) do **not** persist.
- Empty windows/sessions cascade-delete when their last pane is removed (kill, or join vacating the origin).
- Unset fields are `vim.NIL` (renders as `null` in `json_encode` dumps), not omitted.

**Nvim bindings** (`nvim_winid`, `nvim_bufnr`, `nvim_chan_id`) are real nvim ids — not opaque handles we mint ourselves.

## 2. Bash ⇄ Lua RPC Surface

Everything bash sends to nvim is one vim expression evaluated via the single transport function:

```bash
# Evaluate a vim expression in the target nvim; result on stdout.
nvim_expr() {
  local expr="${1:?nvim_expr: expr required}"
  "$(_nvim_bin)" --headless --server "$(nvim_socket)" \
    --remote-expr "$expr" </dev/null
}
```

Subcommands route through `_lua_call METHOD ARGS...`, which quotes each arg as a vim string literal (single-quote doubling) and evaluates `v:lua.require'nvim-tmux'.METHOD(...)` — **one RPC round-trip per tmux subcommand**. The repo is lazily appended to the target nvim's runtimepath on the first call (`_lua_ensure_rtp`, via `luaeval` with the path in the `_A` argument).

**Lua methods bash calls** (all take/return strings; lists are `\n`-joined):

| Method | Called by | Effect / return |
| :--- | :--- | :--- |
| `has_session(name)` | `has-session` | boolean |
| `create_session(name, window_name)` | `new-session` | new pane id |
| `create_window(session, window_name)` | `new-window` | new pane id |
| `count_panes(session_ref, window_ref)` | `display-message '#{window_panes}'` | integer (skips hidden) |
| `list_sessions(field)` | `list-sessions` | names / `$N` ids / name-with-count lines |
| `list_windows(session_ref, field)` | `list-windows` | names / `S:W` ids |
| `list_panes(session_ref, window_ref)` | `list-panes` | pane ids (skips hidden) |
| `split_window(parent_pid, h\|v, size_pct)` | `split-window` | new pane id; splits + binds |
| `kill_pane(pid)` | `kill-pane` | wipes terminal buffer / closes window; idempotent |
| `select_pane(pid, title)` | `select-pane` | focuses window; sets winbar title |
| `resize_pane(pid, width_pct)` | `resize-pane` | width = pct of `&columns` |
| `select_layout()` | `select-layout` | `wincmd =` (all layouts equalize) |
| `send_keys(pid, tokens...)` | `send-keys` | translates tokens, `chansend`; auto-spawns `:terminal` on first contact |
| `break_pane(pid, dest)` | `break-pane` | hides in place; closes window, keeps buffer+job |
| `join_pane(hidden_pid, target, h\|v)` | `join-pane` | validates target *before* mutating; splits, loads preserved buffer, moves record to new id |

`session_ref` resolves by name or numeric idx (`"2"` / `"$2"`). `window_ref` resolves by window index or window name.

**Bash-side conventions** (`bin/tmux`):
- `state_leader_pane` is hardcoded `1:0.0` — no RPC.
- Boolean results (`v:true`/`v:false`/`1`) map to exit codes via `_state_call_bool`, which **dies on RPC failure** rather than reading transport errors as `false` (callers sit inside `if` conditions, where `set -e` is suspended).
- List wrappers re-add the trailing newline the Lua side omits.

**Socket discovery:** `$NVIM` (auto-exported by nvim into `:terminal` children), `$NVIM_LISTEN_ADDRESS` as the pre-0.7 fallback. Nothing else — no socket scanning.

**Why `--headless </dev/null`:** invoked under a pty (inside `:terminal`), the nvim CLI emits terminal-capability probes (`\x1b[?1049h`…) on stdout that corrupt `$(nvim_expr …)` captures. `--headless` + stdin-from-/dev/null forces non-interactive behavior.

**`NVIM_TMUX_NVIM_BIN`:** points at the real nvim binary (the plugin sets it to `vim.v.progpath`); protects against `nvr`-style wrapper scripts on `PATH`. Default: `nvim`.

## 3. Nvim-side Operation Semantics

What each tmux subcommand does to the editor. Implemented in the actions section of `lua/nvim-tmux/init.lua` via `vim.fn` / `vim.api` / `vim.cmd`.

- **`split-window -h|-v [-l N%]`** — focus parent window, measure its width/height **before** splitting (vim halves the parent on `:vsplit`), `:vsplit`/`:split`, optional `vertical resize`/`resize` to N% of the pre-split dimension, bind the new winid. tmux `-h` (side-by-side) = vim `:vsplit`.
- **`kill-pane`** — if the pane has a live `:terminal`, `nvim_buf_delete(bufnr, force)` (kills the job AND every window showing it — no `[Process exited]` residue); else close the bound window if it still exists. Idempotent.
- **`select-pane [-T title]`** — `win_gotoid`; title goes to the window's `'winbar'`. `-P` styling is a validated no-op.
- **`resize-pane -x N%`** — `nvim_win_set_width(winid, floor(&columns * N / 100))`.
- **`select-layout <any supported name>`** — `wincmd =`. Structural shape matters to Claude; visual fidelity does not.
- **Terminal spawn** — first `send-keys` against a pane without a `chan_id` runs `:terminal` (in the pane's bound window if it's still alive; otherwise a fresh vsplit off the leader — never the current window blind), grabs `terminal_job_id`, and registers a `TermClose` autocmd that wipes the buffer via deferred `nvim_buf_delete` (deferral avoids E937 from deleting mid-TermClose).
- **`send-keys`** — translate tokens (§4), concatenate, `nvim_chan_send(chan_id, bytes)`.
- **`break-pane`** — record stays in state under its id with `hidden=true`; the nvim window closes but the buffer and job survive for a later join.
- **`join-pane`** — validate the hidden pane AND the target window **before any window mutation** (a post-split failure would orphan an unbound window); then split off a window in the target, `:buffer <preserved bufnr>`, move the state record to its new id, rebind.
- **Cosmetic no-ops** — `set-option` (all shapes): exit 0, no nvim call.

## 4. `send-keys` Input Grammar

`send-keys -t <target> <tokens...>`; MVP-relevant subset:

- Ordinary string tokens are concatenated as-is (no separator).
- `Enter` → **`\r` (0x0D)** — readline treats CR as submit, not LF.
- `Space` → `" "`, `C-c` → `\x03`, `C-d` → `\x04`.
- Any other token matching `^[A-Z][-A-Za-z0-9]+$` (tmux key-name shape) → error `send-keys: unsupported key literal '<name>'`.
- Everything else passes through literally.
- `-l` (literal mode) is out of scope — errors out.

## 5. Stderr / Exit Codes

**Stderr prefix:** user-facing errors `nvim-tmux: <msg>`.

**Exit codes:**
- `0` — success.
- `1` — any failure (malformed args, nvim unreachable, unknown subcommand, unsupported key literal, …).
- `2` — reserved for a future "tmux would have exited this way" distinction if needed.

**Output discipline:** subcommands print only what real tmux would. `-P -F '#{pane_id}'` shapes print the id; everything else mutating is silent on success.

## 6. Version Compatibility

`tmux -V` returns `tmux 3.0 (nvim-tmux v<SEMVER>)` where `<SEMVER>` is read from the top-level `VERSION` file. The `tmux 3.0` prefix is what Claude's pre-launch probe parses — it is load-bearing. `-V` must work without a live nvim.

Bash 3.2 (macOS `/bin/bash`) is the floor for the bash side — no `mapfile`, no empty-array expansion under `set -u` without a `-` default. Nvim ≥ 0.9 is assumed but not asserted — older nvims fail at the first missing-API call.

Claude binary compatibility target: 2.1.114–2.1.118 (audited call surface). Newer Claude versions may introduce new tmux calls; the shim fails loudly on unknown subcommands so drift is visible.
