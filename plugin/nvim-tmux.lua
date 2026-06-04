-- plugin/nvim-tmux.lua — auto-load entry point.
--
-- Runs once per nvim process on startup. Wires $PATH so :terminal
-- children find our shim without user intervention. Users who want
-- to opt out set `vim.g.nvim_tmux_disable = true`; users who want to
-- pass options call `require("nvim-tmux").setup({...})` themselves
-- AFTER setting `vim.g.loaded_nvim_tmux = 1` to suppress auto-load.

if vim.g.loaded_nvim_tmux == 1 then return end
vim.g.loaded_nvim_tmux = 1

if vim.g.nvim_tmux_disable then return end

require("nvim-tmux").setup()
