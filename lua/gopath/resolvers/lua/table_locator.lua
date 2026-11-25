---@module 'gopath.resolvers.lua.table_locator'
---@brief Locate a table (and optionally a key initializer) by a dotted base chain in a Lua file.
---@desc Robust against newlines after "=", bracketed keys, return-blocks and tables nested in function calls.
---@description
--- `M.locate` tries a Treesitter-based strategy first (`ts_locate`, real
--- queries over table_constructor/field/assignment_statement nodes — see
--- `ts_lua_ast`), which is precise and immune to the depth-confusion bugs
--- textual brace-counting is prone to. When no "lua" parser is available, or
--- none of its tiers match, it falls back to `legacy_locate`: the original
--- line-pattern implementation, kept verbatim as a safety net so every
--- previously-working case keeps working even where the treesitter path
--- doesn't (yet) cover it.

local AST = require("gopath.resolvers.lua.ts_lua_ast")
local DOT = require("gopath.util.dotted")

local M = {}

-- ========= legacy (line-pattern) helpers =========

---Escape a string for use as a literal Lua pattern.
---@internal
---@param str string
---@return string
local function esc(str)
  return (str:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"))
end

---Find the "balanced" table region starting at a line whose first `{` opens the table.
---Tolerates nested braces.
---@internal
---@param lines string[]
---@param start_line integer
---@return integer|nil end_line 1-based
local function find_balanced_region(lines, start_line)
  local depth, i = 0, start_line
  while i <= #lines do
    local s = lines[i]
    -- strip line comments to avoid counting braces in comments
    s = s:gsub("%-%-.*$", "")
    for j = 1, #s do
      local ch = s:sub(j, j)
      if ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
        if depth == 0 then return i end
      end
    end
    i = i + 1
  end
  return nil
end

---Find a table opening after `=` for a given dotted LHS, on the same or a
---following line, tolerating an intervening function call before the `{`.
---@internal
---@param lines string[]
---@param dotted string
---@return integer|nil start_line
---@return integer|nil end_line
local function find_direct_table_loose(lines, dotted)
  local pat_inline = "^%s*" .. esc(dotted) .. "%s*=%s*{"
  local pat_eq = "^%s*" .. esc(dotted) .. "%s*=%s*(.*)$"

  for i = 1, #lines do
    local s = lines[i]
    if s:match(pat_inline) then
      local e = find_balanced_region(lines, i)
      if e then return i, e end
    end
    local rhs = s:match(pat_eq)
    if rhs then
      -- same line: look for first "{"
      local c = rhs:find("{")
      if c then
        local e = find_balanced_region(lines, i)
        if e then return i, e end
      else
        -- next non-empty/non-comment line that starts a "{"
        local j = i + 1
        while j <= #lines do
          local ln = lines[j]
          if ln:match("^%s*$") or ln:match("^%s*%-%-") then
            j = j + 1
          elseif ln:match("^%s*{") or ln:find("{") then
            local e = find_balanced_region(lines, j)
            if e then return j, e end
            break
          else
            break
          end
        end
      end
    end
  end
  return nil, nil
end

---Find "ROOT.chain = { ... }" and return its region.
---@internal
---@param lines string[]
---@param dotted string
---@return integer|nil start_line
---@return integer|nil end_line
local function find_direct_table(lines, dotted)
  local s1, e1 = find_direct_table_loose(lines, dotted)
  if s1 then return s1, e1 end
  return nil, nil
end

---Find any-root direct assignment: `<ROOT>.<chain_wo_root> = { ... }`.
---@internal
---@param lines string[]
---@param chain_wo_root string
---@return string|nil root
---@return integer|nil start_line
---@return integer|nil end_line
local function find_anyroot_direct_table(lines, chain_wo_root)
  local pi = "^%s*([%w_]+)%s*%." .. esc(chain_wo_root) .. "%s*=%s*{"
  local pe = "^%s*([%w_]+)%s*%." .. esc(chain_wo_root) .. "%s*=%s*(.*)$"
  for i = 1, #lines do
    local s = lines[i]
    local root_inline = s:match(pi)
    if root_inline then
      local e = find_balanced_region(lines, i)
      if e then return root_inline, i, e end
    end
    local rhs = s:match(pe)
    if rhs then
      local c = rhs:find("{")
      if c then
        local e = find_balanced_region(lines, i)
        if e then return s:match(pe), i, e end
      else
        local j = i + 1
        while j <= #lines do
          local ln = lines[j]
          if ln:match("^%s*$") or ln:match("^%s*%-%-") then
            j = j + 1
          elseif ln:match("^%s*{") or ln:find("{") then
            local e = find_balanced_region(lines, j)
            if e then
              local r = s:match(pe)
              return r, j, e
            end
            break
          else
            break
          end
        end
      end
    end
  end
  return nil, nil, nil
end

---Find the outermost `return { ... }` region.
---@internal
---@param lines string[]
---@return integer|nil start_line
---@return integer|nil end_line
local function find_return_table_region(lines)
  for i = 1, #lines do
    local s = lines[i]
    if s:match("^%s*return%s*{") then
      local e = find_balanced_region(lines, i)
      if e then return i, e end
    end
  end
  return nil, nil
end

---Strip line comments and string contents so their braces are not counted.
---@internal
---@param s string
---@return string
local function scrub_for_braces(s)
  -- drop line comments
  s = s:gsub("%-%-.*$", "")
  -- drop simple balanced string bodies (keeps quotes to not break patterns)
  s = s:gsub('%b""', '""')
  s = s:gsub("%b''", "''")
  return s
end

---Inside region `s..e`, find a `key = { ... }` nested table at depth 1 and
---return its region. Supports bare and bracketed keys; depth-aware so a
---deeper nested table with the same key name is not matched by mistake.
---@internal
---@param lines string[]
---@param s integer region start line
---@param e integer region end line
---@param key string
---@return integer|nil start_line
---@return integer|nil end_line
local function find_child_table(lines, s, e, key)
  local ke = esc(key)
  local heads = {
    "^%s*" .. ke .. "%s*=%s*{", -- key = {
    '^%s*%["' .. ke .. '"%]%s*=%s*{', -- ["key"] = {
    "^%s*%['" .. ke .. "'%]%s*=%s*{", -- ['key'] = {
    "[%[{,]%s*" .. ke .. "%s*=%s*{", -- , key = {  (also after a comma/block start)
    '%[{"%s*%["' .. ke .. '"%]%s*=%s*{', -- , ["key"] = {
    "[%[{,]%s*%['" .. ke .. "'%]%s*=%s*{", -- , ['key'] = {
  }

  -- depth is the brace nesting *before* line i's own braces are counted, so
  -- it reads 1 exactly on lines that are direct children of the region
  -- opened at `s` (whose own opening brace only takes effect after it is
  -- processed in the loop below). A separate pre-scan of line `s` here would
  -- double-count that line's opening brace and make depth reach 2 one line
  -- too early, so every child match after the first sibling would be missed.
  local depth = 0

  for i = s, e do
    local raw = lines[i] or ""
    local line = scrub_for_braces(raw)

    if depth == 1 then
      for _, pat in ipairs(heads) do
        if line:match(pat) then
          local end_line = find_balanced_region(lines, i)
          if end_line then return i, end_line end
        end
      end
    end

    for j = 1, #line do
      local ch = line:sub(j, j)
      if ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = math.max(0, depth - 1)
      end
    end
  end

  return nil, nil
end
---Inside region `s..e`, find `key =` (any value) and return the key's position.
---@internal
---@param lines string[]
---@param s integer region start line
---@param e integer region end line
---@param key string
---@return integer|nil line
---@return integer|nil col
local function find_key_assignment(lines, s, e, key)
  local ke = esc(key)
  local patterns = {
    "^%s*" .. ke .. "%s*=", -- key =
    '^%s*%["' .. ke .. '"%]%s*=', -- ["key"] =
    "^%s*%['" .. ke .. "'%]%s*=", -- ['key'] =
  }
  for i = s, e do
    local line = lines[i]
    for _, pat in ipairs(patterns) do
      local c = line:find(pat)
      if c then return i, c end
    end
  end
  return nil, nil
end

---Find the first `key = { ... }` anywhere in the file (useful for tables
---nested inside a function call).
---@internal
---@param lines string[]
---@param key string
---@return integer|nil start_line
---@return integer|nil end_line
local function find_global_table(lines, key)
  local k = esc(key)
  local pat_inline = "%f[%w_]" .. k .. "%f[^%w_]%s*=%s*{"
  local pat_eq = "%f[%w_]" .. k .. "%f[^%w_]%s*=%s*$"

  for i = 1, #lines do
    local s = lines[i]
    if s:match(pat_inline) then
      local e = find_balanced_region(lines, i)
      if e then return i, e end
    end
    if s:match(pat_eq) then
      local j = i + 1
      while j <= #lines do
        local ln = lines[j]
        if ln:match("^%s*$") or ln:match("^%s*%-%-") then
          j = j + 1
        elseif ln:match("^%s*{") or ln:find("{") then
          local e = find_balanced_region(lines, j)
          if e then return j, e end
          break
        else
          break
        end
      end
    end
  end
  return nil, nil
end

-- ========= legacy (line-pattern) locate =========

---Legacy line-pattern implementation of `M.locate`, kept as the fallback
---path for files/cases the treesitter strategy (`ts_locate`) can't handle
---(no parser available, or none of its tiers matched).
---@internal
---@param lines string[]
---@param segs string[]  { ROOT, cfg, highlight, ... }
---@param seek_key string|nil
---@param abs_path string
---@return { path:string, key_line:integer|nil, key_col:integer|nil, tbl_start:integer|nil, tbl_end:integer|nil, key_missing:true|nil }|nil
local function legacy_locate(lines, segs, seek_key, abs_path)
  -- final found region
  local found = false
  local fs, fe -- integers (table start/end)

  -- 1) direct: ROOT.cfg.highlight = { ... }
  do
    local s1, e1 = find_direct_table(lines, table.concat(segs, "."))
    if s1 and e1 then
      fs, fe, found = s1, e1, true
    end
  end

  -- 2) progressive: ROOT.cfg = { ... } -> child "highlight" -> ...
  if (not found) and (#segs >= 2) then
    local top = table.concat({ segs[1], segs[2] or "" }, "."):gsub("%.%s*$", "")
    if top ~= "" then
      local t_s, t_e = find_direct_table(lines, top)
      if t_s and t_e then
        local s, e = t_s, t_e
        local ok = true
        for i = 3, #segs do
          local s2, e2 = find_child_table(lines, s, e, segs[i])
          if not s2 or not e2 then
            ok = false
            break
          end
          s, e = s2, e2
        end
        if ok then
          fs, fe, found = s, e, true
        end
      end
    end
  end

  -- 3) any-root: <ROOT>.(cfg.highlight) = { ... }
  if (not found) and (#segs >= 2) then
    local chain_wo_root = table.concat(segs, ".", 2)
    local _, s2, e2 = find_anyroot_direct_table(lines, chain_wo_root)
    if s2 and e2 then
      fs, fe, found = s2, e2, true
    end
  end

  -- 4) return { cfg = { highlight = ... } } : descend inside outer return table
  if not found then
    local r_s, r_e = find_return_table_region(lines)
    if r_s and r_e then
      local s, e = r_s, r_e
      local ok = true
      for i = 1, #segs do
        local s2, e2 = find_child_table(lines, s, e, segs[i])
        if not s2 or not e2 then
          ok = false
          break
        end
        s, e = s2, e2
      end
      if ok then
        fs, fe, found = s, e, true
      end
    end
  end

  -- 5) global fallback: start from segs[2] inside any table, then descend
  if (not found) and (#segs >= 2) then
    local g_s, g_e = find_global_table(lines, segs[2])
    if g_s and g_e then
      local s, e = g_s, g_e
      local ok = true
      for i = 3, #segs do
        local s2, e2 = find_child_table(lines, s, e, segs[i])
        if not s2 or not e2 then
          ok = false
          break
        end
        s, e = s2, e2
      end
      if ok then
        fs, fe, found = s, e, true
      end
    end
  end

  -- 6) nothing found: final single-line field assignment fallback: ROOT.cfg.highlight.key = ...
  if not found then
    if seek_key then
      -- Escape the whole joined chain as one literal (same convention as
      -- `find_direct_table_loose`/`find_anyroot_direct_table` above): segments
      -- can carry Lua-pattern-magic characters when they came from a
      -- string-literal bracket-index segment (e.g. `t["a.b%c"]`) via the
      -- treesitter chain extractor, and an unescaped segment here could turn
      -- into a malformed pattern and make `line:find(pat)` below error out.
      local dotted = esc(table.concat(segs, "."))
      local ke = esc(seek_key)
      local patterns = {
        "^%s*" .. dotted .. "%." .. ke .. "%s*=",
        "^%s*" .. dotted .. '%["' .. ke .. '"%]%s*=',
        "^%s*" .. dotted .. "%['" .. ke .. "'%]%s*=",
      }
      for i = 1, #lines do
        local line = lines[i]
        for _, pat in ipairs(patterns) do
          local c = line:find(pat)
          if c then
            return { path = abs_path, key_line = i, key_col = c, tbl_start = nil, tbl_end = nil }
          end
        end
      end
    end
    return nil
  end

  -- 7) If a key is requested, locate it inside the found table region.
  if seek_key then
    local kl, kc = find_key_assignment(lines, fs, fe, seek_key)
    if kl then
      return { path = abs_path, key_line = kl, key_col = kc, tbl_start = fs, tbl_end = fe }
    end
  end

  -- 8) No key given or key not found: land at table start (`key_missing` tells the two apart).
  return {
    path = abs_path,
    key_line = fs,
    key_col = 1,
    tbl_start = fs,
    tbl_end = fe,
    key_missing = seek_key and true or nil,
  }
end

-- ========= treesitter (primary) helpers =========

---Direct `field` child of `tbl_node` (depth-1 only — never descends into a
---nested table_constructor) whose literal key equals `key`.
---@internal
---@param tbl_node TSNode  type() == "table_constructor"
---@param key string
---@param src string
---@return TSNode|nil field
local function ts_direct_field(tbl_node, key, src)
  for i = 0, tbl_node:named_child_count() - 1 do
    local child = tbl_node:named_child(i)
    if child and child:type() == "field" and AST.field_key_text(child, src) == key then
      return child
    end
  end
  return nil
end

---Like `ts_direct_field`, but only returns the field's value when it is
---itself a table_constructor (used to descend a chain one level).
---@internal
---@param tbl_node TSNode
---@param key string
---@param src string
---@return TSNode|nil child_table
local function ts_direct_child_table(tbl_node, key, src)
  local field = ts_direct_field(tbl_node, key, src)
  if not field then return nil end
  local value = field:field("value")[1]
  if value and value:type() == "table_constructor" then return value end
  return nil
end

---Descend `node` through `segs` one direct-child table per segment.
---@internal
---@param node TSNode
---@param segs string[]
---@param src string
---@return TSNode|nil
local function ts_descend(node, segs, src)
  local cur = node
  for i = 1, #segs do
    -- The next node into its own local, checked, then assigned: `cur` stays a
    -- TSNode for the next iteration's call instead of widening to TSNode|nil.
    local child = ts_direct_child_table(cur, segs[i], src)
    if not child then return nil end
    cur = child
  end
  return cur
end

---First `field` node anywhere in `scope`'s subtree (any depth) whose literal
---key equals `key`. Mirrors legacy `find_key_assignment`'s non-depth-aware
---scan, used only for the final "find the requested key inside an already
----resolved table" step — never for chain descent, which must stay depth-exact.
---@internal
---@param scope TSNode
---@param key string
---@param src string
---@param want_table boolean  when true, only match fields whose value is a table_constructor, and return that value node instead of the field
---@return TSNode|nil
local function ts_find_field_anywhere(scope, key, src, want_table)
  local q = AST.get_query("field_any", "(field) @f")
  if not q then return nil end
  for _, node in q:iter_captures(scope, src) do
    if AST.field_key_text(node, src) == key then
      if not want_table then return node end
      local value = node:field("value")[1]
      if value and value:type() == "table_constructor" then return value end
    end
  end
  return nil
end

---All `assignment_statement`s whose LHS resolves to a literal dotted chain
---and whose RHS is a table_constructor, in document order.
---@internal
---@param root TSNode
---@param src string
---@return { chain:string[], tbl:TSNode }[]
local function ts_collect_table_assignments(root, src)
  local q = AST.get_query(
    "assign_tbl",
    [[
      (assignment_statement
        (variable_list
          name: (_) @lhs)
        (expression_list
          value: (table_constructor) @tbl))
    ]]
  )
  if not q then return {} end

  local out, pending_lhs = {}, nil
  for id, node in q:iter_captures(root, src) do
    local cap = q.captures[id]
    if cap == "lhs" then
      pending_lhs = node
    elseif cap == "tbl" and pending_lhs then
      local chain = AST.chain_of(pending_lhs, src)
      if chain then out[#out + 1] = { chain = chain, tbl = node } end
      pending_lhs = nil
    end
  end
  return out
end

---Outermost `table_constructor` of a `return { ... }` statement, if any.
---@internal
---@param root TSNode
---@param src string
---@return TSNode|nil
local function ts_find_return_table(root, src)
  local q =
    AST.get_query("return_tbl", "(return_statement (expression_list (table_constructor) @tbl))")
  if not q then return nil end
  local iter = q:iter_captures(root, src)
  local _, node = iter()
  return node
end

---Any `assignment_statement` whose LHS resolves to exactly `chain` (any RHS).
---Used for the "no table at all" single-field fallback.
---@internal
---@param root TSNode
---@param chain string[]
---@param src string
---@return TSNode|nil lhs
local function ts_find_assignment_lhs(root, chain, src)
  local q = AST.get_query(
    "assign_lhs",
    [[
      (assignment_statement
        (variable_list
          name: (_) @lhs))
    ]]
  )
  if not q then return nil end
  for _, node in q:iter_captures(root, src) do
    local c = AST.chain_of(node, src)
    if c and AST.chains_equal(c, chain) then return node end
  end
  return nil
end

---Build a locate-result once a table region has been resolved via treesitter.
---@internal
---@param abs_path string
---@param tbl_node TSNode
---@param seek_key string|nil
---@param src string
---@return table
local function ts_table_hit(abs_path, tbl_node, seek_key, src)
  local fs, fe = AST.node_lines(tbl_node)
  if seek_key then
    local field = ts_find_field_anywhere(tbl_node, seek_key, src, false)
    if field then
      local name = field:field("name")[1] or field
      local kl, kc = AST.node_start(name)
      return { path = abs_path, key_line = kl, key_col = kc, tbl_start = fs, tbl_end = fe }
    end
  end
  -- No key given or key not found: land at table start (`key_missing` tells the two apart).
  return {
    path = abs_path,
    key_line = fs,
    key_col = 1,
    tbl_start = fs,
    tbl_end = fe,
    key_missing = seek_key and true or nil,
  }
end

---Treesitter-based strategy, mirroring `legacy_locate`'s tiers 1-6 with real
---syntax-tree queries instead of line patterns. Returns nil (falling through
---to `legacy_locate`) when no "lua" parser is available or none of its tiers
---match.
---@internal
---@param doc GopathLuaDoc
---@param segs string[]
---@param seek_key string|nil
---@return { path:string, key_line:integer|nil, key_col:integer|nil, tbl_start:integer|nil, tbl_end:integer|nil, key_missing:true|nil }|nil
local function ts_locate(doc, segs, seek_key)
  local root, src, abs_path = doc.root, doc.src, doc.path
  if not root or not src then return nil end

  -- One collection per document: a caller trying many roots against one file asks again and again.
  doc.assigns = doc.assigns or ts_collect_table_assignments(root, src)
  local assigns = doc.assigns
  local tbl = nil

  -- 1) direct: ROOT.cfg.highlight = { ... }
  for _, a in ipairs(assigns) do
    if AST.chains_equal(a.chain, segs) then
      tbl = a.tbl
      break
    end
  end

  -- 2) progressive: ROOT.cfg = { ... } -> child "highlight" -> ...
  if not tbl and #segs >= 2 then
    local top = { segs[1], segs[2] }
    for _, a in ipairs(assigns) do
      if AST.chains_equal(a.chain, top) then
        tbl = ts_descend(a.tbl, AST.slice(segs, 3), src)
        break
      end
    end
  end

  -- 3) any-root: <ROOT>.(cfg.highlight) = { ... }
  if not tbl and #segs >= 2 then
    local tail = AST.slice(segs, 2)
    for _, a in ipairs(assigns) do
      if #a.chain == #segs and AST.chain_tail_equal(a.chain, 2, tail) then
        tbl = a.tbl
        break
      end
    end
  end

  -- 4) return { cfg = { highlight = ... } } : descend inside outer return table
  if not tbl then
    local rt = ts_find_return_table(root, src)
    if rt then tbl = ts_descend(rt, segs, src) end
  end

  -- 5) global fallback: any field named segs[2] anywhere, then descend
  if not tbl and #segs >= 2 then
    local g = ts_find_field_anywhere(root, segs[2], src, true)
    if g then tbl = ts_descend(g, AST.slice(segs, 3), src) end
  end

  if tbl then return ts_table_hit(abs_path, tbl, seek_key, src) end

  -- 6) nothing found: single-line field assignment fallback: ROOT.cfg.highlight.key = ...
  if seek_key then
    local full = AST.slice(segs, 1)
    full[#full + 1] = seek_key
    local lhs = ts_find_assignment_lhs(root, full, src)
    if lhs then
      local last = lhs:field("field")[1] or lhs
      local kl, kc = AST.node_start(last)
      return { path = abs_path, key_line = kl, key_col = kc, tbl_start = nil, tbl_end = nil }
    end
  end

  return nil
end

-- ========= main locate =========

---Locate a table region and optionally a key initializer inside it.
---@param abs_path string  Absolute file path to search in
---@param base_chain string "M.cfg.highlight" (root.var1.var2)
---@param seek_key string|nil  e.g. "enable_insert_submode_colors"
---@return { path:string, key_line:integer|nil, key_col:integer|nil, tbl_start:integer|nil, tbl_end:integer|nil, key_missing:true|nil }|nil
---  `key_missing` is true when `seek_key` was given but the table does not hold it; `key_line` is then the
---  table's first line.
function M.locate(abs_path, base_chain, seek_key)
  local doc = M.read_doc(abs_path)
  if not doc then return nil end
  return M.locate_doc(doc, base_chain, seek_key)
end

---A Lua file read and parsed once, for callers that look up several chains in it.
---@class GopathLuaDoc
---@field path string
---@field lines string[]
---@field root TSNode|nil  nil when no "lua" parser is available
---@field src string|nil  the text `root` was parsed from
---@field assigns table[]|nil  table assignments, collected on first use

---Read and parse `abs_path` (nil when it is unreadable or empty).
---@param abs_path string
---@return GopathLuaDoc|nil
function M.read_doc(abs_path)
  if type(abs_path) ~= "string" or abs_path == "" then return nil end
  local ok, lines = pcall(vim.fn.readfile, abs_path)
  if not ok or type(lines) ~= "table" or #lines == 0 then return nil end
  local root, src = AST.parse(lines)
  return { path = abs_path, lines = lines, root = root, src = src }
end

---`M.locate` on a document from `M.read_doc`.
---@param doc GopathLuaDoc
---@param base_chain string
---@param seek_key string|nil
---@return { path:string, key_line:integer|nil, key_col:integer|nil, tbl_start:integer|nil, tbl_end:integer|nil, key_missing:true|nil }|nil
function M.locate_doc(doc, base_chain, seek_key)
  local segs = DOT.split(base_chain) -- { ROOT, cfg, highlight, ... }
  if #segs == 0 then return nil end

  return ts_locate(doc, segs, seek_key) or legacy_locate(doc.lines, segs, seek_key, doc.path)
end

return M
