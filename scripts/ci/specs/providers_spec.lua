-- scripts/ci/specs/providers_spec.lua
-- gopath.providers.*: the token extractor every path resolver starts from, the
-- Tree-sitter helpers, and the LSP definition request.
--
-- scripts/ci/functional_tests.lua already pins the one property of the LSP
-- provider that is about *not* doing something (no client attached means no
-- request). This spec covers the response shapes it has to understand, with
-- `vim.lsp.buf_request_sync` replaced so no server is ever contacted.

---@param H table
return function(H)
  local token = require("gopath.providers.token")
  local builtin = require("gopath.providers.builtin")
  local TSP = require("gopath.providers.treesitter")
  local lsp = require("gopath.providers.lsp")

  -- ── token ──────────────────────────────────────────────────────────────────

  ---@param line string
  ---@param anchor string
  ---@return string|nil
  local function extract(line, anchor)
    H.line_at(line, anchor, { filetype = "text" })
    return token.extract_at_cursor()
  end

  H.check("extract_at_cursor: widens over path characters in both directions", function()
    H.eq(extract("open lua/gopath/init.lua now", "gopath"), "lua/gopath/init.lua")
    H.eq(extract("open lua/gopath/init.lua now", "lua/"), "lua/gopath/init.lua", "from the start")
    H.eq(extract("open lua/gopath/init.lua now", ".lua"), "lua/gopath/init.lua", "from the end")
  end)

  H.check("extract_at_cursor: the colon location suffixes survive", function()
    H.eq(extract("at src/a.lua:42:7 here", "src"), "src/a.lua:42:7")
    H.eq(extract("at src/a.lua:42 here", "src"), "src/a.lua:42")
  end)

  H.check("BUG: the `path(line)` form is broken by the trailing-paren strip", function()
    -- token.lua's module docstring promises it "Preserves :line:col, (line),
    -- and other location formats", and `filetoken.looks_like_path` explicitly
    -- accepts `%(%d+%)`. But the cleanup step ends with
    --     token = token:gsub("%)$", "")   -- Strip trailing paren (function calls)
    -- which removes the very bracket that makes `(line)` parseable.
    H.eq(extract("at src/a.lua(42) here", "src"), "src/a.lua(42", "BUG: the ')' is gone")

    -- The damage is not just a lost line number: what is left is not a path
    -- either, so the file itself stops resolving.
    local LOC = require("gopath.util.location")
    H.same(
      LOC.parse_location("src/a.lua(42)"),
      { path = "src/a.lua", line = 42, col = 1 },
      "intact, the form parses"
    )
    H.same(
      LOC.parse_location("src/a.lua(42"),
      { path = "src/a.lua(42" },
      "BUG: mangled, it is taken as a filename ending in '(42'"
    )
  end)

  H.check("extract_at_cursor: Windows paths stay whole", function()
    H.eq(extract([[from C:\Users\me\init.lua loaded]], "Users"), [[C:\Users\me\init.lua]])
    H.eq(extract("from C:/Users/me/init.lua loaded", "Users"), "C:/Users/me/init.lua")
  end)

  H.check("extract_at_cursor: wrapper characters are trimmed, but not a meaningful dot", function()
    H.eq(extract("[label](docs/a.md) here", "docs"), "docs/a.md", "the Markdown link's parens")
    -- Documented limitation: only a LEADING "(" is stripped, and "(" is itself
    -- a path character, so a call wrapper whose callee is an identifier drags
    -- the identifier in. `[label](path)` works because "]" stops the widening;
    -- `require("path")` works because the quote does.
    H.eq(extract("call(src/a.lua) here", "src"), "call(src/a.lua", "the callee comes along")
    H.eq(extract('require("gopath.config")', "gopath"), "gopath.config", "quotes stop the widening")
    H.eq(extract("chain .field here", "field"), "field", "a leading chain dot is dropped")
    H.eq(extract("see ./rel/a.lua here", "rel"), "./rel/a.lua", "but './' keeps its dot")
    H.eq(extract("see ...trunc/a.lua here", "trunc"), "...trunc/a.lua", "and so does an ellipsis")
  end)

  H.check("extract_at_cursor: nothing under the cursor", function()
    H.line_at("", "", { filetype = "text" })
    H.is_nil(token.extract_at_cursor(), "empty line")
    H.line_at("   ", " ", { filetype = "text" })
    H.is_nil(token.extract_at_cursor(), "whitespace only")
  end)

  H.check("expand_cfile and get_token: the smart extractor first, <cfile> after", function()
    H.line_at("see lua/gopath/init.lua now", "gopath", { filetype = "text" })
    H.eq(token.get_token(), "lua/gopath/init.lua", "the smart form wins")
    H.eq(type(token.expand_cfile()), "string", "and <cfile> is there as the fallback")
    H.eq(builtin.expand_cfile(), token.get_token(), "the builtin provider is a pass-through")

    H.line_at("", "", { filetype = "text" })
    H.is_nil(token.expand_cfile(), "nothing to expand on an empty line")
    H.is_nil(token.get_token(), "and therefore no token")
  end)

  -- ── treesitter helpers ─────────────────────────────────────────────────────

  H.check("node_at_cursor: returns the named node under the cursor in a parsed buffer", function()
    H.buf({ "local alpha = 1", "print(alpha)" }, { filetype = "lua" })
    H.cursor_on(2, "alpha")
    local node = TSP.node_at_cursor()
    H.truthy(node, "expected a node")
    H.eq(node:type(), "identifier")
    H.eq(vim.treesitter.get_node_text(node, 0), "alpha")
  end)

  H.check("node_at_cursor: a buffer with no parser answers nil rather than erroring", function()
    H.buf({ "nothing parseable here" }, { filetype = "" })
    H.is_nil(TSP.node_at_cursor())
  end)

  H.check("parse_string: parses text that is not in any buffer", function()
    local root = TSP.parse_string("local M = {}\nreturn M\n", "lua")
    H.truthy(root, "expected a root node")
    H.eq(root:type(), "chunk")
    H.is_nil(TSP.parse_string("whatever", "a_language_with_no_parser"), "unknown language")
  end)

  H.check("captures_at_pos: answers a list, empty when nothing is highlighted", function()
    H.buf({ "local x = 1" }, { filetype = "lua" })
    H.eq(type(TSP.captures_at_pos(0, 6)), "table")
    H.buf({ "plain" }, { filetype = "" })
    H.same(TSP.captures_at_pos(0, 0), {}, "no parser, no captures")
  end)

  H.check(
    "captures_at_pos: a failing core call never falls back to nvim-treesitter.ts_utils",
    function()
      -- ts_utils is gone in the nvim-treesitter rewrite; core get_captures_at_pos exists since 0.9.
      local reached = false
      local ts_utils = {
        get_captures_at_pos = function()
          reached = true
          return { "from-ts_utils" }
        end,
      }
      H.buf({ "local x = 1" }, { filetype = "lua" })
      H.with_modules({ ["nvim-treesitter.ts_utils"] = ts_utils }, function()
        H.with_field(vim.treesitter, "get_captures_at_pos", function()
          error("core failed", 0)
        end, function()
          H.same(TSP.captures_at_pos(0, 6), {}, "a core failure answers an empty list")
        end)
      end)
      H.falsy(reached, "nvim-treesitter.ts_utils is not consulted")
    end
  )

  -- ── lsp ────────────────────────────────────────────────────────────────────

  ---Run `lsp.definition_at_cursor` against a canned server response.
  ---@param response any  the `result` field one server would return
  ---@return table[]|nil
  local function definition_from(response)
    local out
    H.with_field(vim.lsp, "buf_request_sync", function()
      return { [1] = { result = response } }
    end, function()
      -- `has_client` must say yes for the request to be attempted at all.
      H.with_field(vim.lsp, "get_clients", function()
        return { { name = "fake" } }
      end, function()
        out = lsp.definition_at_cursor(50)
      end)
    end)
    return out
  end

  H.check(
    "definition_at_cursor: a single Location, 0-indexed, becomes a 1-indexed range",
    function()
      local out = definition_from({
        uri = vim.uri_from_fname(vim.fn.fnamemodify("/tmp/target.lua", ":p")),
        range = { start = { line = 9, character = 4 } },
      })
      H.truthy(out, "expected results")
      H.eq(#out, 1)
      H.match(out[1].path:gsub("\\", "/"), "target%.lua$")
      H.same(out[1].range, { line = 10, col = 5 }, "both fields shifted by one")
    end
  )

  H.check("definition_at_cursor: a list of Locations", function()
    local uri = vim.uri_from_fname(vim.fn.fnamemodify("/tmp/a.lua", ":p"))
    local out = definition_from({
      { uri = uri, range = { start = { line = 0, character = 0 } } },
      { uri = uri, range = { start = { line = 3, character = 2 } } },
    })
    H.eq(#out, 2)
    H.same(out[1].range, { line = 1, col = 1 }, "line 0 col 0 is position 1,1")
    H.same(out[2].range, { line = 4, col = 3 })
  end)

  H.check("definition_at_cursor: LocationLink's targetUri/targetRange are understood", function()
    local out = definition_from({
      {
        targetUri = vim.uri_from_fname(vim.fn.fnamemodify("/tmp/link.lua", ":p")),
        targetRange = { start = { line = 1, character = 1 } },
      },
    })
    H.eq(#out, 1)
    H.match(out[1].path:gsub("\\", "/"), "link%.lua$")
    H.same(out[1].range, { line = 2, col = 2 })
  end)

  H.check("definition_at_cursor: empty and malformed responses answer nil", function()
    H.is_nil(definition_from({}), "an empty list")
    H.is_nil(definition_from("not a table"), "a non-table result")
    H.is_nil(definition_from({ { uri = "file:///x" } }), "a Location with no range")
    H.is_nil(definition_from({ { range = { start = { line = 0, character = 0 } } } }), "no uri")

    local none
    H.with_field(vim.lsp, "buf_request_sync", function()
      return nil
    end, function()
      H.with_field(vim.lsp, "get_clients", function()
        return { { name = "fake" } }
      end, function()
        none = lsp.definition_at_cursor(50)
      end)
    end)
    H.is_nil(none, "a nil response (every server timed out)")
  end)

  H.check("definition_at_cursor: a vim.NIL uri/range is skipped, not thrown on (LUA-16)", function()
    -- JSON/LSP `null` decodes to vim.NIL, not Lua nil -- and vim.NIL is
    -- truthy, so `loc.uri or loc.targetUri` and a bare `if uri and rng`
    -- would both let it through undetected.
    local good_uri = vim.uri_from_fname(vim.fn.fnamemodify("/tmp/good.lua", ":p"))
    H.is_nil(
      definition_from({ { uri = vim.NIL, range = { start = { line = 0, character = 0 } } } }),
      "a NIL uri alone"
    )
    H.is_nil(definition_from({ { uri = good_uri, range = vim.NIL } }), "a NIL range alone")

    -- one bad entry does not take a good sibling down with it
    local out = definition_from({
      { uri = vim.NIL, range = { start = { line = 0, character = 0 } } },
      { uri = good_uri, range = { start = { line = 2, character = 0 } } },
    })
    H.eq(#out, 1, "only the valid entry survives")
    H.match(out[1].path:gsub("\\", "/"), "good%.lua$")
  end)

  H.check(
    "definition_at_cursor: a vim.NIL (or missing) range.start is skipped, not thrown on (LUA-16)",
    function()
      -- `range` itself surviving the nil/vim.NIL check does not mean
      -- `range.start` did too -- it is an independent JSON field that can
      -- just as easily decode to vim.NIL, or be omitted entirely (decoding
      -- to Lua nil). Either used to throw on `rng.start.line` one level
      -- below the check that LUA-16 originally added.
      local good_uri = vim.uri_from_fname(vim.fn.fnamemodify("/tmp/good.lua", ":p"))
      H.is_nil(
        definition_from({
          { uri = good_uri, range = { start = vim.NIL, ["end"] = { line = 2, character = 0 } } },
        }),
        "a NIL range.start"
      )
      H.is_nil(
        definition_from({ { uri = good_uri, range = { ["end"] = { line = 2, character = 0 } } } }),
        "a missing range.start"
      )

      -- one bad entry does not take an earlier, already-collected good
      -- sibling down with it
      local good_uri2 = vim.uri_from_fname(vim.fn.fnamemodify("/tmp/good2.lua", ":p"))
      local out = definition_from({
        { uri = good_uri, range = { start = { line = 0, character = 0 } } },
        { uri = good_uri2, range = { start = vim.NIL, ["end"] = { line = 2, character = 0 } } },
      })
      H.eq(#out, 1, "only the valid entry survives")
      H.match(out[1].path:gsub("\\", "/"), "good%.lua$")
    end
  )

  H.check("definition_at_cursor: no attached client means no request is even made", function()
    local asked = 0
    H.with_field(vim.lsp, "buf_request_sync", function()
      asked = asked + 1
      return nil
    end, function()
      H.with_field(vim.lsp, "get_clients", function()
        return {}
      end, function()
        H.is_nil(lsp.definition_at_cursor(50))
      end)
    end)
    H.eq(asked, 0, "buf_request_sync blocks for the whole timeout, so it is never entered")
  end)
end
