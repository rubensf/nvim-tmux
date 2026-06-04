---
name: Bug report
about: Something the shim does wrong, crashes on, or fails to handle
labels: bug
---

## What happened

<!-- One or two sentences. The exact failure or wrong behavior. -->

## Environment

- OS: <!-- macOS 14.5 / Ubuntu 22.04 / ... -->
- Neovim: <!-- nvim --version | head -1 -->
- Claude Code version: <!-- claude --version -->
- nvim-tmux version: <!-- tmux -V -->
- Plugin manager: <!-- lazy.nvim / packer / dein / native packages / ... -->

## Reproduction

<!--
Steps to reproduce. If you don't have a clean repro, describe what you were
doing in Claude when the error occurred.
-->

## Logs

<details>
<summary>Failing invocation + stderr</summary>

```
# the exact `tmux ...` command Claude ran (or you ran) and its stderr
```

</details>

<details>
<summary>Live state dump</summary>

```json
# from the shell inside the affected nvim's :terminal:
# "$NVIM_TMUX_NVIM_BIN" --headless --server "$NVIM" \
#   --remote-expr "json_encode(get(g:, 'nvim_tmux', {}))" </dev/null | jq .
```

</details>

## Expected behavior

<!-- What you expected to happen instead. -->
