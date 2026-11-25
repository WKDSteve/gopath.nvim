---@module 'gopath.resolvers.lua.value_origin'
---@brief From a cursor chain like `cfg.foo` resolve to initializer location in module/current file.

local CHN = require("gopath.resolvers.lua.chain")
local BIX = require("gopath.resolvers.lua.binding_index")
local ALX = require("gopath.resolvers.lua.alias_index")
local PATH = require("gopath.util.path")
local CROSS = require("gopath.util.cross")
local AST = require("gopath.resolvers.lua.ts_lua_ast")
local DOT = require("gopath.util.dotted")

local M = {}

-- The last Lua file looked into: its document (read and parsed once) and its roots. One entry, so a
-- big file costs one parse per gF, not one per root tried, and nothing piles up. Keyed on the path,
-- mtime and size: the file is read from disk (it need not be an open buffer), so there is no
-- changedtick to key off.
---@type { abs: string, stamp: string, doc: GopathLuaDoc, primary: string[], secondary: string[] }|nil
local doc_cache = nil

---Candidate root identifiers of a file, from its top-level lines only (a `local x = {` inside a
---function is private state, never what `require` hands out).
---  primary:   the identifier of a top-level `return x`, then "M" -- the module's own table
---  secondary: every other top-level `local x = {` / `local x = setmetatable(` -- a last resort
---@internal
---@param lines_ string[]
---@return string[] primary
---@return string[] secondary
local function infer_roots_from_lines(lines_)
  local primary, secondary = {}, {}
  for i = 1, #lines_ do
    local s = lines_[i] or ""
    local rid = s:match("^return%s+([%w_]+)%s*$")
    if rid then primary[#primary + 1] = rid end
    local id = s:match("^local%s+([%w_]+)%s*=%s*{")
      or s:match("^local%s+([%w_]+)%s*=%s*setmetatable%s*%(")
    if id then secondary[#secondary + 1] = id end
  end
  primary[#primary + 1] = "M"
  local TBL = require("lib.lua.tables")
  primary = TBL.dedup_list(primary)
  local is_primary = {}
  for _, r in ipairs(primary) do
    is_primary[r] = true
  end
  return primary,
    vim.tbl_filter(function(r)
      return not is_primary[r]
    end, TBL.dedup_list(secondary))
end

---The document and roots of `abs`, from cache while the file is unchanged.
---@internal
---@param abs string
---@return GopathLuaDoc|nil doc
---@return string[] primary
---@return string[] secondary
local function get_doc(abs)
  -- Nanoseconds too: a save within the same second (same size) must not hand back the old tree.
  local st = vim.uv.fs_stat(abs)
  local stamp = st and (st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size) or "?"
  if doc_cache and doc_cache.abs == abs and doc_cache.stamp == stamp then
    return doc_cache.doc, doc_cache.primary, doc_cache.secondary
  end
  local doc = require("gopath.resolvers.lua.table_locator").read_doc(abs)
  if not doc then return nil, {}, {} end
  local primary, secondary = infer_roots_from_lines(doc.lines)
  doc_cache = { abs = abs, stamp = stamp, doc = doc, primary = primary, secondary = secondary }
  return doc, primary, secondary
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
      local parts = DOT.split(entry.chain)
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

---Locate `suffix`/`last_key` under each of `roots` in turn.
---@internal
---@param doc GopathLuaDoc
---@param roots string[]
---@param suffix string  ".cfg.highlight" below the root, or ""
---@param last_key string|nil
---@return table|nil hit  the first table that holds `last_key` (or the first table, without a key)
---@return table|nil keyless  else the first table found that lacks `last_key`
local function locate_in(doc, roots, suffix, last_key)
  local TL = require("gopath.resolvers.lua.table_locator")
  local keyless
  for _, root in ipairs(roots) do
    local hit = TL.locate_doc(doc, root .. suffix, last_key)
    if hit and not hit.key_missing then return hit, nil end
    keyless = keyless or hit
  end
  return nil, keyless
end

---Where one of `roots` defines `key` itself: `function R.key()`, `function R:key()` or
---`R.key = ...`, with R one of `roots` and nothing between (no `local function key()`, no
---`R.sub.key`). The first one in the file.
---@internal
---@param doc GopathLuaDoc
---@param roots string[]
---@param key string
---@return integer|nil line
---@return integer|nil col
local function definition_of(doc, roots, key)
  if not doc.root or not doc.src then return nil, nil end
  local want = {}
  for _, r in ipairs(roots) do
    want[r] = true
  end
  local best_l, best_c
  local function consider(node)
    local c = AST.chain_of(node, doc.src)
    if c and #c == 2 and want[c[1]] and c[2] == key then
      local l, col = AST.node_start(node)
      if not best_l or l < best_l or (l == best_l and col < best_c) then
        best_l, best_c = l, col
      end
    end
  end
  local decl = AST.get_query("vo_fn_decl_name", "(function_declaration name: (_) @name)")
  if decl then
    for _, node in decl:iter_captures(doc.root, doc.src) do
      consider(node)
    end
  end
  local assign =
    AST.get_query("vo_assign_lhs", "(assignment_statement (variable_list name: (_) @lhs))")
  if assign then
    for _, node in assign:iter_captures(doc.root, doc.src) do
      consider(node)
    end
  end
  return best_l, best_c
end

---Find what `extra_chain`/`last_key` points at in `abs`. In order: a table of the module's own
---roots (`return x`, "M") that holds the key; for a key straight on that table, its definition
---(`config.get` for a `function M.get()`, which no constructor holds); that table without the
---key (its first line); and only then the file's other top-level tables, private state the
---module does not hand out.
---@internal
---@param abs string
---@param extra_chain string
---@param last_key string|nil
---@param chain string[]
---@return GopathResult|nil
local function locate_value(abs, extra_chain, last_key, chain)
  local doc, primary, secondary = get_doc(abs)
  if not doc then return nil end
  local suffix = extra_chain ~= "" and ("." .. extra_chain) or ""

  local hit, keyless = locate_in(doc, primary, suffix, last_key)
  if not hit and last_key and extra_chain == "" then
    local l, c = definition_of(doc, primary, last_key)
    if l then
      return {
        language = "lua",
        kind = "field",
        path = abs,
        range = { line = l, col = c or 1 },
        chain = chain,
        source = "treesitter",
        confidence = 0.85,
      }
    end
  end
  if not hit and not keyless then
    hit, keyless = locate_in(doc, secondary, suffix, last_key)
  end
  hit = hit or keyless
  if not hit then return nil end
  return {
    language = "lua",
    kind = last_key and "field" or "table",
    path = hit.path,
    range = { line = hit.key_line or hit.tbl_start or 1, col = hit.key_col or 1 },
    chain = chain,
    source = "treesitter",
    confidence = last_key and 0.9 or 0.8,
  }
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

    return locate_value(abs, base_res.extra_chain or "", last_key, chain.chain)
      or {
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
    return locate_value(abs, base_res.extra_chain or "", last_key, chain.chain)
  end

  return nil
end

return M
