---
name: nvim-tmux
description: How the nvim-tmux shim works -- setup (Claude config + plugin install), architecture, and how to investigate / debug it when Agent Teams, split-window, send-keys, or terminal spawn misbehaves. Invoke when the user asks how to install or configure nvim-tmux, reports errors prefixed with `nvim-tmux:`, when shim subcommands error or hang, when nvim windows don't appear where expected, or when Claude's tmux call surface behaves differently than documented.
---

# nvim-tmux shim — setup, architecture, debug runbook

You are working on **nvim-tmux**: a bash executable installed as `tmux` on PATH that impersonates the tmux subcommands Claude Code 2.1.x invokes, but drives **Neovim splits** via `nvim --server ... --remote-expr` instead of a real tmux server. Claude launches from inside a nvim `:terminal`; `$NVIM` is auto-inherited; teammate agents appear as real nvim windows.

This skill is your runbook both for getting a user set up AND for diagnosing failures once they are.

## Setup (when the user is installing fresh)

### Step 1 — enable Agent Teams

**`~/.claude/settings.json`** (user-global) — enable the experimental Agent Teams feature:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

Claude's teammate backend defaults to `"auto"` and picks tmux by itself when it finds `tmux` on `PATH` — no further config needed. If a user's Claude does NOT pick the tmux backend (teammates run in-process despite the shim being on PATH), force it in **`~/.claude.json`**:

```json
{
  "teammateMode": "tmux"
}
```

Restart `claude` for these to pick up.

### Step 2 — install the shim

Plugin-manager install only (lazy.nvim / dein / packer / mini.deps / rocks / native packages). The plugin auto-prepends its own `bin/` to `vim.env.PATH` on nvim startup, and sets `NVIM_TMUX_NVIM_BIN` to `vim.v.progpath` so the shim bypasses any `nvr`/fish wrapper that might sit on `PATH`.

```lua
-- lazy.nvim
{ "rubensf/nvim-tmux" }
```

```vim
" dein.vim
call dein#add('rubensf/nvim-tmux')
```

For private-repo installs, pass an SSH URL (`git@github.com:rubensf/nvim-tmux.git`) or set `g:dein#types#git#default_protocol = 'ssh'` globally (dein).

Opt out without uninstalling: `vim.g.nvim_tmux_disable = true`. Opt out of auto-`setup()` but call it manually with options: `vim.g.loaded_nvim_tmux = 1` then `require("nvim-tmux").setup({...})`.

### Step 3 — verify

```bash
# From inside nvim (:terminal):
which tmux           # should be <plugin-dir>/bin/tmux
tmux -V              # should print: tmux 3.0 (nvim-tmux v<semver>)
echo "$NVIM"         # non-empty: nvim's RPC socket
echo "$NVIM_TMUX_NVIM_BIN"   # the plugin sets this to vim.v.progpath
```

If any of these are wrong, jump to the "First step for any reported issue" section below.

### Pre-flight requirements

- macOS or Linux.
- Neovim ≥ 0.9 (not enforced -- older nvims fail at the first missing-API error).
- `bash` (3.2+ on macOS is fine), POSIX coreutils. (`jq` only for running the test suite.)
- No real tmux ahead of the shim on `PATH`.
- The `nvim` on `PATH` must be the real binary, OR `NVIM_TMUX_NVIM_BIN` must point at it. The plugin wrapper handles this automatically; standalone-CLI users with fish/zsh wrappers around `nvim` need to set `NVIM_TMUX_NVIM_BIN` themselves.

### Run order

1. `nvim` — launch as usual, no plugin init beyond the plugin-manager line.
2. `:terminal` — nvim spawns a child shell and sets `$NVIM` in its env.
3. `claude` — runs in that terminal, sees the shim on `PATH`, probes `tmux -V`, hands Agent Teams off to our impersonator.

## Architecture in one paragraph

`bin/tmux` is the entire bash side: it parses argv, strips tmux global flags, and routes each subcommand to a `cmd_*` handler that makes one `_lua_call <method>` RPC over the `nvim_expr` transport (`nvim --server $NVIM --remote-expr`). Everything else is `lua/nvim-tmux/init.lua`, one module with three sections: state bookkeeping in `vim.g.nvim_tmux` (flat maps keyed by id — `sessions[name]`, `windows["S:W"]`, `panes["S:W.P"]`; no on-disk state, instance-scoped, dies with nvim), the actions that translate each tmux subcommand into nvim window/buffer/job ops (split, kill, send-keys, break/join), and `setup()` which wires `vim.env.PATH` + `NVIM_TMUX_NVIM_BIN` for plugin-manager installs (auto-run by `plugin/nvim-tmux.lua`).

## Key files to read first

- `docs/CONTRACTS.md` — authoritative interface contracts: state schema (§1), bash⇄lua RPC surface (§2), nvim-side op semantics (§3), send-keys grammar (§4), stderr/exit conventions (§5).
- `bin/tmux` — the whole bash side: argv parsing + subcommand routing + `nvim_expr` transport + `_lua_call` dispatcher + `state_*` wrappers. Start here to trace which handler a failing invocation ran.
- `lua/nvim-tmux/init.lua` — the whole Lua side: state bookkeeping (source of truth for "which pane has which winid"), the pane/terminal actions, send-keys grammar, and setup().

Always grep the code path for the failing subcommand before guessing.

## Required runtime environment

The shim refuses to work unless these are set in the shell calling it. The plugin wrapper (if installed) handles `$PATH` and `$NVIM_TMUX_NVIM_BIN` automatically; the rest are either auto-set by nvim or optional.

| Variable | Source | Purpose |
| :--- | :--- | :--- |
| `$NVIM` | nvim (:terminal auto) | RPC socket of the target nvim. `$NVIM_LISTEN_ADDRESS` is the legacy fallback for nvim < 0.7. |
| `$PATH` | plugin | Must have the shim's `bin/` ahead of any real tmux. The plugin prepends via `vim.env.PATH`. |
| `$NVIM_TMUX_NVIM_BIN` | plugin auto-sets | Path to the real nvim binary (`vim.v.progpath`). Override by exporting it before nvim starts if you need a different binary. |

## First step for *any* reported issue

0. **Confirm the shim is even being called.** From inside `:terminal`:

   ```bash
   which tmux            # should resolve to <plugin>/bin/tmux
   tmux -V               # should print "tmux 3.0 (nvim-tmux v...)"
   ```

   If `which tmux` points at `/usr/local/bin/tmux` or `/opt/homebrew/bin/tmux`, the user has real tmux ahead of the shim on PATH — investigate why the plugin's `vim.env.PATH` prepend didn't take. Common causes:
   - Plugin not loaded yet: `:lua print(vim.g.loaded_nvim_tmux)` should print `1`. If `nil`, the plugin manager hasn't loaded `plugin/nvim-tmux.lua` (lazy-loaded on a non-existent event, missing rtp entry, …).
   - User set `vim.g.nvim_tmux_disable = true` and forgot.
   - `:terminal` was opened *before* the plugin loaded (lazy.nvim with `event = "VeryLazy"` and a too-early `:terminal`). Restart nvim and try again.

1. Dump the live state (lives in `vim.g.nvim_tmux` inside the target nvim):

   ```bash
   "$NVIM_TMUX_NVIM_BIN" --headless --server "$NVIM" \
     --remote-expr "json_encode(get(g:, 'nvim_tmux', {}))" </dev/null | jq .
   ```

   Compare the pane records to what the user observes in nvim. Mismatch between `nvim_winid` and reality = stale state or a failed binding.
2. Compare the shim's view to nvim's via `--remote-expr`:

   ```bash
   "$NVIM_TMUX_NVIM_BIN" --headless --server "$NVIM" --remote-expr 'win_getid()' </dev/null
   "$NVIM_TMUX_NVIM_BIN" --headless --server "$NVIM" --remote-expr "winnr('\$')" </dev/null
   ```

## Failure patterns you will see

### Claude says "Agent Teams is unavailable" / never shells out to tmux
First check the feature flag:

```bash
jq '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' ~/.claude/settings.json   # expect "1"
which tmux                                                               # expect the shim
```

The backend defaults to `"auto"` and picks tmux when the shim is on PATH. If the flag is on and the shim resolves but teammates still run in-process, force the backend: `jq '.teammateMode' ~/.claude.json` should be `"tmux"` — set it if absent. Restart `claude` after editing.

### `which tmux` returns the system tmux instead of the shim
The plugin's PATH prepend didn't run, or the `:terminal` was launched before the plugin loaded. See "First step 0" above. Quickest workaround: `:lua require("nvim-tmux").setup()` then re-open the `:terminal`.

### Plugin appears installed but `:lua print(vim.g.loaded_nvim_tmux)` is `nil`
`plugin/nvim-tmux.lua` never sourced. With dein, run `:call dein#recache_runtimepath()` and restart. With lazy.nvim, the plugin spec might have `lazy = true` plus a wrong trigger; remove it (let it auto-load).

### `nvim-tmux: unknown subcommand: <name>`
The dispatcher didn't recognize the first non-global-flag argument. Either Claude invoked a subcommand the shim doesn't implement, or a tmux global flag is being mis-parsed. Tmux globals (`-L`, `-S`, `-f`, boolean globals) must be stripped before the subcommand — look at `main()` in `bin/tmux`.

### Garbled `$(nvim_expr ...)` captures / weird Lua errors from valid-looking calls
The pane id or RPC result captured by bash contains stray escape bytes, which then ride into the next `_lua_call` as a corrupt argument. Historical cause: the nvim CLI emits terminal capability probes (`\x1b[?1049h` etc.) on stdout when invoked under a pty without `--headless`. The fix is baked into `nvim_expr` in `bin/tmux` (`--headless` + `</dev/null`); if symptoms re-appear, first suspect `NVIM_TMUX_NVIM_BIN` pointing at a wrapper script instead of the real nvim binary, then `grep -n -- --headless bin/tmux` to confirm the guard is intact.

### `send-keys` appears to type but not execute
`Enter` must send **CR (0x0D)**, not LF (0x0A). Interactive shells under readline treat CR as submit. Check `translate_token` in `lua/nvim-tmux/init.lua`.

### A split ends up in the wrong nvim window / focus jumps to the wrong pane
State holds a stale `nvim_winid`. The leader pane's winid is cached on first use by `leader_winid()` (via `vim.fn.win_getid()`). State lives in `vim.g.nvim_tmux` inside the running nvim — restart nvim to clear it, or `:lua vim.g.nvim_tmux = nil` from inside that nvim.

### `nvim-tmux: nvim: no $NVIM socket`
Shim was invoked outside any `:terminal`, so nvim never exported `$NVIM` into the shell. Unsupported by design — tell the user to launch whatever ran the shim from inside `:terminal` in a live nvim.

### `send-keys: unsupported key literal '<Tab>' / '<BSpace>' / ...`
`docs/CONTRACTS.md §4` lists the supported key names: `Enter`, `Space`, `C-c`, `C-d`. Anything else that matches the tmux key-literal shape (`^[A-Z][-A-Za-z0-9]+$`) is rejected rather than typed literally. If Claude needs a new one, add a case to `translate_token` in `lua/nvim-tmux/init.lua` and update CONTRACTS §4.

### Claude says "Failed to create swarm session"
First error after that is usually the real one — ask for the full stderr. Often: a tmux global flag the dispatcher doesn't strip (e.g. `tmux -L claude-swarm new-session ...`), or an option in `new-session` we never audited.

## How to extend the shim

1. Red: add failing test(s) — `tests/integration/<sub>.bats` for anything touching nvim (one file per subcommand), `tests/unit/` only for pure argv/dispatch logic.
2. Green: add the `cmd_<sub>()` handler in `bin/tmux` (flag parsing + one `_lua_call <method>`); implement the method in `lua/nvim-tmux/init.lua`.
3. `make lint && make test` stays green.
4. Commit with `[<topic>] <Title>` subject; describe what/why/caveats in the body.

Never add a subcommand without tracing it back to Claude's binary. Silent pass-through = invisible drift.

## Things to NOT do

- Don't add tmux semantics to bash. The split is: bash = argv parsing + one
  `_lua_call` RPC per subcommand; Lua (`lua/nvim-tmux/init.lua`)
  = everything that touches windows, buffers, jobs, or state. New subcommand
  handlers parse flags in `bin/tmux` and delegate to a Lua method.
- Don't introduce new runtime dependencies beyond `bash`, `nvim`, POSIX coreutils.
  No Node, no Python (that's why `nvr` was rejected). `jq` is test-only.
- Don't silently swallow unknown subcommands/flags — CONTRACTS §5 says fail loudly. (`set-option` is the one documented exception: a cosmetic no-op that accepts anything.)
- Don't reuse session/window/pane indices; they're monotonic per run.
- Don't mutate `vim.g.nvim_tmux` with nested writes (`vim.g.nvim_tmux.x = y`
  doesn't persist) — read into a local, mutate, commit the whole table back.

## Handy probes

```bash
# What state does the shim see right now?
"$NVIM_TMUX_NVIM_BIN" --headless --server "$NVIM" \
  --remote-expr "json_encode(get(g:, 'nvim_tmux', {}))" </dev/null | jq .

# What does the running nvim see?
"$NVIM_TMUX_NVIM_BIN" --headless --server "$NVIM" --remote-expr "winnr('\$')" </dev/null

# Is a given pane's window still open?  (get WINID from the state dump above)
"$NVIM_TMUX_NVIM_BIN" --headless --server "$NVIM" --remote-expr "win_id2win(${WINID})" </dev/null

# Run the tests
make test               # unit + integration + e2e
make test-int           # just headless-nvim integration
bash tests/e2e/agent-teams-external.sh
```

Read these first when diagnosing; improvise after.
