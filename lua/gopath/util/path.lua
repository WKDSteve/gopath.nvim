---@module 'gopath.util.path'
---@brief Path helpers: join/exists and multi-strategy file searches.
---@description
--- Provides four distinct search strategies used by resolvers:
---   1. `search_in_rtp`        — walks Neovim's runtimepath (with a module-level
---                               cache invalidated when the rtp string changes).
---   2. `search_with_vim_path` — consults &path / suffixesadd (vim's built-in
---                               file-search, good for languages that honour it).
---   3. `search_with_package_path` — uses Lua's own package.searchpath for
---                               resolving standard `require`-style module names.
---   4. `search_in_plugin_dirs` — walks the install directory of every *known*
---                               plugin, including ones that are installed but
---                               not loaded (and therefore absent from 1 and 3).
---
--- `search_module` composes 1 → 3 → 4 into the single chain every Lua module
--- resolver should use.

local M = {}

-- Module-level runtimepath cache.
-- Invalidated whenever vim.o.runtimepath changes (detected by string identity).
local _rtp_str = nil ---@type string|nil
local _rtp_list = nil ---@type string[]|nil

-- How long a built runtimepath name index stays usable, in milliseconds.
--
-- The index is keyed on the runtimepath string, which catches plugins loading
-- but not files appearing on disk. Three signals cover that directly: gopath's
-- own create-on-missing calls `invalidate_caches`, a `BufWritePost` autocmd
-- does the same for buffers written in this session, and installing a plugin
-- moves the runtimepath. The TTL is only a backstop for changes made entirely
-- outside Neovim (a git checkout, another tool), so it is deliberately long:
-- rebuilding costs about as much as one uncached lookup, and a short TTL would
-- rebuild on nearly every keypress, since interactive gF presses are usually
-- seconds apart.
--
-- Only the FIRST path segment is indexed, so this can only ever hide a
-- brand-new top-level entry; adding files under an existing directory resolves
-- normally regardless of index age.
---@return integer
local function rtp_index_ttl_ms()
  local ok, config = pcall(require, "gopath.config")
  if not ok or type(config.get) ~= "function" then return 30000 end
  local n = ((config.get() or {}).truncated or {}).rtp_index_ttl_ms
  return (type(n) == "number" and n >= 0) and n or 30000
end

-- Per-runtimepath-entry index of the names present at `<rtp>/` and `<rtp>/lua/`.
-- Entries are stored in runtimepath order so lookups preserve search order.
local _rtpidx = nil ---@type GopathRtpIndexEntry[]|nil
local _rtpidx_str = nil ---@type string|nil
local _rtpidx_at = 0 ---@type integer

-- Module-level plugin-directory cache, invalidated on the same signal as the
-- rtp cache: lazily loading a plugin mutates the runtimepath, which is the
-- cheapest available proxy for "the plugin set may have changed".
local _pdir_str = nil ---@type string|nil
local _pdir_list = nil ---@type string[]|nil

-- Index of module root -> plugin dirs owning it, sharing the rtp cache signal.
-- Declared up here with the other caches so `invalidate_caches` below can clear
-- it; a declaration next to its own accessor would be out of scope there and
-- would silently create globals instead.
local _pidx_str = nil ---@type string|nil
local _pidx_map = nil ---@type table<string, string[]>|nil

---Return the current runtimepath as a list, rebuilding only when it changed.
---@internal
---@return string[]
local function get_rtp_list()
  local s = vim.o.runtimepath
  local list = _rtp_list
  if s ~= _rtp_str or not list then
    list = vim.split(s, ",", { trimempty = true })
    _rtp_str, _rtp_list = s, list
  end
  return list
end

---Join path segments, normalising separators to forward-slash.
---@param ... string
---@return string
function M.join(...)
  local parts = { ... }
  for i = 1, #parts do
    local s = parts[i] or ""
    s = s:gsub("[/\\]+", "/")
    if s:sub(-1) == "/" and i < #parts then s = s:sub(1, -2) end
    parts[i] = s
  end
  return table.concat(parts, "/")
end

---Return true when `p` exists and is a regular file.
---@param p string
---@return boolean
function M.exists(p)
  if not p or p == "" then return false end
  -- `fs_stat` hits the OS directly, unlike `M.join`'s callers: a
  -- backslash-spelled path (Windows' native separator) is just an ordinary,
  -- nonexistent filename component on Linux, so it has to be normalised
  -- here too, not only where paths get built.
  local st = vim.uv.fs_stat((p:gsub("[/\\]+", "/")))
  return st ~= nil and st.type == "file"
end

---Return true when `p` exists and is a directory.
---@param p string
---@return boolean
function M.is_dir(p)
  if not p or p == "" then return false end
  local st = vim.uv.fs_stat((p:gsub("[/\\]+", "/")))
  return st ~= nil and st.type == "directory"
end

---Return the set of entry names directly inside `dir`, or nil when unreadable.
---@internal
---@param dir string
---@return table<string, true>|nil
local function scan_names(dir)
  local fs = vim.uv.fs_scandir(dir)
  if not fs then return nil end
  local set = {}
  while true do
    local name = vim.uv.fs_scandir_next(fs)
    if not name then break end
    set[name] = true
  end
  return set
end

---First path segment of a candidate ("a/b/c.lua" -> "a", "bar.lua" -> "bar.lua").
---This is the name that must exist directly inside a search root for the
---candidate to have any chance of resolving there.
---@internal
---@param candidate string
---@return string|nil
local function first_segment(candidate)
  return candidate:match("^([^/\\]+)")
end

---Build (or reuse) the per-runtimepath-entry name index.
---
---One readdir per search root replaces a stat per candidate per root. The
---payoff is the miss case: a candidate whose first segment appears in no root
---is rejected by hash lookup alone, without touching the filesystem.
---@internal
---@return GopathRtpIndexEntry[]
local function get_rtp_index()
  local s = vim.o.runtimepath
  local now = vim.uv.now()
  if _rtpidx and s == _rtpidx_str and (now - _rtpidx_at) < rtp_index_ttl_ms() then
    return _rtpidx
  end

  local idx = {}
  local rtp = get_rtp_list()
  for i = 1, #rtp do
    idx[i] = {
      dir = rtp[i],
      root = scan_names(rtp[i]),
      lua = scan_names(M.join(rtp[i], "lua")),
    }
  end

  _rtpidx, _rtpidx_str, _rtpidx_at = idx, s, now
  return idx
end

---Drop every cached directory listing, forcing the next search to re-read disk.
---Call after creating files that a subsequent lookup must be able to find.
---@return nil
function M.invalidate_caches()
  _rtpidx, _rtpidx_str, _rtpidx_at = nil, nil, 0
  _pidx_str, _pidx_map = nil, nil
end

---Strategy 1: search for `candidates` under every runtimepath entry.
--- For each rtp dir the search order is:
---   <rtp>/<candidate>
---   <rtp>/lua/<candidate>
--- Then falls back to cwd/<candidate> as a last resort.
---
--- A cached name index gates every probe, so only paths whose first segment
--- actually exists in that root are stat'ed. Search order is unchanged.
---@param candidates string[]
---@return string|nil  absolute path of first match
function M.search_in_rtp(candidates)
  if not candidates or #candidates == 0 then return nil end

  -- Hoisted out of the per-root loops: the segment of a candidate never varies
  -- by root, and this runs once per runtimepath entry otherwise.
  local segs = {}
  for j = 1, #candidates do
    segs[j] = first_segment(candidates[j])
  end

  local idx = get_rtp_index()
  for i = 1, #idx do
    local e = idx[i]
    if e.root then
      for j = 1, #candidates do
        if segs[j] and e.root[segs[j]] then
          local p = M.join(e.dir, candidates[j])
          if M.exists(p) then return p end
        end
      end
    end
    if e.lua then
      for j = 1, #candidates do
        if segs[j] and e.lua[segs[j]] then
          local p = M.join(e.dir, "lua", candidates[j])
          if M.exists(p) then return p end
        end
      end
    end
  end

  local cwd = vim.uv.cwd()
  for j = 1, #candidates do
    local p = M.join(cwd, candidates[j])
    if M.exists(p) then return p end
  end
  return nil
end

---Strategy 2: resolve `token` via vim's &path / suffixesadd mechanism.
--- Equivalent to what gf does for plain file paths.
---@param token string
---@return string|nil  absolute path
function M.search_with_vim_path(token)
  if not token or token == "" then return nil end
  if M.exists(token) then return vim.fn.fnamemodify(token, ":p") end
  local found = vim.fn.findfile(token, vim.o.path)
  if type(found) == "string" and found ~= "" and M.exists(found) then
    return vim.fn.fnamemodify(found, ":p")
  end
  local suffixes = vim.split(vim.o.suffixesadd or "", ",", { trimempty = true })
  for i = 1, #suffixes do
    local cand = token .. suffixes[i]
    local f = vim.fn.findfile(cand, vim.o.path)
    if type(f) == "string" and f ~= "" and M.exists(f) then return vim.fn.fnamemodify(f, ":p") end
  end
  return nil
end

---Strategy 3: resolve a dotted Lua module name via `package.searchpath`.
--- Useful for modules outside the Neovim runtimepath (e.g. luarocks packages).
---@param module string  Dotted module name, e.g. "a.b.c"
---@return string|nil  absolute path
function M.search_with_package_path(module)
  if type(module) ~= "string" or module == "" then return nil end
  local pattern = package and package.path or nil
  if not pattern or pattern == "" then return nil end
  local path = package.searchpath(module, pattern)
  if type(path) == "string" and M.exists(path) then return vim.fn.fnamemodify(path, ":p") end
  return nil
end

---Collect the install directory of every plugin the manager knows about,
---regardless of whether it has been loaded yet.
---
---Supports lazy.nvim (`lazy.core.config`) and Neovim's built-in `vim.pack`.
---Both are probed defensively: an absent or restructured manager yields an
---empty list rather than an error, so this stays a pure best-effort fallback.
---@internal
---@return string[]
local function get_plugin_dirs()
  local s = vim.o.runtimepath
  if s == _pdir_str and _pdir_list then return _pdir_list end

  local dirs, seen = {}, {}
  local function add(d)
    if type(d) == "string" and d ~= "" and not seen[d] then
      seen[d] = true
      dirs[#dirs + 1] = d
    end
  end

  -- lazy.nvim: every resolved spec carries `dir`, set at spec-resolution time
  -- and independent of load state.
  local ok_lazy, lazy_cfg = pcall(require, "lazy.core.config")
  if ok_lazy and type(lazy_cfg) == "table" and type(lazy_cfg.plugins) == "table" then
    for _, plugin in pairs(lazy_cfg.plugins) do
      if type(plugin) == "table" then add(plugin.dir) end
    end
  end

  -- vim.pack (Neovim 0.12+): entries expose the install path either directly
  -- or nested under `spec`, depending on version.
  if type(vim.pack) == "table" and type(vim.pack.get) == "function" then
    -- `info = false`: only the paths are read here; the default runs `git version` synchronously and then
    -- asks git about every plugin (a 215 ms freeze on the first resolution). An older vim.pack ignores it.
    local ok_pack, entries = pcall(vim.pack.get, nil, { info = false })
    if ok_pack and type(entries) == "table" then
      for _, e in ipairs(entries) do
        if type(e) == "table" then
          -- `vim.pack.get()` entries carry no annotations, so the two paths
          -- this reads are fetched by key rather than off a bare `table`.
          add(vim.tbl_get(e, "path") or vim.tbl_get(e, "spec", "path"))
        end
      end
    end
  end

  _pdir_str, _pdir_list = s, dirs
  return dirs
end

---Build a map from top-level module name to the plugin dirs that provide it,
---by listing each plugin's `lua/` directory exactly once.
---
---Indexing up front costs one readdir per plugin, but turns the common case —
---a dotted token that is not a module at all — into a single failed hash
---lookup instead of a stat against every installed plugin.
---@internal
---@return table<string, string[]>
local function get_plugin_lua_index()
  local s = vim.o.runtimepath
  if s == _pidx_str and _pidx_map then return _pidx_map end

  local map = {}
  for _, dir in ipairs(get_plugin_dirs()) do
    local lua_dir = M.join(dir, "lua")
    local fs = vim.uv.fs_scandir(lua_dir)
    if fs then
      while true do
        local name, typ = vim.uv.fs_scandir_next(fs)
        if not name then break end
        -- A module root is either `lua/<root>/` or `lua/<root>.lua`.
        local root = (typ == "directory") and name or name:match("^(.+)%.lua$")
        if root then
          local bucket = map[root]
          if bucket then
            bucket[#bucket + 1] = dir
          else
            map[root] = { dir }
          end
        end
      end
    end
  end

  _pidx_str, _pidx_map = s, map
  return map
end

---Strategy 4: resolve a dotted module against the `lua/` tree of every known
--- plugin, including ones that are installed but not loaded.
---
--- This is what makes a `require("x.y")` pointing into a lazily-loaded plugin
--- resolvable: until that plugin is loaded its directory is on neither the
--- runtimepath nor `package.path`, so strategies 1 and 3 both miss it.
---@param module string  Dotted module name, e.g. "a.b.c"
---@return string|nil  absolute path of first match
function M.search_in_plugin_dirs(module)
  if type(module) ~= "string" or module == "" then return nil end

  local root = module:match("^([^.]+)")
  if not root then return nil end

  local dirs = get_plugin_lua_index()[root]
  if not dirs then return nil end

  local rel = module:gsub("%.", "/")
  for i = 1, #dirs do
    for _, cand in ipairs({ rel .. ".lua", rel .. "/init.lua" }) do
      local p = M.join(dirs[i], "lua", cand)
      if M.exists(p) then return p end
    end
  end
  return nil
end

---Resolve a dotted Lua module name to a file, trying every strategy in order:
--- runtimepath → `package.path` → plugin install dirs.
---
--- The plugin-dir step runs last on purpose: it is the broadest and least
--- precise, so a loaded module always wins over a merely installed one.
---@param module string  Dotted module name, e.g. "a.b.c"
---@return string|nil  absolute path
---@see M.search_in_rtp, M.search_with_package_path, M.search_in_plugin_dirs
function M.search_module(module)
  if type(module) ~= "string" or module == "" then return nil end
  local rel = module:gsub("%.", "/")
  return M.search_in_rtp({ rel .. ".lua", rel .. "/init.lua" })
    or M.search_with_package_path(module)
    or M.search_in_plugin_dirs(module)
end

return M
