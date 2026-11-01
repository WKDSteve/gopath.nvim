---@module 'gopath.commands'
---@brief User-facing commands: resolve & open / copy / debug / probe.
---Handles routing to appropriate opener based on user's chosen mode (edit/split/vsplit/tab).

local RESOLVE = require("gopath.resolve")
local CONFIG = require("gopath.config")
local OPEN = require("gopath.open")
local HELP = require("gopath.open.help")
local LOG = require("gopath.util.log")

local M = {}

---@private
---@param res GopathResult
---@param kind string
local function open_for_kind(res, kind)
  if res.kind == "help" then
    local target = (kind == "tab" and "tab")
      or ((kind == "window" or kind == "vsplit") and "window")
      or "edit"
    return HELP.open(res, { target = target })
  end
  return OPEN.open(res, kind or "edit")
end

---Open a result a caller already resolved itself (bypasses cursor
---re-resolution) -- for a caller like `gopath.integrations.menu` that
---resolved a right-click's context (cursor OR a live visual selection, via
---`gopath.resolve_selection`) once, up front, and needs to open exactly
---that same result once an action is chosen from the menu.
---
---A result that names several targets (a task id in two vaults) is picked from
---first, as gF does; a dismissed picker opens nothing.
---@param res GopathResult
---@param kind string|nil  "edit"|"window"|"vsplit"|"tab"|"explorer"|"filetree"
function M.open_result(res, kind)
  kind = kind or "edit"
  if res and res.alternatives and #res.alternatives > 1 then
    require("gopath.resolvers.common.task_id").pick(res, function(choice)
      if choice then open_for_kind(choice, kind) end
    end)
    return
  end
  open_for_kind(res, kind)
end

---Open a resolved result, applying the fuzzy-alternate fallback when the
---file does not exist. A missing file that fuzzy-alternate can't resolve
---either falls through to `gopath.open`, which offers to create it (see
---`gopath.create`) — a directory can't be "opened" in a buffer the way a
---file can, so there is no more silent "open nearest folder" fallback here.
---@private
---@param res GopathResult
---@param kind string
local function finish_open(res, kind)
  local cfg = CONFIG.get()

  if res.exists == false and cfg.alternate and cfg.alternate.enable then
    -- Try fuzzy alternate resolution (Levenshtein similarity in same dir).
    -- Callback-based: the picker can be asynchronous, so we may only fall
    -- through once it has actually reported back — otherwise the create-offer
    -- below opens on top of a picker that is still on screen.
    local alternate = require("gopath.alternate")
    alternate.try_resolve(res.path, {
      similarity_threshold = cfg.alternate.similarity_threshold or 75,
      mode = kind or "edit",
      range = res.range,
    }, function(handled)
      if handled then return end
      open_for_kind(res, kind or "edit")
    end)
    return
  end

  open_for_kind(res, kind or "edit")
end

---Resolve and open with the specified window mode.
---
---The synchronous pipeline only consults instant sources (help, env, rtp, and
---the in-memory truncated-path cache). When it cannot find an existing file,
---the expensive filesystem search runs ASYNCHRONOUSLY so the UI never freezes:
---a "Dateisuche läuft…" message is shown and the buffer opens once a match is
---found.
---@param kind string  "edit"|"window"|"vsplit"|"tab"|"explorer"|"filetree"
---@see M.probe_selection
function M.goto_at_cursor(kind)
  kind = kind or "edit"
  local res, err = RESOLVE.resolve_at_cursor({})

  -- A task id that names several tasks (open and finished, or in two vaults):
  -- ask, and open the one picked. A dismissed picker opens nothing.
  if res and res.alternatives and #res.alternatives > 1 then
    require("gopath.resolvers.common.task_id").pick(res, function(choice)
      if choice then finish_open(choice, kind) end
    end)
    return
  end

  -- Fast path: an existing file was resolved instantly (help, env, rtp, cache…).
  if res and res.exists ~= false then return finish_open(res, kind) end

  -- Nothing concrete yet → try an async live filesystem search before giving up.
  local cfg = CONFIG.get()
  local ts_cfg = cfg.tailsearch or {}
  if ts_cfg.enable == false then
    if res then return finish_open(res, kind) end
    LOG.warn("no match: " .. (err or "unknown"))
    return
  end

  local TS = require("gopath.resolvers.common.tailsearch")

  -- Derive a search tail (+ line/col) from the speculative result or <cfile>.
  local tail, line, col
  if res and res.path and res.path ~= "" then
    tail = TS.sanitize(res.path)
    line = res.range and res.range.line
    col = res.range and res.range.col
  else
    local cfile = vim.fn.expand("<cfile>")
    if type(cfile) == "string" and cfile ~= "" then
      tail, line, col = TS.sanitize(cfile)
    end
  end

  if not tail or tail == "" then
    if res then return finish_open(res, kind) end
    LOG.warn("no match: " .. (err or "unknown"))
    return
  end

  TS.resolve_async(tail, {
    roots = ts_cfg.roots,
    limit = ts_cfg.limit or 100,
    max_components = ts_cfg.max_components or 6,
    line = line,
    col = col,
  }, function(found)
    vim.schedule(function()
      if found then return finish_open(found, kind) end
      -- Live search missed → fall back to whatever the sync pass produced
      -- (drives the alternate / nearest-folder fallbacks on the original path).
      if res then return finish_open(res, kind) end
      LOG.warn("no match for '" .. tail .. "'")
    end)
  end, function()
    -- on_live_start: only fires when the slow filesystem walk actually begins.
    LOG.info("Dateisuche läuft…")
  end)
end

---Check whether the path under cursor exists, without opening it.
---Reports existence; when missing, offers to create it (always offers, even
---if `create_on_missing.enable = false` — this is an explicit user action)
---and jumps into the freshly created file on confirmation.
function M.check_under_cursor()
  local res, err = RESOLVE.resolve_at_cursor({})
  if not res or not res.path then
    LOG.warn("no match to check: " .. (err or "unknown"))
    return
  end

  if res.kind == "help" then
    LOG.info("help target — nothing to check: " .. tostring(res.subject))
    return
  end

  if res.kind == "url" then
    LOG.info("URL — nothing to check on disk: " .. res.path)
    return
  end

  if res.exists ~= false then
    LOG.info("exists: " .. res.path)
    return
  end

  local CREATE = require("gopath.create")
  CREATE.offer(res, function(created_res)
    OPEN.open(created_res, "edit")
  end, { force = true })
end

---Copy the resolved location to the system clipboard as "path:line:col".
function M.copy_location()
  local res, err = RESOLVE.resolve_at_cursor({})
  if not res then
    LOG.warn("no match to copy: " .. (err or "unknown"))
    return
  end

  local l = res.range and res.range.line or 1
  local c = res.range and res.range.col or 1

  -- A URL has no line/col to append -- copy it verbatim so the clipboard
  -- content stays pasteable into a browser.
  --
  -- Both branches go through lib.nvim's verified writer rather than a bare
  -- vim.fn.setreg("+", ...): that call does not raise when there is no
  -- clipboard provider (or the build itself reports has("clipboard") == 0)
  -- -- it silently does nothing -- so a bare call was never proof anything
  -- actually reached the clipboard. Its own return value is checked here
  -- for the same reason: claiming "copied to clipboard" regardless of it
  -- would just move the same lie up one level.
  local copy = require("lib.nvim.cross.copy_to_clipboard")
  local text
  if res.kind == "url" then
    text = tostring(res.path or "?")
  else
    local left
    if res.kind == "help" then
      left = ("<help:%s>"):format(res.subject or "?")
    else
      left = tostring(res.path or "?")
    end
    text = ("%s:%d:%d"):format(left, l, c)
  end

  if copy(text) then
    LOG.info("copied to clipboard")
  else
    LOG.warn("could not copy to clipboard: no provider and no external tool found")
  end
end

-- ── Visual selection helpers ─────────────────────────────────────────────────

---Read the text of the `'<`/`'>` visual selection (single line), or nil when
---the marks hold nothing usable.
---
---Deliberately does NOT gate on `nvim_get_mode()`. It used to, and that made
---the whole function dead code: by the time either caller runs, Visual mode is
---already over — a `:'<,'>Gopath probe` executes in command mode, and the
---visual keymap feeds `<Esc>` before its scheduled callback. `mode` was
---therefore never one of v/V/CTRL-V, the function always returned nil, and the
---visual probe silently degraded to `<cfile>`/`<cword>` in every case.
---
---Whether the marks are meaningful is the caller's knowledge, not something
---derivable here (they persist from any earlier selection), so callers only
---invoke this when they know a selection was actually given.
---@internal
---@return string|nil
local function get_visual_selection()
  ---@diagnostic disable-next-line: deprecated
  local srow, scol = unpack(vim.api.nvim_buf_get_mark(0, "<"))
  ---@diagnostic disable-next-line: deprecated
  local erow, ecol = unpack(vim.api.nvim_buf_get_mark(0, ">"))
  if srow == 0 or erow == 0 then return nil end
  local line = vim.api.nvim_buf_get_lines(0, srow - 1, srow, false)[1] or ""
  if srow ~= erow then return line:match("%S") and line or nil end
  local i = math.min(scol + 1, #line + 1)
  -- ecol is MAXCOL for a linewise selection; clamping keeps sub() in range.
  local j = math.min(ecol + 1, #line + 1)
  if j < i then
    i, j = j, i
  end
  local slice = line:sub(i, j):gsub("^%s+", ""):gsub("%s+$", "")
  return slice ~= "" and slice or nil
end

---Get a path-ish token in normal mode (<cfile>, then <cword>).
---@internal
---@return string|nil
local function get_normal_token()
  local tok = vim.fn.expand("<cfile>")
  if type(tok) == "string" and tok ~= "" then return tok end
  tok = vim.fn.expand("<cword>")
  return (type(tok) == "string" and tok ~= "") and tok or nil
end

-- ── Probe command (pathprobe strategy) ───────────────────────────────────────

---Probe: resolve the path under cursor / in visual selection.
---
---Tries direct recognizers first (`gopath.resolve_selection`: a `$VAR/rest`
---reference or a URL, which tailsearch's filesystem suffix search has no way
---to recognize on its own) -- this is what lets a PARTIAL selection of one of
---those resolve, not just a partial selection of a plain file path. Falls
---back to tailsearch (suffix-based filesystem search, with vim.ui.select
---when multiple matches are found) for everything else.
---
---`opts.selection` is how a caller states that the `'<`/`'>` marks describe a
---selection made for THIS invocation — the marks alone can't say so, since they
---outlive whatever set them. Without it, the cursor token is used.
---
---`open_cmd = "filetree"`/`"explorer"` reveal the resolved result instead of
---opening a buffer for it — the same modes `gopath.open` already supports for
---the cursor-based `gT`/`gM` keymaps, now reachable for a (possibly partial)
---selection too. See `gopath.open.M.open` for what each mode does per result
---kind (e.g. a URL is never "revealed", it opens externally regardless).
---@param opts { open_cmd?: string, ask?: boolean, roots?: string[], max_components?: integer, selection?: boolean }|nil
function M.probe_selection(opts)
  opts = opts or {}
  local open_cmd = opts.open_cmd or "edit"
  local open_mode = open_cmd == "vsplit" and "vsplit"
    or open_cmd == "split" and "window"
    or open_cmd == "tab" and "tab"
    or open_cmd == "explorer" and "explorer"
    or open_cmd == "filetree" and "filetree"
    or "edit"

  local raw = (opts.selection and get_visual_selection()) or get_normal_token()
  if not raw then
    LOG.warn("No path-like token under cursor / in selection")
    return
  end

  local direct = require("gopath.resolve_selection").resolve_text(raw)
  if direct then
    open_for_kind(direct, open_mode)
    return
  end

  local cfg = CONFIG.get()
  local ts_cfg = cfg.tailsearch or {}
  local TS = require("gopath.resolvers.common.tailsearch")

  TS.probe(raw, {
    roots = opts.roots or ts_cfg.roots,
    max_components = opts.max_components or ts_cfg.max_components or 6,
    limit = ts_cfg.limit or 100,
    ask = opts.ask ~= false and ts_cfg.ask_on_ambiguous ~= false,
  }, function(res, reason)
    if reason == "cancelled" then
      -- The user dismissed the disambiguation picker: not a failed search.
      return
    end
    if not res then
      LOG.warn("probe: no match found for '" .. raw .. "'")
      return
    end
    open_for_kind(res, open_mode)
  end)
end

-- ─── Debug command ────────────────────────────────────────────────────────────

---@class GopathDebugInfo
---@field filetype   string
---@field cfile      string
---@field chain      LuaChainInfo|nil
---@field bind_sz    integer
---@field bind_map   LuaBindingMap
---@field identifier string|nil
---@field cache_info { files:integer, last_built:integer|nil, needs_refresh:boolean }|nil
---@field result     GopathResult|nil
---@field error      string|nil

---@private
---@return GopathDebugInfo
local function collect_debug_info()
  local info = {
    filetype = vim.bo.filetype or "?",
    cfile = vim.fn.expand("<cfile>"),
    chain = nil,
    bind_sz = 0,
    bind_map = {},
    identifier = nil,
    cache_info = nil,
    result = nil,
    error = nil,
  }

  pcall(function()
    info.chain = require("gopath.resolvers.lua.chain").get_chain_at_cursor()
  end)

  pcall(function()
    info.bind_map = require("gopath.resolvers.lua.binding_index").get_map()
    for _ in pairs(info.bind_map) do
      info.bind_sz = info.bind_sz + 1
    end
  end)

  pcall(function()
    local TS = require("gopath.providers.treesitter")
    local node = TS.node_at_cursor()
    if node and node:type() == "identifier" then
      info.identifier = vim.treesitter.get_node_text(node, 0)
    end
  end)

  pcall(function()
    local cache = require("gopath.truncated.cache")
    cache.load_from_disk()
    local state = cache._get_state()
    info.cache_info = {
      files = #(state.paths or {}),
      last_built = state.last_built,
      needs_refresh = cache.needs_refresh(),
    }
  end)

  info.result, info.error = RESOLVE.resolve_at_cursor({})
  return info
end

---@private
---@param info GopathDebugInfo
---@return string[]
local function format_debug_lines(info)
  local t = {
    "=== Gopath Debug ===",
    "  Filetype:   " .. info.filetype,
    "  <cfile>:    " .. info.cfile,
    "  Identifier: " .. (info.identifier or "nil"),
  }

  if info.chain then
    t[#t + 1] = "  Chain: " .. info.chain.base .. " -> " .. table.concat(info.chain.chain, ".")
  else
    t[#t + 1] = "  Chain: nil"
  end

  t[#t + 1] = "  Binding map size: " .. info.bind_sz
  if info.bind_sz > 0 then
    t[#t + 1] = "  Bindings (sample):"
    local n = 0
    for id, mod in pairs(info.bind_map) do
      t[#t + 1] = string.format("    %s -> %s", id, mod)
      n = n + 1
      if n >= 3 then break end
    end
  end

  -- The local first, then the check on the local: narrowing a *field* does not
  -- carry into a fresh read of it, so every `ci.x` below read as maybe-nil.
  local ci = info.cache_info
  if ci then
    t[#t + 1] = "  Cache:"
    t[#t + 1] = "    Files indexed:  " .. ci.files
    t[#t + 1] = "    Last built:     "
      .. (ci.last_built and os.date("%Y-%m-%d %H:%M:%S", ci.last_built) or "never")
    t[#t + 1] = "    Needs refresh:  " .. (ci.needs_refresh and "yes" or "no")
  end

  local res = info.result
  if res then
    t[#t + 1] = "  Result:"
    t[#t + 1] = "    language:   " .. (res.language or "?")
    t[#t + 1] = "    kind:       " .. (res.kind or "?")
    t[#t + 1] = "    path:       " .. tostring(res.path)
    t[#t + 1] = "    source:     " .. (res.source or "?")
    t[#t + 1] = "    confidence: " .. tostring(res.confidence)
    t[#t + 1] = "    exists:     " .. tostring(res.exists)
    if res.range then
      t[#t + 1] = "    range:      line="
        .. tostring(res.range.line)
        .. "  col="
        .. tostring(res.range.col)
    else
      t[#t + 1] = "    range:      nil"
    end
  else
    t[#t + 1] = "  Result: nil"
    t[#t + 1] = "  Error:  " .. (info.error or "unknown")
  end

  t[#t + 1] = "===================="
  return t
end

---Show detailed resolution information via vim.notify.
function M.debug_under_cursor()
  local info = collect_debug_info()
  local lines = format_debug_lines(info)
  LOG.info(table.concat(lines, "\n"))
end

---Rewrite an absolute path on the current line (or, with `opts.selection`,
---just the visually selected span of it) whose root segment is a configured
---directory name (e.g. "repos") back into `$VAR` form -- any drive letter,
---any OS. Also recognises a relative Markdown-link path that resolves under
---that root once joined to the buffer's own directory.
---@param opts { selection?: boolean }|nil
---@see gopath.env_shorten
function M.shorten_to_env(opts)
  require("gopath.env_shorten").shorten_current_line(opts)
end

---Rewrite literal occurrences of a configured "well-known" directory (e.g.
---vim.fn.stdpath("config")) on the current line (or, with `opts.selection`,
---just the visually selected span) back into `$VAR` form. Also recognises a
---relative Markdown-link path that resolves under that directory once
---joined to the buffer's own directory.
---@param opts { selection?: boolean }|nil
---@see gopath.env_shorten
function M.shorten_to_known_dir(opts)
  require("gopath.env_shorten").shorten_current_line_known(opts)
end

return M
