-- nvim-tmux: the entire Lua side, one module.
--
--   1. State    -- session/window/pane bookkeeping in `vim.g.nvim_tmux`.
--   2. Actions  -- translate each tmux subcommand into nvim window/
--                  buffer/job operations. The bash shim calls these via
--                  `nvim --remote-expr v:lua.require'nvim-tmux'.X(...)`,
--                  one RPC per subcommand.
--   3. setup()  -- plugin packaging: wires $PATH + NVIM_TMUX_NVIM_BIN
--                  so :terminal children resolve `tmux` to our shim.
--                  Auto-run by plugin/nvim-tmux.lua.
--
-- State lives in `vim.g.nvim_tmux`, which scopes naturally to the
-- running nvim instance, is mutated atomically per RPC call (nvim's
-- event loop is single-threaded), and vanishes with the process -- by
-- design; the shim does not promise survival across restarts.
--
-- The store is FLAT: ids double as table keys, so "S:W.P" already
-- encodes the hierarchy and no record repeats its own id.
--
--   sessions  name    -> { idx, next_window }
--   windows   "S:W"   -> { name, next_pane }
--   panes     "S:W.P" -> { nvim_winid, nvim_bufnr, nvim_chan_id,
--                          hidden, hidden_session }
--
-- Every mutation reads `vim.g.nvim_tmux` into a local table, mutates
-- that, then writes the local back to `vim.g`. Direct nested mutation
-- (`vim.g.nvim_tmux.panes[...] = ...`) does NOT persist.

local M = {}

local LEADER_PANE = "1:0.0"

-- ---------------------------------------------------------------------------
-- State internals
-- ---------------------------------------------------------------------------

local function _ensure_init()
  if not vim.g.nvim_tmux then
    vim.g.nvim_tmux = {
      next_session_idx = 2,
      leader_winid = vim.NIL,
      sessions = {},
      windows = {},
      panes = {},
    }
  end
end

local function _read()
  _ensure_init()
  return vim.g.nvim_tmux
end

local function _commit(s) vim.g.nvim_tmux = s end

-- pane_id "S:W.P" -> sidx, widx, pidx (numbers)
local function _parse_pid(pid)
  local sidx, widx, pidx = pid:match("^(%d+):(%d+)%.(%d+)$")
  if not sidx then return nil end
  return tonumber(sidx), tonumber(widx), tonumber(pidx)
end

local function _empty_pane()
  return {
    nvim_winid = vim.NIL, nvim_bufnr = vim.NIL, nvim_chan_id = vim.NIL,
    hidden = false, hidden_session = vim.NIL,
  }
end

local function _is_set(v) return v ~= nil and v ~= vim.NIL end

local function _find_session_by_idx(s, idx)
  for name, sess in pairs(s.sessions or {}) do
    if sess.idx == idx then return name, sess end
  end
end

-- Resolve "<session-ref>" to (name, sess). session-ref may be the
-- literal session name or a numeric idx ("$2", "2"). Returns nil if no
-- match.
local function _resolve_session_ref(s, ref)
  if s.sessions[ref] then return ref, s.sessions[ref] end
  local digits = ref:match("^%$?(%d+)$")
  if digits then return _find_session_by_idx(s, tonumber(digits)) end
  return nil
end

-- Window ids of session #sidx, sorted by window index.
local function _session_window_ids(s, sidx)
  local prefix = sidx .. ":"
  local out = {}
  for wid in pairs(s.windows or {}) do
    if wid:sub(1, #prefix) == prefix then table.insert(out, wid) end
  end
  table.sort(out, function(a, b)
    return tonumber(a:sub(#prefix + 1)) < tonumber(b:sub(#prefix + 1))
  end)
  return out
end

-- Pane ids of window "S:W", sorted by pane index.
local function _window_pane_ids(s, wid)
  local prefix = wid .. "."
  local out = {}
  for pid in pairs(s.panes or {}) do
    if pid:sub(1, #prefix) == prefix then table.insert(out, pid) end
  end
  table.sort(out, function(a, b)
    return tonumber(a:sub(#prefix + 1)) < tonumber(b:sub(#prefix + 1))
  end)
  return out
end

-- Resolve a window-ref (window index "0" or window name) within
-- session #sidx. Returns the window id "S:W" or nil.
local function _resolve_window_ref(s, sidx, ref)
  if not ref or ref == "" then return nil end
  if ref:match("^%d+$") and s.windows[sidx .. ":" .. ref] then
    return sidx .. ":" .. ref
  end
  for _, wid in ipairs(_session_window_ids(s, sidx)) do
    if s.windows[wid].name == ref then return wid end
  end
end

-- After removing a pane from window "S:W": drop the window when its
-- last pane is gone, and the session when its last window is gone.
local function _cascade_remove(s, sidx, widx)
  local wid = sidx .. ":" .. widx
  if #_window_pane_ids(s, wid) == 0 then
    s.windows[wid] = nil
    if #_session_window_ids(s, sidx) == 0 then
      local sname = _find_session_by_idx(s, sidx)
      if sname then s.sessions[sname] = nil end
    end
  end
end

-- ---------------------------------------------------------------------------
-- State: lifecycle / scalars
-- ---------------------------------------------------------------------------

function M.leader_pane() return LEADER_PANE end

function M.leader_winid()
  local s = _read()
  if not _is_set(s.leader_winid) then
    s.leader_winid = vim.fn.win_getid()
    _commit(s)
  end
  return s.leader_winid
end

function M.has_session(name)
  return _read().sessions[name] ~= nil
end

function M.has_pane(pid)
  return _read().panes[pid] ~= nil
end

-- ---------------------------------------------------------------------------
-- State: mutations
-- ---------------------------------------------------------------------------

function M.create_session(name, window_name)
  local s = _read()
  if s.sessions[name] then error("session already exists: " .. name) end
  local idx = s.next_session_idx
  s.next_session_idx = idx + 1
  s.sessions[name] = { idx = idx, next_window = 1 }
  local wid = idx .. ":0"
  local pid = wid .. ".0"
  s.windows[wid] = {
    name = (window_name and window_name ~= "") and window_name or "default",
    next_pane = 1,
  }
  s.panes[pid] = _empty_pane()
  _commit(s)
  return pid
end

function M.create_window(session, window_name)
  local s = _read()
  local sess = s.sessions[session]
  if not sess then error("unknown session: " .. session) end
  local widx = sess.next_window
  sess.next_window = widx + 1
  local wid = sess.idx .. ":" .. widx
  local pid = wid .. ".0"
  s.windows[wid] = { name = window_name, next_pane = 1 }
  s.panes[pid] = _empty_pane()
  _commit(s)
  return pid
end

function M.split_pane(parent_pid)
  local s = _read()
  local sidx, widx = _parse_pid(parent_pid)
  local wid = sidx and (sidx .. ":" .. widx)
  local win = wid and s.windows[wid]
  if not win then error("state: no window for parent pane " .. parent_pid) end
  local pidx = win.next_pane
  win.next_pane = pidx + 1
  local pid = wid .. "." .. pidx
  s.panes[pid] = _empty_pane()
  _commit(s)
  return pid
end

-- Bookkeeping halves of kill/break/join. The public M.kill_pane /
-- M.break_pane / M.join_pane (actions section) own the nvim window
-- side and call these.
local function state_kill_pane(pid)
  local s = _read()
  if not s.panes[pid] then return "noop" end
  s.panes[pid] = nil
  local sidx, widx = _parse_pid(pid)
  _cascade_remove(s, sidx, widx)
  _commit(s)
  return "killed"
end

-- Hides a pane IN PLACE: the record stays under its origin id with
-- hidden=true, so the id keeps resolving (get_nvim_field etc.) while
-- list_panes/count_panes skip it. No cross-key move.
local function state_break_pane(pid, dest)
  local s = _read()
  local pane = s.panes[pid]
  if not pane then error("break-pane: unknown pane " .. pid) end
  pane.hidden = true
  pane.hidden_session = dest
  pane.nvim_winid = vim.NIL
  _commit(s)
  return pid
end

local function state_join_pane(hidden_pid, target)
  local s = _read()
  -- The hidden pane sits under its origin id (see state_break_pane),
  -- so it resolves directly -- no search.
  local opane = s.panes[hidden_pid]
  if not opane or opane.hidden ~= true then
    error("join-pane: no hidden pane with id " .. hidden_pid)
  end

  local sess_ref, win_ref = target:match("^([^:]+):?(.*)$")
  local _, target_sess = _resolve_session_ref(s, sess_ref)
  if not target_sess then error("join-pane: unknown target session " .. sess_ref) end
  local target_wid = _resolve_window_ref(s, target_sess.idx, win_ref)
  if not target_wid then
    error("join-pane: unknown target window " .. sess_ref .. ":" .. (win_ref or ""))
  end

  local target_win = s.windows[target_wid]
  local pidx = target_win.next_pane
  target_win.next_pane = pidx + 1
  local pid = target_wid .. "." .. pidx

  opane.hidden         = false
  opane.hidden_session = vim.NIL
  opane.nvim_winid     = vim.NIL  -- caller rebinds
  s.panes[pid] = opane

  -- Vacate the origin id (cascade window/session cleanup).
  s.panes[hidden_pid] = nil
  local osidx, owidx = _parse_pid(hidden_pid)
  _cascade_remove(s, osidx, owidx)
  _commit(s)
  return pid
end

function M.set_nvim_binding(pid, winid, bufnr, chan_id)
  local s = _read()
  local pane = s.panes[pid]
  if not pane then error("state: no pane record for " .. pid) end
  pane.nvim_winid = tonumber(winid)
  if bufnr   and bufnr   ~= "" and bufnr   ~= "null" then pane.nvim_bufnr   = tonumber(bufnr)   end
  if chan_id and chan_id ~= "" and chan_id ~= "null" then pane.nvim_chan_id = tonumber(chan_id) end
  _commit(s)
  return pid
end

-- ---------------------------------------------------------------------------
-- State: queries (return strings/numbers; lists are joined with \n)
-- ---------------------------------------------------------------------------

-- One pane field as a string. "null" if unset.
function M.get_nvim_field(pid, field)
  local pane = _read().panes[pid]
  if not pane then error("state: no pane record for " .. pid) end
  local v = pane[field]
  if v == nil or v == vim.NIL then return "null" end
  return tostring(v)
end

function M.list_sessions(field)
  field = field or "name"
  local s = _read()
  local entries = {}
  for name, sess in pairs(s.sessions) do
    table.insert(entries, { name = name, idx = sess.idx })
  end
  table.sort(entries, function(a, b) return a.idx < b.idx end)
  local out = {}
  for _, e in ipairs(entries) do
    if field == "name" then
      table.insert(out, e.name)
    elseif field == "id" then
      table.insert(out, "$" .. e.idx)
    elseif field == "name_with_count" then
      local n = #_session_window_ids(s, e.idx)
      table.insert(out, e.name .. ": " .. n .. " windows")
    else
      error("list_sessions: unknown field '" .. field .. "'")
    end
  end
  return table.concat(out, "\n")
end

function M.list_windows(session_ref, field)
  local s = _read()
  local _, sess = _resolve_session_ref(s, session_ref)
  if not sess then error("unknown session: " .. session_ref) end
  local out = {}
  for _, wid in ipairs(_session_window_ids(s, sess.idx)) do
    if field == "name" then
      table.insert(out, s.windows[wid].name)
    elseif field == "id" then
      table.insert(out, wid)
    else
      error("list_windows: unknown field '" .. tostring(field) .. "'")
    end
  end
  return table.concat(out, "\n")
end

-- Resolve (session_ref, window_ref) to the window ids to enumerate:
-- the one referenced window, or all of the session's windows when
-- window_ref is empty.
local function _target_window_ids(s, session_ref, window_ref)
  local _, sess = _resolve_session_ref(s, session_ref)
  if not sess then error("unknown session: " .. session_ref) end
  if window_ref and window_ref ~= "" then
    local wid = _resolve_window_ref(s, sess.idx, window_ref)
    if not wid then error("unknown window: " .. session_ref .. ":" .. window_ref) end
    return { wid }
  end
  return _session_window_ids(s, sess.idx)
end

function M.list_panes(session_ref, window_ref)
  local s = _read()
  local out = {}
  for _, wid in ipairs(_target_window_ids(s, session_ref, window_ref)) do
    for _, pid in ipairs(_window_pane_ids(s, wid)) do
      if not s.panes[pid].hidden then table.insert(out, pid) end
    end
  end
  return table.concat(out, "\n")
end

function M.count_panes(session_ref, window_ref)
  local s = _read()
  -- Empty window_ref resolves to all windows; count only the first
  -- (lowest-idx) one.
  local wid = _target_window_ids(s, session_ref, window_ref)[1]
  if not wid then return 0 end
  local n = 0
  for _, pid in ipairs(_window_pane_ids(s, wid)) do
    if not s.panes[pid].hidden then n = n + 1 end
  end
  return n
end

-- ---------------------------------------------------------------------------
-- Actions: pane structure
-- ---------------------------------------------------------------------------

-- Resolve a pane_id to a winid:
--   leader pane -> leader_winid (cached on first use)
--   bound       -> the bound winid
--   else        -> fall back to leader winid; structural callers (e.g.
--                  split parent lookup) are fine with that, and
--                  open_terminal handles its own materialization.
local function winid_for_pane(pid)
  if pid == LEADER_PANE then return M.leader_winid() end
  local w = M.get_nvim_field(pid, "nvim_winid")
  if w ~= "null" then return tonumber(w) end
  return M.leader_winid()
end

function M.split_window(parent_pid, direction, size_pct)
  local parent_winid = winid_for_pane(parent_pid)
  vim.fn.win_gotoid(parent_winid)
  -- Measure BEFORE splitting: :vsplit/:split halve the parent first, so
  -- a post-split winwidth() would make -l N% come out at ~N/2.
  local pre_w = vim.fn.winwidth(parent_winid)
  local pre_h = vim.fn.winheight(parent_winid)
  if direction == "h" then
    vim.cmd("vsplit")
  elseif direction == "v" then
    vim.cmd("split")
  else
    error("split-window: direction must be h or v, got '" .. tostring(direction) .. "'")
  end
  if size_pct and size_pct ~= "" then
    local pct = tonumber(size_pct)
    if direction == "h" then
      vim.cmd("vertical resize " .. math.floor(pre_w * pct / 100))
    else
      vim.cmd("resize " .. math.floor(pre_h * pct / 100))
    end
  end
  local new_winid = vim.fn.win_getid()
  local new_pid = M.split_pane(parent_pid)
  M.set_nvim_binding(new_pid, new_winid)
  return new_pid
end

function M.kill_pane(pid)
  if not M.has_pane(pid) then return "noop" end
  local chan = M.get_nvim_field(pid, "nvim_chan_id")
  local winid = M.get_nvim_field(pid, "nvim_winid")
  if chan ~= "null" then
    -- Live :terminal -- wiping the buffer stops the job AND closes
    -- every window showing it, sparing us a "[Process exited]" residual.
    local bufnr = M.get_nvim_field(pid, "nvim_bufnr")
    if bufnr ~= "null" then
      pcall(vim.api.nvim_buf_delete, tonumber(bufnr), { force = true })
    end
  elseif winid ~= "null" then
    local wid = tonumber(winid)
    if vim.fn.win_id2win(wid) ~= 0 then
      pcall(vim.api.nvim_win_close, wid, true)
    end
  end
  state_kill_pane(pid)
  return "killed"
end

function M.select_pane(pid, title)
  if not M.has_pane(pid) then error("select-pane: unknown pane '" .. pid .. "'") end
  local winid = winid_for_pane(pid)
  if vim.fn.win_id2win(winid) == 0 then
    error("select-pane: nvim window " .. winid .. " for pane " .. pid .. " no longer exists")
  end
  vim.fn.win_gotoid(winid)
  if title and title ~= "" then
    pcall(vim.api.nvim_set_option_value, "winbar", title, { win = winid })
  end
  return pid
end

function M.resize_pane(pid, width_pct)
  if not M.has_pane(pid) then error("resize-pane: unknown pane '" .. pid .. "'") end
  local winid = winid_for_pane(pid)
  local cols = math.floor(vim.o.columns * tonumber(width_pct) / 100)
  vim.api.nvim_win_set_width(winid, cols)
  return pid
end

-- MVP: every layout shape Claude asks for resolves to `wincmd =`. The
-- structural shape (leader + teammates each with its own terminal
-- buffer) is what matters; visual fidelity isn't checked.
function M.select_layout()
  vim.cmd("wincmd =")
  return ""
end

function M.break_pane(pid, dest)
  if not M.has_pane(pid) then error("break-pane: unknown pane '" .. pid .. "'") end
  local winid = M.get_nvim_field(pid, "nvim_winid")
  state_break_pane(pid, dest)
  if winid ~= "null" then
    local wid = tonumber(winid)
    -- :close-equivalent (not :bdelete): keep the :terminal job alive
    -- so a future join-pane can restore it.
    if vim.fn.win_id2win(wid) ~= 0 then
      pcall(vim.api.nvim_win_close, wid, true)
    end
  end
  return pid
end

function M.join_pane(hidden_pid, target_window, direction)
  -- Validate EVERYTHING up-front, before any window mutation -- a
  -- failure after the split would orphan an unbound nvim window.
  -- 1. The pane must exist, be hidden (break_pane hides in place), and
  --    carry a preserved buffer.
  local ok, hidden = pcall(M.get_nvim_field, hidden_pid, "hidden")
  local bufnr_str = (ok and hidden == "true")
    and M.get_nvim_field(hidden_pid, "nvim_bufnr") or "null"
  if bufnr_str == "null" then
    error("join-pane: no preserved buffer for hidden pane '" .. hidden_pid .. "'")
  end
  local bufnr = tonumber(bufnr_str)

  -- 2. The target session AND window must resolve. An empty win_ref
  --    ("swarm:" / "swarm") would slip through list_panes (which treats
  --    it as "all windows") only to fail later in state_join_pane.
  local sess_ref, win_ref = target_window:match("^([^:]+):?(.*)$")
  do
    local s = _read()
    local _, tsess = _resolve_session_ref(s, sess_ref or "")
    if not tsess then error("join-pane: unknown target session " .. tostring(sess_ref)) end
    if win_ref == "" or not _resolve_window_ref(s, tsess.idx, win_ref) then
      error("join-pane: unknown target window " .. sess_ref .. ":" .. (win_ref or ""))
    end
  end

  -- Find a parent winid in the target window to split off.
  local parent_winid
  local first_panes = M.list_panes(sess_ref or "", win_ref or "")
  local first_pid = first_panes:match("^([^\n]+)")
  if first_pid then
    local w = M.get_nvim_field(first_pid, "nvim_winid")
    if w ~= "null" then parent_winid = tonumber(w) end
  end
  parent_winid = parent_winid or M.leader_winid()

  vim.fn.win_gotoid(parent_winid)
  if direction == "v" then vim.cmd("split") else vim.cmd("vsplit") end
  vim.cmd("buffer " .. bufnr)
  local new_winid = vim.fn.win_getid()

  local new_pid = state_join_pane(hidden_pid, target_window)
  M.set_nvim_binding(new_pid, new_winid, bufnr)
  return new_pid
end

-- ---------------------------------------------------------------------------
-- Actions: terminal + send-keys
-- ---------------------------------------------------------------------------

local function translate_token(tok)
  if tok == "Enter" then return "\r" end
  if tok == "Space" then return " " end
  if tok == "C-c"   then return "\3" end
  if tok == "C-d"   then return "\4" end
  -- Anything else that LOOKS like a tmux key literal (capital + alnum/-)
  -- is unsupported -- fail loudly rather than typing it as text.
  if tok:match("^[A-Z][-A-Za-z0-9]+$") then
    error("send-keys: unsupported key literal '" .. tok .. "'")
  end
  return tok
end

function M.open_terminal(pid)
  local existing = M.get_nvim_field(pid, "nvim_chan_id")
  if existing ~= "null" then return tonumber(existing) end

  -- If the pane already has a live non-leader winid, reuse it (the
  -- split-window-then-send-keys path). Otherwise materialize a fresh
  -- vsplit off the leader so :terminal doesn't replace the leader's
  -- own terminal buffer. The win_id2win guard matters: a stale winid
  -- (user :close'd the window) makes win_gotoid a silent no-op and
  -- :terminal would clobber whatever window happens to be current.
  local leader_winid = M.leader_winid()
  local stored = M.get_nvim_field(pid, "nvim_winid")
  local winid
  if stored ~= "null" and tonumber(stored) ~= leader_winid
     and vim.fn.win_id2win(tonumber(stored)) ~= 0 then
    winid = tonumber(stored)
    vim.fn.win_gotoid(winid)
  else
    vim.fn.win_gotoid(leader_winid)
    vim.cmd("vsplit")
    winid = vim.fn.win_getid()
  end

  vim.cmd("terminal")
  local bufnr = vim.fn.bufnr("%")
  local chan  = vim.fn.getbufvar(bufnr, "terminal_job_id")
  if not chan or chan == 0 then
    error("send-keys: failed to spawn :terminal for pane '" .. pid .. "'")
  end

  -- When the inner process exits naturally (`exit`, C-d, agent done),
  -- collapse the window. The delete is deferred via timer_start(0)
  -- so it runs AFTER TermClose finishes -- a synchronous delete from
  -- inside TermClose trips E937 "buffer in use".
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = bufnr, once = true, nested = true,
    callback = function()
      vim.defer_fn(function()
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end, 0)
    end,
  })

  M.set_nvim_binding(pid, winid, bufnr, chan)
  return chan
end

function M.send_keys(pid, ...)
  if not M.has_pane(pid) then error("send-keys: unknown pane '" .. pid .. "'") end
  -- Translate (and thereby validate) every token BEFORE touching nvim
  -- state: a bad literal must not leave a freshly opened terminal behind.
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do parts[i] = translate_token(select(i, ...)) end
  local chan_str = M.get_nvim_field(pid, "nvim_chan_id")
  local chan
  if chan_str == "null" then
    chan = M.open_terminal(pid)
  else
    chan = tonumber(chan_str)
  end
  vim.api.nvim_chan_send(chan, table.concat(parts))
  return ""
end

-- ---------------------------------------------------------------------------
-- Plugin setup (packaging only)
-- ---------------------------------------------------------------------------

-- Returns the directory that contains both bin/ and lua/ -- i.e., the
-- plugin root. Works regardless of where the plugin manager cloned us.
-- Always absolute: :p resolves relative paths against CWD at load time
-- so the result doesn't drift if the user later :cd's.
local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then source = source:sub(2) end
  -- /x/y/z/lua/nvim-tmux/init.lua -> /x/y/z (absolute)
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local function notify(level, msg)
  vim.schedule(function()
    vim.notify("nvim-tmux: " .. msg, level)
  end)
end

local function path_contains(path_list, dir)
  -- Match against ":"-delimited entries. dir is appended with ":" to
  -- avoid false hits on prefix-substring collisions.
  return (":" .. path_list .. ":"):find(":" .. dir .. ":", 1, true) ~= nil
end

--- Wire up the shim. Safe to call multiple times.
--- @param opts table|nil
---   shim_dir     (string)  absolute path to bin/ of the installed plugin.
---                          Default: <plugin_root>/bin
---   enabled      (bool)    false to skip PATH modification. Default true.
---   set_nvim_bin (bool)    if true and $NVIM_TMUX_NVIM_BIN is unset,
---                          point it at vim.v.progpath. Default true.
function M.setup(opts)
  opts = opts or {}
  if opts.enabled == false then return end

  local shim_dir = opts.shim_dir or (plugin_root() .. "/bin")
  local shim = shim_dir .. "/tmux"

  if vim.fn.isdirectory(shim_dir) == 0 then
    notify(vim.log.levels.ERROR,
      "shim directory not found: " .. shim_dir ..
      " -- is the plugin fully cloned?")
    return
  end
  if vim.fn.executable(shim) == 0 then
    notify(vim.log.levels.WARN,
      "shim not executable at " .. shim .. " -- bash will error on invocation")
  end
  if vim.fn.executable("bash") == 0 then
    notify(vim.log.levels.WARN, "bash not on PATH; shim cannot run")
  end

  -- Idempotent PATH prepend.
  local path = vim.env.PATH or ""
  if not path_contains(path, shim_dir) then
    vim.env.PATH = shim_dir .. ":" .. path
  end

  -- NVIM_TMUX_NVIM_BIN: point at the real nvim executable so the shim
  -- bypasses any user wrapper script (nvr-style). Don't clobber if the
  -- user already set it.
  if opts.set_nvim_bin ~= false and (vim.env.NVIM_TMUX_NVIM_BIN or "") == "" then
    vim.env.NVIM_TMUX_NVIM_BIN = vim.v.progpath
  end
end

return M
