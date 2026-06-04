# Contributing to nvim-tmux

Thanks for your interest. nvim-tmux is a small bash shim with a focused scope; contributions that keep it small and focused are very welcome.

## Scope check before you start

Before opening a PR, confirm the change fits the project's scope (see the **Scope** section of the [README](README.md)):

- **In scope:** new tmux subcommands or arg shapes that Claude's binary actually invokes; bug fixes; tests; portability fixes for macOS / Linux.
- **Out of scope:** interactive tmux usage, coexistence with real tmux, Windows support, visual fidelity to tmux borders/titles, generic terminal-multiplexer features that Claude doesn't drive.

If you're unsure, open an issue first to discuss.

## Dev setup

```bash
git clone https://github.com/rubensf/nvim-tmux.git
cd nvim-tmux
make install-dev    # installs bats-core + shellcheck via brew or apt
```

Runtime requirements: `bash` (3.2+ on macOS), Neovim ≥ 0.9. Test/lint tooling only: `bats-core`, `shellcheck`, `jq`.

## Workflow

1. **Red:** add a failing test for the behavior you're changing.
   - Pure-bash logic (argv parsing, dispatch) → `tests/unit/<topic>.bats`
   - Anything that touches a real nvim → `tests/integration/<topic>.bats`
2. **Green:** implement the change. Bash flag parsing goes in the `cmd_*` handler in `bin/tmux`; everything that touches nvim windows, buffers, jobs, or state goes in `lua/nvim-tmux/init.lua`.
3. **Verify:**
   ```bash
   make lint        # shellcheck on bin/tmux
   make test        # unit + integration + e2e
   ```
4. **Commit:** subject `[<topic>] <Title>`, body explains *why* and any caveats.

## Cross-module contracts

State schema, nvim transport, send-keys grammar, and stderr/exit conventions are pinned in [`docs/CONTRACTS.md`](docs/CONTRACTS.md). If your change touches any of those, update CONTRACTS in the same PR.

## Filing bug reports

Please include:

- OS + version, Neovim version (`nvim --version | head -1`), Claude Code version.
- The exact `tmux ...` invocation that failed (or the nvim-tmux stderr line).
- A dump of the live state (from the shell inside the affected nvim's `:terminal`):
  ```bash
  "$NVIM_TMUX_NVIM_BIN" --headless --server "$NVIM" \
    --remote-expr "json_encode(get(g:, 'nvim_tmux', {}))" </dev/null | jq .
  ```

## Adding a new tmux subcommand

The shim impersonates a specific subset of tmux's surface — only what Claude's binary actually invokes. Before adding a handler:

1. Confirm Claude calls it (e.g. temporarily wrap the shim in a logging script, or run the failing flow and capture the stderr).
2. Document the call shape and any flags Claude passes.
3. Add unit tests for arg parsing and integration tests for the nvim side-effects.
4. Add a `cmd_<name>()` handler in `bin/tmux` that parses flags and makes one `_lua_call <method>` RPC; implement the method in `lua/nvim-tmux/init.lua`.

Silent pass-through of unknown subcommands is a bug — the shim fails loudly by design.
