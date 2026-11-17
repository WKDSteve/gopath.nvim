-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
--
-- Same reasoning for the three below: `AST.parse` is replaced as a test
-- double for the length of one case and restored right after; the config
-- literals fed to `setup()` are partial on purpose (the merge fills the
-- rest); and a value asserted truthy on the line above is still optional
-- to the type checker.
---@diagnostic disable: duplicate-set-field, missing-fields, param-type-mismatch
-- scripts/ci/functional_tests.lua
-- Headless CI functional tests for the Lua resolvers' Treesitter-first
-- table/symbol locating (table_locator.lua, symbol_locator.lua), and a couple
-- of end-to-end buffer+cursor cases mirroring TESTS/05_direct_symbol_jump.lua.
--
-- Unlike scripts/ci/headless_tests.lua (which only load-checks fixtures),
-- these are real behavioral assertions: fixture files/buffers are written,
-- a cursor is placed where relevant, and the resolvers' return values are
-- checked against expected paths/lines/columns.
--
-- Requires lib.nvim on the runtimepath (a hard gopath.nvim dependency; see
-- docs/install.json) since `value_origin` transitively requires `lib.lua.tables`.
--
-- Run via:
--   nvim --headless --noplugin -u NONE \
--     -c "set rtp+=<path-to-lib.nvim>" \
--     -c "lua dofile('scripts/ci/functional_tests.lua')"

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

require("gopath").setup({})

local failures = {}

---@param name string
---@param fn fun()
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print(("[ OK ] %s"):format(name))
  else
    print(("[FAIL] %s: %s"):format(name, err))
    failures[#failures + 1] = name
  end
end

---@param actual any
---@param expected any
---@param msg string|nil
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(
      ("%s: expected %s, got %s"):format(
        msg or "assert_eq",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

---@param v any
---@param msg string|nil
local function assert_truthy(v, msg)
  if not v then error(msg or "expected a truthy value", 2) end
end

---@param v any
---@param msg string|nil
local function assert_nil(v, msg)
  if v ~= nil then error((msg or "expected nil") .. ", got " .. vim.inspect(v), 2) end
end

---Canonical spelling of a path, for comparing a resolver's answer against a
---fixture path.
---
---`fnamemodify(p, ":p")` makes a path absolute but never touches separators, so
---on Windows it is not a canonicaliser at all: a fixture path built as
---`tempname() .. "/" .. name` is mixed ("C:\\...\\dir/x.lua") while a resolver
---reporting a buffer name answers in whatever spelling Neovim stored. Both are
---the same file; only the strings differ. Putting both sides through the same
---canonicaliser the plugin promises for `GopathResult.path`
---(`gopath.util.cross.to_forward`, forward slashes everywhere) compares one file
---against one file, instead of pinning one platform's accidental spelling.
---@param p string
---@return string
local function canon_path(p)
  return require("gopath.util.cross").to_forward(vim.fn.fnamemodify(p, ":p"))
end

-- ========= fixtures =========

local scratch_dir = vim.fn.tempname() .. "_gopath_fntest"
vim.fn.mkdir(scratch_dir, "p")
-- Resolved to its physical spelling, symlinks in the prefix followed. On macOS
-- tempname() answers below /var, a symlink to /private/var, and Neovim
-- canonicalises a buffer name when it is set (fix_fname chdirs into the
-- directory and reads getcwd, which is always physical). A resolver that
-- reports the path of the buffer it was invoked on therefore answers
-- /private/var/..., and comparing that against the raw fixture path compares
-- two spellings of one file. Resolving at the source keeps both sides equal on
-- every platform; a no-op on Linux and Windows, which have no symlink there.
scratch_dir = vim.uv.fs_realpath(scratch_dir) or scratch_dir
-- Fixture modules live directly under scratch_dir so `search_in_rtp`'s
-- root-level candidate check (`<rtp>/<name>.lua`) resolves them.
vim.opt.runtimepath:append(scratch_dir)

---Write `lines` to `<scratch_dir>/<relname>` and return the absolute path.
---Invalidates `gopath.util.path`'s runtimepath index, since it's keyed on
---the rtp *string* and won't otherwise notice a file appearing under an
---already-indexed root (see path.lua's `invalidate_caches` docs).
---@param relname string
---@param lines string[]
---@return string
local function write_fixture(relname, lines)
  local path = scratch_dir .. "/" .. relname
  vim.fn.writefile(lines, path)
  require("gopath.util.path").invalidate_caches()
  return path
end

-- ========= Group A: table_locator.locate =========

local table_locator = require("gopath.resolvers.lua.table_locator")

check("table_locator: nested table chain (M.cfg.highlight.enable_x)", function()
  local path = write_fixture("a1_nested_chain.lua", {
    "local M = {}",
    "M.cfg = {",
    "  highlight = {",
    "    enable_x = true,",
    "  },",
    "}",
    "return M",
  })
  local hit = table_locator.locate(path, "M.cfg.highlight", "enable_x")
  assert_truthy(hit, "expected a hit")
  assert_eq(hit.key_line, 4, "key_line")
  assert_eq(hit.tbl_start, 3, "tbl_start")
  assert_eq(hit.tbl_end, 5, "tbl_end")
end)

check("table_locator: return { ... } module style", function()
  local path = write_fixture("a2_return_table.lua", {
    "return {",
    "  cfg = {",
    "    highlight = {",
    "      enable_x = true,",
    "    },",
    "  },",
    "}",
  })
  local hit = table_locator.locate(path, "cfg.highlight", "enable_x")
  assert_truthy(hit, "expected a hit")
  assert_eq(hit.key_line, 4, "key_line")
end)

check("table_locator: table nested inside a function call (setmetatable)", function()
  local path = write_fixture("a3_setmetatable.lua", {
    "local obj = setmetatable({",
    "  cfg = {",
    "    highlight = {",
    "      enable_x = true,",
    "    },",
    "  },",
    "}, {})",
  })
  local hit = table_locator.locate(path, "obj.cfg.highlight", "enable_x")
  assert_truthy(hit, "expected a hit")
  assert_eq(hit.key_line, 4, "key_line")
end)

check("table_locator: bracketed string keys", function()
  local path = write_fixture("a4_bracket_keys.lua", {
    "local M = {}",
    'M["cfg"] = {',
    '  ["highlight"] = {',
    "    enable_x = true,",
    "  },",
    "}",
    "return M",
  })
  local hit = table_locator.locate(path, "M.cfg.highlight", "enable_x")
  assert_truthy(hit, "expected a hit")
  assert_eq(hit.key_line, 4, "key_line")
end)

check("table_locator: sibling keys at the same depth are not confused", function()
  local path = write_fixture("a5_sibling_depth.lua", {
    "local M = {}",
    "M.cfg = {",
    "  a = { x = 1 },",
    "  b = { y = 2 },",
    "}",
    "return M",
  })
  local hit_b = table_locator.locate(path, "M.cfg.b", "y")
  assert_truthy(hit_b, "expected a hit for b.y")
  assert_eq(hit_b.key_line, 4, "key_line for b.y")

  local hit_a = table_locator.locate(path, "M.cfg.a", "x")
  assert_truthy(hit_a, "expected a hit for a.x")
  assert_eq(hit_a.key_line, 3, "key_line for a.x")
end)

check("table_locator: missing key falls back to the table start", function()
  local path = write_fixture("a6_missing_key.lua", {
    "local M = {}",
    "M.cfg = {",
    "  highlight = { enable_x = true },",
    "}",
    "return M",
  })
  local hit = table_locator.locate(path, "M.cfg", "does_not_exist")
  assert_truthy(hit, "expected a hit (table-start fallback)")
  assert_eq(hit.tbl_start, 2, "tbl_start")
  assert_eq(hit.key_line, 2, "key_line falls back to tbl_start")
  assert_eq(hit.key_missing, true, "key_missing tells the fallback from a key on that line")

  local found = table_locator.locate(path, "M.cfg", "highlight")
  assert_truthy(found, "expected a hit for a key the table holds")
  assert_nil(found.key_missing, "key_missing is only set for a key that is not there")
end)

check("table_locator: unmatched chain returns nil", function()
  local path = write_fixture("a7_total_miss.lua", {
    "local M = {}",
    "M.cfg = { highlight = { enable_x = true } }",
    "return M",
  })
  local hit = table_locator.locate(path, "X.Y.Z", "foo")
  assert_nil(hit, "expected nil for a chain that doesn't exist anywhere")
end)

check("table_locator: single-field assignment with no table literal", function()
  local path = write_fixture("a8_single_field.lua", {
    "M.cfg.highlight.enable_x = true",
  })
  local hit = table_locator.locate(path, "M.cfg.highlight", "enable_x")
  assert_truthy(hit, "expected a hit")
  assert_eq(hit.key_line, 1, "key_line")
  assert_nil(hit.tbl_start, "tbl_start should be nil (no table literal to report)")
end)

-- ========= Group B: symbol_locator.via_treesitter =========

local symbol_locator = require("gopath.resolvers.lua.symbol_locator")

write_fixture("target_symbols.lua", {
  "local M = {}",
  "",
  "function M.setup(opts)",
  "end",
  "",
  "local function helper()",
  "end",
  "",
  "M.other = function()",
  "end",
  "",
  'M["bracketed"] = function() end',
  "",
  "return M",
})

check("symbol_locator: function M.setup(...)", function()
  local r = symbol_locator.via_treesitter(
    { base = "cfgmod", chain = { "setup" } },
    { cfgmod = "target_symbols" }
  )
  assert_truthy(r, "expected a result")
  assert_eq(r.kind, "field", "kind")
  assert_eq(r.source, "treesitter", "source")
  assert_eq(r.range.line, 3, "range.line")
end)

check("symbol_locator: local function helper()", function()
  local r = symbol_locator.via_treesitter(
    { base = "cfgmod", chain = { "helper" } },
    { cfgmod = "target_symbols" }
  )
  assert_truthy(r, "expected a result")
  assert_eq(r.range.line, 6, "range.line")
end)

check("symbol_locator: M.other = function() ... end", function()
  local r = symbol_locator.via_treesitter(
    { base = "cfgmod", chain = { "other" } },
    { cfgmod = "target_symbols" }
  )
  assert_truthy(r, "expected a result")
  assert_eq(r.range.line, 9, "range.line")
end)

check("symbol_locator: bracketed assignment M['bracketed'] = function() end", function()
  local r = symbol_locator.via_treesitter(
    { base = "cfgmod", chain = { "bracketed" } },
    { cfgmod = "target_symbols" }
  )
  assert_truthy(r, "expected a result")
  assert_eq(r.range.line, 12, "range.line")
end)

check("symbol_locator: empty chain resolves to the module itself", function()
  local r = symbol_locator.via_treesitter(
    { base = "cfgmod", chain = {} },
    { cfgmod = "target_symbols" }
  )
  assert_truthy(r, "expected a result")
  assert_eq(r.kind, "module", "kind")
  assert_nil(r.range, "range should be nil")
end)

check("symbol_locator: unknown symbol falls back to a module reference", function()
  local r = symbol_locator.via_treesitter(
    { base = "cfgmod", chain = { "nonexistent" } },
    { cfgmod = "target_symbols" }
  )
  assert_truthy(r, "expected a result")
  assert_eq(r.kind, "module", "kind")
  assert_eq(r.confidence, 0.5, "confidence")
end)

-- ========= Group C: end-to-end buffer+cursor (mirrors TESTS/05) =========

check("value_origin: cursor on a nested chain resolves through a real buffer+cursor", function()
  local path = write_fixture("c1_value_origin.lua", {
    "local M = {}",
    "M.cfg = {",
    "  highlight = {",
    "    enable_x = true,",
    "  },",
    "}",
    "",
    "local function use()",
    "  return M.cfg.highlight.enable_x",
    "end",
    "",
    "return M",
  })

  vim.cmd.edit(path)
  vim.bo.filetype = "lua"

  local line = vim.api.nvim_buf_get_lines(0, 8, 9, false)[1] -- 1-based line 9
  local col = assert(line:find("enable_x"), "fixture line changed") - 1
  vim.api.nvim_win_set_cursor(0, { 9, col })

  local value_origin = require("gopath.resolvers.lua.value_origin")
  local r = value_origin.resolve()
  assert_truthy(r, "expected a resolve() result")
  assert_eq(r.range.line, 4, "range.line (initializer line, not the usage line)")
  assert_eq(canon_path(r.path), canon_path(path), "path")
  -- The comparison above canonicalises BOTH sides, so on its own it would keep
  -- passing if the resolver went back to reporting a native backslash spelling.
  -- Pin the contract separately, so the canonicalisation stays a way to compare
  -- two spellings of the fixture path and not a way to hide a regression.
  assert_eq(r.path:find("\\", 1, true), nil, "path is reported with forward slashes only")
end)

check(
  "chain + symbol_locator: cursor on a chained call resolves through a real buffer+cursor",
  function()
    write_fixture("target_c2.lua", {
      "local M = {}",
      "",
      "function M.setup(opts)",
      "end",
      "",
      "return M",
    })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'local cfgmod = require("target_c2")',
      "cfgmod.setup()",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "lua"

    local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] -- 1-based line 2
    local col = assert(line:find("setup"), "fixture line changed") - 1
    vim.api.nvim_win_set_cursor(0, { 2, col })

    local chain_mod = require("gopath.resolvers.lua.chain")
    local binding_index = require("gopath.resolvers.lua.binding_index")

    local chain = chain_mod.get_chain_at_cursor()
    assert_truthy(chain, "expected a chain at cursor")
    assert_eq(chain.base, "cfgmod", "chain.base")

    local bind = binding_index.get_map()
    local r = symbol_locator.via_treesitter(chain, bind)
    assert_truthy(r, "expected a symbol_locator result")
    assert_eq(r.range.line, 3, "range.line")
  end
)

check("value_origin: a function of the module's root table resolves to its definition", function()
  -- gF on `config.get()` without a language server: `get` is no key of the table constructor
  -- (`local M = {}`), so the value pass must hand over to the definition, not report line 1.
  write_fixture("c3_target.lua", {
    "local M = {}",
    "M.defaults = { enable_x = true }",
    "",
    "function M.get()",
    "  return M.defaults",
    "end",
    "",
    "M.set = function() end",
    "",
    "return M",
  })
  local value_origin = require("gopath.resolvers.lua.value_origin")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    'local config = require("c3_target")',
    "config.get()",
    "config.set()",
    "local alias = config",
    "alias.get()",
    "config.defaults.enable_x",
    "config.nope()",
  })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"

  ---@param row integer
  ---@param word string
  ---@return table|nil
  local function at(row, word)
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    vim.api.nvim_win_set_cursor(0, { row, assert(line:find(word, 1, true)) - 1 })
    return value_origin.resolve()
  end

  local r = at(2, "get")
  assert_truthy(r, "config.get(): a result")
  assert_eq(r.range.line, 4, "config.get(): the line of function M.get()")
  r = at(3, "set")
  assert_eq(r and r.range.line, 8, "config.set(): the line of M.set = function")
  r = at(5, "get")
  assert_eq(r and r.range.line, 4, "alias.get(): through the alias too")
  r = at(6, "enable_x")
  assert_eq(r and r.range.line, 2, "a value one level deeper keeps its initializer line")
  r = at(7, "nope")
  assert_truthy(r, "config.nope(): still the module")
  assert_eq(r.range and r.range.line or 1, 1, "config.nope(): no definition, the table start")
end)

-- ========= Group D: legacy (line-pattern) fallback path =========
-- Forces the treesitter tiers to report "unavailable" (as if no "lua" parser
-- were installed) and re-runs a couple of Group A/B fixtures, to confirm the
-- fallback safety net itself still resolves correctly, independent of the
-- treesitter-first path exercised above.

check("legacy fallback: table_locator resolves without a parser", function()
  local AST = require("gopath.resolvers.lua.ts_lua_ast")
  local original_parse = AST.parse
  AST.parse = function()
    return nil, nil
  end

  local ok, err = pcall(function()
    local path = write_fixture("d1_legacy_table.lua", {
      "local M = {}",
      "M.cfg = {",
      "  highlight = {",
      "    enable_x = true,",
      "  },",
      "}",
      "return M",
    })
    local hit = table_locator.locate(path, "M.cfg.highlight", "enable_x")
    assert_truthy(hit, "expected a hit via the legacy path")
    assert_eq(hit.key_line, 4, "key_line")
  end)

  AST.parse = original_parse
  if not ok then error(err, 0) end
end)

check("legacy fallback: symbol_locator resolves without a parser", function()
  local AST = require("gopath.resolvers.lua.ts_lua_ast")
  local original_parse = AST.parse
  AST.parse = function()
    return nil, nil
  end

  local ok, err = pcall(function()
    local r = symbol_locator.via_treesitter(
      { base = "cfgmod", chain = { "setup" } },
      { cfgmod = "target_symbols" }
    )
    assert_truthy(r, "expected a result via the legacy path")
    assert_eq(r.range.line, 3, "range.line")
  end)

  AST.parse = original_parse
  if not ok then error(err, 0) end
end)

-- ========= Group E: filetoken URL handling =========
-- Regression for a bug where a URL under the cursor (e.g. in a markdown doc)
-- got joined with the current file's directory instead of being recognised
-- as an external target, producing a bogus path like
-- ".../personal/http://www.google.com" and offering to create it.

check("filetoken: URL under cursor is returned verbatim, not cwd-joined", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "See http://www.google.com for details.",
  })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"

  local col = assert(({ vim.api.nvim_buf_get_lines(buf, 0, 1, false) })[1][1]:find("http")) - 1
  vim.api.nvim_win_set_cursor(0, { 1, col })

  local filetoken = require("gopath.resolvers.common.filetoken")
  local r = filetoken.resolve()
  assert_truthy(r, "expected a result")
  assert_eq(r.path, "http://www.google.com", "path must be the raw URL, not cwd-joined")
  assert_truthy(r.exists, "URL results should be marked as existing")
end)

-- ========= URL resolution (gopath.resolve pipeline) =========
--- The full pipeline must hand URLs to the external opener instead of turning
--- them into local paths. Strict forms (explicit scheme, "www.") pre-empt the
--- file resolvers; scheme-less hosts only win after every file resolver missed,
--- so a real file of the same name still opens as a file.

---Place the cursor on `anchor` inside `line` and run the full resolve pipeline.
---@param line string
---@param anchor string substring of `line` to put the cursor on
---@return GopathResult|nil
local function resolve_on(line, anchor)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { 1, assert(line:find(anchor, 1, true)) - 1 })
  return (require("gopath.resolve").resolve_at_cursor({}))
end

---@param name string
---@param line string
---@param anchor string
---@param expected string
local function check_url(name, line, anchor, expected)
  check(name, function()
    local r = resolve_on(line, anchor)
    assert_truthy(r, "expected a result")
    assert_eq(r.kind, "url", "kind")
    assert_eq(r.path, expected, "url")
    assert_truthy(r.exists, "URL results must be marked existing so create-on-missing is skipped")
  end)
end

check_url(
  "url: query string and fragment survive (<cfile> would truncate at '?')",
  "docs at https://example.com/a?b=1&c=2#frag ok",
  "https",
  "https://example.com/a?b=1&c=2#frag"
)

check_url(
  "url: wrapping parens and trailing sentence period are trimmed",
  "See (https://example.com/x).",
  "https",
  "https://example.com/x"
)

check_url(
  "url: markdown link target",
  "[docs](https://neovim.io/doc/user/index.html#top)",
  "https",
  "https://neovim.io/doc/user/index.html#top"
)

check_url(
  "url: 'www.' prefix gets the implicit scheme",
  "www.google.com",
  "www",
  "https://www.google.com"
)

check_url(
  "url: bare host with a known TLD (loose pass)",
  "clone github.com/neovim/neovim first",
  "github",
  "https://github.com/neovim/neovim"
)

check_url(
  "url: scp-style git remote is rewritten to https",
  "git@github.com:foo/bar.git",
  "git@",
  "https://github.com/foo/bar"
)

check("url: a real file is never mistaken for a bare host", function()
  local r = resolve_on("see README.md for details", "README")
  assert_truthy(r, "expected a result")
  assert_eq(r.kind ~= "url", true, "README.md must not resolve as a URL")
end)

check("url: bare_hosts = false disables the loose pass", function()
  require("gopath.config").setup({ url = { bare_hosts = false } })
  local r = resolve_on("clone github.com/neovim/neovim first", "github")
  local is_url = r ~= nil and r.kind == "url"
  require("gopath.config").setup({ url = { bare_hosts = true } })
  assert_eq(is_url, false, "loose pass must stay off when bare_hosts = false")
end)

-- ========= alternate frecency: ordering by what was chosen before =========
--
-- The property worth pinning is not "does it reorder" -- it is the ceiling.
-- Without one, a single visit scores log(2) x 100 = 69 on a scale where
-- similarity itself runs 0-100, and the list would be ordered by history
-- alone with similarity as decoration. Every check below is about the bonus
-- staying a tiebreak.

do
  local frecency = require("gopath.alternate.frecency")
  local config = require("gopath.config")

  local frec_dir = vim.fn.tempname()
  vim.fn.mkdir(frec_dir, "p")

  ---@param overrides table|nil
  local function configure(overrides)
    config.setup({
      alternate = {
        frecency = vim.tbl_extend(
          "force",
          { enable = true, max_bonus = 10, dir = frec_dir },
          overrides or {}
        ),
      },
    })
  end

  ---@param spec table[] { path, similarity }
  ---@return table[]
  local function candidates(spec)
    local out = {}
    for _, s in ipairs(spec) do
      out[#out + 1] = {
        path = s[1],
        filename = vim.fn.fnamemodify(s[1], ":t"),
        similarity = s[2],
      }
    end
    return out
  end

  ---@param matches table[]
  ---@return string[]
  local function paths_of(matches)
    local out = {}
    for _, m in ipairs(matches) do
      out[#out + 1] = m.path
    end
    return out
  end

  configure()

  check("alternate frecency: no history leaves the similarity order alone", function()
    local ordered = frecency.rerank(candidates({
      { "/p/config.lua", 90 },
      { "/p/configs.lua", 88 },
    }))
    assert_eq(paths_of(ordered)[1], "/p/config.lua", "the better match must stay first")
  end)

  check("alternate frecency: a chosen candidate wins a near-tie", function()
    frecency.record("/p/configs.lua")
    local ordered = frecency.rerank(candidates({
      { "/p/config.lua", 90 },
      { "/p/configs.lua", 88 },
    }))
    assert_eq(
      paths_of(ordered)[1],
      "/p/configs.lua",
      "two points of similarity must lose to a real choice"
    )
  end)

  check("alternate frecency: a clear winner is never inverted", function()
    -- Same recorded choice as above, now against a match 19 points better.
    -- This is the one that would fail without the saturating ceiling.
    local ordered = frecency.rerank(candidates({
      { "/p/config.lua", 95 },
      { "/p/configs.lua", 76 },
    }))
    assert_eq(
      paths_of(ordered)[1],
      "/p/config.lua",
      "history must not push a 95% match below a 76% one"
    )
  end)

  check("alternate frecency: max_bonus = 0 records but does not reorder", function()
    configure({ max_bonus = 0 })
    local ordered = frecency.rerank(candidates({
      { "/p/config.lua", 90 },
      { "/p/configs.lua", 88 },
    }))
    configure()
    assert_eq(paths_of(ordered)[1], "/p/config.lua", "a zero ceiling is no reordering at all")
  end)

  check("alternate frecency: enable = false reorders nothing", function()
    configure({ enable = false })
    local ordered = frecency.rerank(candidates({
      { "/p/config.lua", 90 },
      { "/p/configs.lua", 88 },
    }))
    configure()
    assert_eq(paths_of(ordered)[1], "/p/config.lua", "disabled must mean the raw similarity order")
  end)

  check("alternate frecency: a single candidate is returned untouched", function()
    local one = candidates({ { "/p/configs.lua", 88 } })
    assert_eq(frecency.rerank(one), one, "nothing to order, nothing to read")
  end)

  check("alternate frecency: equal similarity keeps the incoming order", function()
    -- Lua's table.sort is not stable, so this is a real risk rather than a
    -- theoretical one: without the index tiebreak these two could swap.
    local ordered = frecency.rerank(candidates({
      { "/p/aaa.lua", 80 },
      { "/p/bbb.lua", 80 },
    }))
    assert_eq(paths_of(ordered)[1], "/p/aaa.lua", "a tie must resolve deterministically")
  end)

  check("alternate frecency: the choice survives a fresh store", function()
    require("lib.nvim.frecency")._reset_handles()
    local ordered = frecency.rerank(candidates({
      { "/p/config.lua", 90 },
      { "/p/configs.lua", 88 },
    }))
    assert_eq(
      paths_of(ordered)[1],
      "/p/configs.lua",
      "a recorded choice must be flushed, not held in memory until exit"
    )
  end)
end

-- ========= LSP provider does not wait for a server that is not there =========
-- See docs/resolution.md#the-lsp-step-does-not-wait-for-a-server-that-is-not-there
-- for the measurements behind this guard.
--
-- Asserted by whether the request is *made*, not by how long it takes: a
-- timing assertion on a timeout is a flake waiting for a slow runner, and
-- "did we ask nobody" is the thing the guard actually changes.

check("lsp provider: no client attached means no request at all", function()
  local lsp = require("gopath.providers.lsp")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })

  ---@diagnostic disable-next-line: deprecated
  local clients = (vim.lsp.get_clients or vim.lsp.get_active_clients)({ bufnr = buf })
  assert_eq(#clients, 0, "the fixture buffer has no client")

  local asked = 0
  local real = vim.lsp.buf_request_sync
  vim.lsp.buf_request_sync = function(...)
    asked = asked + 1
    return real(...)
  end

  local ok, res = pcall(lsp.definition_at_cursor, 200)

  vim.lsp.buf_request_sync = real
  vim.api.nvim_buf_delete(buf, { force = true })

  assert_truthy(ok, "the provider does not error without a client")
  assert_nil(res, "and answers nil")
  assert_eq(asked, 0, "without sending a request nobody could answer")
end)

-- ========= config: curated array fields are replaced, not index-merged =========
-- See docs/... : `order` and `truncated.excluded_dirs` are closed, curated
-- lists. A naive recursive table merge (mirroring `vim.tbl_deep_extend`'s
-- known list trap) merges arrays index-wise, so a shorter user-supplied list
-- leaves the default's trailing entries in place instead of fully replacing
-- it. Asserted on the full sequence (3+ default entries), not just length or
-- a single index, since a 1-2 element comparison can pass "by accident" even
-- with the buggy index-wise merge for some inputs.

check("config: order = { one entry } is not padded with leftover defaults", function()
  local config = require("gopath.config")
  config.setup({ order = { "treesitter" } })
  local order = config.get().order
  assert_eq(#order, 1, "user supplied exactly one entry")
  assert_eq(
    table.concat(order, ","),
    "treesitter",
    "the default's other two entries ('lsp', 'builtin') must not survive the override"
  )
  -- restore for any later check relying on the default order
  config.setup({ order = { "lsp", "treesitter", "builtin" } })
end)

check("config: truncated.excluded_dirs replaces the default list wholesale", function()
  local config = require("gopath.config")
  config.setup({ truncated = { excluded_dirs = { "vendor" } } })
  local dirs = config.get().truncated.excluded_dirs
  assert_eq(#dirs, 1, "user supplied exactly one entry")
  assert_eq(
    dirs[1],
    "vendor",
    "the default's other exclusions (.git, node_modules, ...) must not survive the override"
  )
  -- restore for any later check relying on the default exclusion list
  config.setup({
    truncated = {
      excluded_dirs = { ".git", ".github", "node_modules", "target", "build", ".cache", "venv" },
    },
  })
end)

-- ========= summary =========

if #failures > 0 then
  print(("\n%d check(s) failed: %s"):format(#failures, table.concat(failures, ", ")))
  vim.cmd("cquit 1")
else
  print("\nAll functional checks passed.")
  vim.cmd("qa!")
end
