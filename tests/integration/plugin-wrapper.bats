#!/usr/bin/env bats

# Tests the Lua plugin wrapper: loading the plugin should prepend the
# shim's bin/ directory to $PATH and point NVIM_TMUX_NVIM_BIN at the
# running nvim binary -- so :terminal children resolve `tmux` to our
# impersonator with zero user config.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  if [[ -n "${NVIM_TMUX_NVIM_BIN:-}" ]]; then
    NVIM_BIN="$NVIM_TMUX_NVIM_BIN"
  elif [[ -x /opt/homebrew/bin/nvim ]]; then
    NVIM_BIN=/opt/homebrew/bin/nvim
  else
    NVIM_BIN=$(command -v nvim || true)
  fi
  [ -n "$NVIM_BIN" ] && [ -x "$NVIM_BIN" ] || skip "no nvim binary found"
}

# Run headless nvim with the plugin's rtp loaded, then execute an
# arbitrary :lua expression and echo its value.
plugin_probe() {
  local lua_expr="$1"
  "$NVIM_BIN" --headless --clean \
    -c "set rtp+=${REPO_ROOT}" \
    -c "lua require('nvim-tmux').setup()" \
    -c "lua print(${lua_expr})" \
    -c 'qa' 2>&1
}

@test "setup prepends the plugin's bin/ to \$PATH" {
  local out
  out=$(plugin_probe "(vim.env.PATH or ''):match('^[^:]+')")
  [ "$out" = "${REPO_ROOT}/bin" ]
}

@test "setup sets NVIM_TMUX_NVIM_BIN to vim.v.progpath when unset" {
  unset NVIM_TMUX_NVIM_BIN
  local out
  out=$(plugin_probe "vim.env.NVIM_TMUX_NVIM_BIN or ''")
  # progpath may resolve symlinks (Homebrew's /opt/homebrew/bin/nvim ->
  # /opt/homebrew/Cellar/.../nvim), so just check the result is a
  # valid nvim binary.
  [ -n "$out" ]
  [ -x "$out" ]
  "$out" --version | head -1 | grep -q '^NVIM v'
}

@test "setup honors a pre-existing NVIM_TMUX_NVIM_BIN (doesn't clobber)" {
  NVIM_TMUX_NVIM_BIN=/opt/custom/nvim "$NVIM_BIN" --headless --clean \
    -c "set rtp+=${REPO_ROOT}" \
    -c "lua require('nvim-tmux').setup()" \
    -c "lua print(vim.env.NVIM_TMUX_NVIM_BIN)" \
    -c 'qa' > "$BATS_TEST_TMPDIR/out" 2>&1
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = "/opt/custom/nvim" ]
}

@test "setup is idempotent -- calling it twice doesn't double-prepend" {
  local out count
  out=$("$NVIM_BIN" --headless --clean \
    -c "set rtp+=${REPO_ROOT}" \
    -c "lua require('nvim-tmux').setup()" \
    -c "lua require('nvim-tmux').setup()" \
    -c "lua print(vim.env.PATH)" \
    -c 'qa' 2>&1)
  # Count occurrences of "<repo>/bin:" in the PATH.
  count=$(printf '%s' "$out" | awk -v r="${REPO_ROOT}/bin" '
    { n=0; p=0; while ((q = index(substr($0,p+1), r ":")) > 0) { n++; p = p + q + length(r) + 1 } print n }
  ' | tail -1)
  [ "$count" -eq 1 ]
}

@test "setup({enabled = false}) is a pure no-op" {
  local out
  out=$("$NVIM_BIN" --headless --clean \
    -c "set rtp+=${REPO_ROOT}" \
    -c "lua require('nvim-tmux').setup({enabled = false})" \
    -c "lua print((vim.env.PATH or ''):match('^[^:]+'))" \
    -c 'qa' 2>&1)
  [ "$out" != "${REPO_ROOT}/bin" ]
}

@test "auto-load via plugin/nvim-tmux.lua wires PATH on startup" {
  # lazy.nvim-style: just put the plugin on rtp, let nvim source
  # plugin/*.lua automatically (no -c 'lua require').
  local out
  out=$("$NVIM_BIN" --headless --clean \
    -c "set rtp+=${REPO_ROOT}" \
    -c "runtime! plugin/nvim-tmux.lua" \
    -c "lua print((vim.env.PATH or ''):match('^[^:]+'))" \
    -c 'qa' 2>&1)
  [ "$out" = "${REPO_ROOT}/bin" ]
}

@test "vim.g.nvim_tmux_disable = true suppresses auto-load" {
  local out
  out=$("$NVIM_BIN" --headless --clean \
    -c "set rtp+=${REPO_ROOT}" \
    -c "let g:nvim_tmux_disable = 1" \
    -c "runtime! plugin/nvim-tmux.lua" \
    -c "lua print((vim.env.PATH or ''):match('^[^:]+'))" \
    -c 'qa' 2>&1)
  [ "$out" != "${REPO_ROOT}/bin" ]
}
