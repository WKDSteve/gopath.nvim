---@module 'gopath.resolvers.lua.value_origin'
---@brief From a cursor chain like `cfg.foo` resolve to initializer location in module/current file.

local CHN = require("gopath.resolvers.lua.chain")
local BIX = require("gopath.resolvers.lua.binding_index")
local ALX = require("gopath.resolvers.lua.alias_index")
local PATH = require("gopath.util.path")
local CROSS = require("gopath.util.cross")

local M = {}

---@class _RootsCache
---@field mtime integer
---@field roots string[]

-- abs file path -> _RootsCache. Invalidated on mtime change (these files are
-- read via vim.fn.readfile, not necessarily open buffers, so there is no
-- changedtick to key off — unlike binding_index.lua's per-buffer cache).
local roots_cache = {}

---Infer candidate root identifiers ("M", locally-declared tables, the
---identifier returned at the end of the file) from the file's lines.
---@internal
---@param lines_ string[]
---@return string[]
local function infer_roots_from_lines(lines_)
  local roots = { "M" }
  for i = 1, #lines_ do
    local s = lines_[i] or ""
    local id = s:match("^%s*local%s+([%w_]+)%s*=%s*{")
      or s:match("^%s*local%s+([%w_]+)%s*=%s*setmetatable%s*%(")
    if id then roots[#roots + 1] = id end
    local rid = s:match("^%s*return%s+([%w_]+)%s*$")
    if rid then roots[#roots + 1] = rid end
  end
  return require("lib.lua.tables").dedup_list(roots)
end

---Get the inferred roots for `abs`, from cache when the file's mtime is
---unchanged since the last inference, avoiding a re-read + re-scan of every
---line on repeated lookups against the same (unedited) file.
---@internal
---@param abs string
---@return string[]
local function get_roots_cached(abs)
  local mtime = vim.fn.getftime(abs)
  local entry = roots_cache[abs]
  if entry and entry.mtime == mtime then return entry.roots end

  local lines = vim.fn.readfile(abs)
  local roots = infer_roots_from_lines(lines)
  roots_cache[abs] = { mtime = mtime, roots = roots }
  return roots
end

---Split a dotted string ("a.b.c") into its segments.
---@internal
---@param s string
---@return string[]
local function split_by_dot(s)
  local t = {}
  for p in s:gmatch("[^%.]+") do
    t[#t + 1] = p
  end
  return t
end

---Resolve base identifier to either:
---  a) { kind="module", module="x.y", extra_chain="cfg.highlight" }
---  b) { kind="current", base="M",   extra_chain="cfg.highlight" }
---Follows the alias chain (require/chain/id entries) up to 32 hops to guard
---against a cyclic alias graph.
---@internal
---@param base_id string
---@param initial_chain string[]|nil
---@param bind_map table<string,string>
---@param alias_map table<string,LuaAliasEntry>
---@return { kind: '"module"'|'"current"', module: string|nil, base: string|nil, extra_chain: string }|nil
local function resolve_base(base_id, initial_chain, bind_map, alias_map)
  local chain_suffix = initial_chain and table.concat(initial_chain, ".") or ""
  local current = base_id
  local suffix = chain_suffix

  -- First check direct binding "local id = require 'mod'"
  local be = bind_map[current]
  if be then return { kind = "module", module = be, extra_chain = suffix } end

  local guard = 0
  while guard < 32 and alias_map[current] do
    guard = guard + 1
    local entry = alias_map[current]
    if entry.kind == "require" and entry.module then
      return { kind = "module", module = entry.module, extra_chain = suffix }
    elseif entry.kind == "chain" and entry.chain then
      -- entry.chain might be "C.cfg.highlight" or "M"
      local parts = split_by_dot(entry.chain)
      if #parts == 0 then break end
      local head = parts[1]
      if #parts > 1 then
        -- prepend remaining chain before our suffix
        local rest = {}
        for i = 2, #parts do
          rest[#rest + 1] = parts[i]
        end
        suffix = table.concat(rest, ".") .. (suffix ~= "" and "." .. suffix or "")
      end
      current = head
    elseif entry.kind == "id" and entry.id then
      current = entry.id
    else
      break
    end
  end

  -- If base resolves to M (same file table), we treat it as current file.
  if current == "M" then return { kind = "current", base = "M", extra_chain = suffix } end

  -- As a last resort: if `current` is another id bound to require via bind_map.
  local be2 = bind_map[current]
  if be2 then return { kind = "module", module = be2, extra_chain = suffix } end

  return nil
end

---Canonical spelling of a path this module is about to key on and report.
---
---`GopathResult.path` is forward-slash canonical across the pipeline (see
---`gopath.util.cross`, and the same `to_forward` call in
---`resolvers/common/filetoken.lua`). The two sources this resolver draws an
---absolute path from do not honour that on Windows by themselves:
---`nvim_buf_get_name` returns whatever spelling Neovim stored for the buffer
---(backslashes when it was opened by a native path), and
---`PATH.search_with_package_path` hands back a `package.searchpath` result,
---which is backslash-spelled there too. Left alone they make one file arrive
---under two names, and the name is not just decoration: `roots_cache` below is
---keyed on it, and `gopath.commands` feeds it to `tailsearch.sanitize`, whose
---drive strip is anchored to "<drive>:/" and so turns "C:\dir\x.lua" into the
---bogus tail "C/dir/x.lua" while "C:/dir/x.lua" correctly yields "dir/x.lua".
---Normalising at the two sources keeps every return below on one spelling.
---@internal
---@param abs string
---@return string
local function canonical(abs)
  return CROSS.to_forward(abs)
end

---Try to locate `extra_chain`/`last_key` inside `abs`, trying every plausible
---root identifier inferred from the file (see `infer_roots_from_lines`).
---@internal
---@param abs string  Absolute file path to search in
---@param extra_chain string  Dotted chain below the root, e.g. "cfg.highlight"
---@param last_key string|nil  Final chain segment to locate as a key, if any
---@return table|nil  Result of `table_locator.locate` (one that holds `last_key` first), or nil
local function try_locate_with_roots(abs, extra_chain, last_key)
  local tl = require("gopath.resolvers.lua.table_locator")
  if type(abs) ~= "string" or abs == "" then return nil end

  local roots = get_roots_cached(abs)
  local suffix = (extra_chain and extra_chain ~= "") and ("." .. extra_chain) or ""
  -- A root whose table holds the key wins over an earlier one that only has the table.
  local keyless
  for _, root in ipairs(roots) do
    local base_chain = root .. suffix
    local hit = tl.locate(abs, base_chain, last_key)
    if hit and not hit.key_missing then return hit end
    keyless = keyless or hit
  end

  return keyless
end

---The definition of `key` in module `module` (`function M.key()`, `M.key = ...`), through the
---symbol locator with the base already resolved here (aliases included, which the
---binding map the locator usually gets does not know).
---@internal
---@param base string
---@param module string
---@param key string
---@return GopathResult|nil  nil when the module defines no such symbol
local function symbol_definition(base, module, key)
  local SL = require("gopath.resolvers.lua.symbol_locator")
  local r = SL.via_treesitter({ base = base, chain = { key } }, { [base] = module })
  if r and r.kind == "field" then return r end
  return nil
end

---@return GopathResult|nil
function M.resolve()
  local chain = CHN.get_chain_at_cursor()
  if not chain then return nil end

  local last_key = (#chain.chain > 0) and chain.chain[#chain.chain] or nil

  -- Resolve the *table* the leaf lives in from everything but the final
  -- segment; last_key locates the leaf separately inside that table. Passing
  -- the full chain here would make base_chain point one level too deep and
  -- double up the key in table_locator's dotted-fallback pattern, so a chain
  -- like cfg.highlight.enable_x could never be located.
  local chain_wo_last = {}
  for i = 1, #chain.chain - 1 do
    chain_wo_last[i] = chain.chain[i]
  end

  local bind_map = BIX.get_map()
  local alias_map = ALX.get_map()
  local base_res = resolve_base(chain.base, chain_wo_last, bind_map, alias_map)
  if not base_res then return nil end

  if base_res.kind == "module" then
    local abs = PATH.search_module(base_res.module)
    if not abs then return nil end
    abs = canonical(abs)

    local extra = base_res.extra_chain or ""
    local hit = try_locate_with_roots(abs, extra, last_key)
    -- A key of the module's root table that its constructor does not hold (`config.get` for
    -- a `function M.get()`) is a definition, not a value: without this, the answer would be
    -- the table's first line (or the bare module) and the pipeline would stop before the
    -- symbol locator. A missing key one level deeper (`cfg.highlight.nope`) still lands on
    -- its table, the best answer there.
    if last_key and extra == "" and (not hit or hit.key_missing) then
      local def = symbol_definition(chain.base, base_res.module, last_key)
      if def then return def end
    end
    if hit then
      return {
        language = "lua",
        kind = last_key and "field" or "table",
        path = hit.path,
        range = { line = hit.key_line or hit.tbl_start or 1, col = hit.key_col or 1 },
        chain = chain.chain,
        source = "treesitter",
        confidence = last_key and 0.9 or 0.8,
      }
    end

    return {
      language = "lua",
      kind = "module",
      path = abs,
      range = nil,
      chain = chain.chain,
      source = "treesitter",
      confidence = 0.5,
    }
  end

  if base_res.kind == "current" then
    local abs = vim.api.nvim_buf_get_name(0)
    if type(abs) ~= "string" or abs == "" then return nil end
    abs = canonical(abs)

    -- Do NOT hard-code "M" here -- try the roots as well, or a module using a
    -- different local name for its table resolves to nothing.
    local hit = try_locate_with_roots(abs, base_res.extra_chain or "", last_key)
    if hit then
      return {
        language = "lua",
        kind = last_key and "field" or "table",
        path = hit.path,
        range = { line = hit.key_line or hit.tbl_start or 1, col = hit.key_col or 1 },
        chain = chain.chain,
        source = "treesitter",
        confidence = last_key and 0.9 or 0.8,
      }
    end
  end

  return nil
end

return M
