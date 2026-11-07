-- scripts/ci/specs/common_resolvers_spec.lua
-- The language-agnostic resolvers: the token/`<cfile>` one (filetoken), the
-- whole-line extractor behind it (extractor.find + extractor.helpers), the
-- `$VAR/...` one (env_path) and the `:help` one.
--
-- The truncated-path cache is replaced with an empty stand-in wherever a
-- resolver would consult it, so a hit or miss here is decided by the fixture
-- on disk rather than by whatever the machine running the suite happens to
-- have indexed.

---@param H table
return function(H)
  -- A cache that knows nothing, so the cache fast path never decides a case.
  local EMPTY_CACHE = {
    ["gopath.truncated.cache"] = {
      search = function()
        return {}
      end,
    },
  }

  -- ── extractor helpers ──────────────────────────────────────────────────────

  local helpers = require("gopath.resolvers.common.extractor.helpers")
  local TERMINATORS = require("gopath.resolvers.common.extractor.terminators")
  local find = require("gopath.resolvers.common.extractor.find")

  H.check("terminators: the characters that end a path token", function()
    for _, ch in ipairs({ " ", "\t", "(", ")", "<", ">", '"', "'", ",", ";", "|", "`" }) do
      H.eq(TERMINATORS[ch], true, ("%q terminates"):format(ch))
    end
    H.is_nil(TERMINATORS["/"], "a separator does not")
    H.is_nil(TERMINATORS["."], "nor does a dot")
    H.is_nil(TERMINATORS[":"], "nor a colon, so 'file:12' stays one token")
  end)

  H.check("expand_left / expand_right: the two ends are NOT symmetric", function()
    local s = 'say "a/b.lua" now'
    local at = s:find("b%.lua")
    H.eq(helpers.expand_left(s, at), 6, "left stops just AFTER the opening quote")
    H.eq(helpers.expand_right(s, at), 13, "right stops ON the closing quote, not before it")
    H.eq(s:sub(helpers.expand_left(s, at), helpers.expand_right(s, at)), 'a/b.lua"', "so it bleeds")

    local bare = "a/b.lua"
    H.eq(helpers.expand_left(bare, 3), 1, "no terminator to the left")
    H.eq(helpers.expand_right(bare, 3), #bare, "nor to the right")
  end)

  H.check("BUG: a line-extracted path keeps the character that ended it", function()
    -- `expand_left` returns `j + 1` when it stopped on a terminator;
    -- `expand_right` returns `j`. The right-hand terminator therefore lands
    -- inside the candidate, and only *bracket* terminators are cleaned up
    -- afterwards (by `strip_wrappers`). A space, comma, semicolon or quote
    -- stays put:
    local function raw_of(line)
      local out = find.by_extension(line)
      return out[1] and out[1].raw or nil
    end
    H.eq(
      raw_of("see lua/gopath/config.lua for all defaults"),
      "lua/gopath/config.lua ",
      "BUG: space"
    )
    H.eq(raw_of("edit docs/a.md, then run"), "docs/a.md,", "BUG: comma")
    H.eq(raw_of('open "docs/a.md" now'), 'docs/a.md"', "BUG: closing quote")
    H.eq(raw_of("docs/a.md at end of line"), "docs/a.md ", "BUG: space again")
    H.eq(raw_of("tail is docs/a.md"), "docs/a.md", "only a path at the very end comes out clean")

    -- Why it matters, and why it is easy to miss on Windows: the Win32 API
    -- silently tolerates a trailing space, so exactly the case that leaves one
    -- keeps working there and fails on Linux/macOS. A trailing comma or quote
    -- fails everywhere.
    local dir = H.tmpdir()
    local file = H.write(dir .. "/a.md", { "" })
    H.eq(vim.uv.fs_stat(file) ~= nil, true, "the file itself")
    H.eq(vim.uv.fs_stat(file .. ",") ~= nil, false, "a trailing comma never resolves")
    H.eq(vim.uv.fs_stat(file .. '"') ~= nil, false, "nor a trailing quote")
    H.eq(
      vim.uv.fs_stat(file .. " ") ~= nil,
      vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1,
      "a trailing space resolves on Windows only"
    )
  end)

  H.check("uniq: deduplicates by `raw`, keeps order, and drops keyless entries", function()
    local out = helpers.uniq({
      { raw = "a", path = "a" },
      { raw = "b", path = "b" },
      { raw = "a", path = "a-again" },
      { raw = "", path = "empty" },
      { path = "no raw at all" },
      false,
    })
    H.eq(#out, 2)
    H.eq(out[1].raw, "a", "first-seen order preserved")
    H.eq(out[1].path, "a", "and the first-seen value, not the later duplicate")
    H.eq(out[2].raw, "b")
    H.same(helpers.uniq({}), {}, "empty list")
    H.same(helpers.uniq(nil), {}, "nil list")
  end)

  H.check("uniq: the hand-rolled fallback behaves identically without lib.nvim", function()
    H.with_modules({ ["lib.lua.tables.unique_table"] = false }, function()
      local bare = require("gopath.resolvers.common.extractor.helpers")
      local out = bare.uniq({ { raw = "a" }, { raw = "a" }, { raw = "b" }, { raw = "" } })
      H.eq(#out, 2)
      H.eq(out[1].raw, "a")
      H.eq(out[2].raw, "b")
    end, { unload = { "gopath.resolvers.common.extractor.helpers" } })
    H.fresh("gopath.resolvers.common.extractor.helpers")
  end)

  -- ── extractor.find ─────────────────────────────────────────────────────────

  H.check("stack_patterns: path:line:col comes first; the :line pass also re-matches it", function()
    local out = find.stack_patterns("  at lua/gopath/resolve.lua:42:7 in function 'f'")
    H.eq(out[1].path, "lua/gopath/resolve.lua")
    H.eq(out[1].lineno, 42)
    H.eq(out[1].col, 7)

    -- Documented behaviour rather than a defect: the second (`path:line`) pass
    -- is greedy and matches ".../resolve.lua:42" as the *path* with 7 as the
    -- line, which the "skip duplicates" guard cannot recognise because it
    -- compares paths. It is harmless because the correct candidate is tried
    -- first and wins; it only costs one extra probe when nothing resolves.
    H.eq(#out, 2, "a second, greedier candidate follows")
    H.eq(out[2].path, "lua/gopath/resolve.lua:42")
    H.eq(out[2].lineno, 7)

    local no_col = find.stack_patterns("  at lua/gopath/resolve.lua:42 in function 'f'")
    H.eq(#no_col, 1)
    H.eq(no_col[1].lineno, 42)
    H.is_nil(no_col[1].col)

    H.same(find.stack_patterns("no path here"), {}, "nothing path-like")
    H.same(find.stack_patterns(""), {}, "empty line")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.same(find.stack_patterns(nil), {}, "nil line")
  end)

  H.check("stack_patterns: a Windows drive path keeps its drive", function()
    local out = find.stack_patterns([[Error in C:/Users/me/nvim/init.lua:14:3 unexpected]])
    H.truthy(#out >= 1, "extracted")
    H.eq(out[1].path, "C:/Users/me/nvim/init.lua", "the drive letter is part of the path")
    H.eq(out[1].lineno, 14)
    H.eq(out[1].col, 3)

    local back = find.stack_patterns([[at C:\Users\me\init.lua:9]])
    H.truthy(#back >= 1, "backslash spelling too")
    H.eq(back[1].path, [[C:\Users\me\init.lua]])
    H.eq(back[1].lineno, 9)
  end)

  H.check("by_extension: expands around a known extension, path-like results only", function()
    local out = find.by_extension("see lua/gopath/config.lua for all defaults")
    H.eq(#out, 1)
    H.match(out[1].path, "^lua/gopath/config%.lua")

    H.same(find.by_extension("the word config.lua alone"), {}, "no separator, not path-like")
    H.same(find.by_extension("[report](report.pdf)"), {}, "a bare filename is not path-like either")
    H.truthy(#find.by_extension("~/notes/todo.md") >= 1, "'~' counts as path-like")
    H.truthy(#find.by_extension([[C:\d\x.lua]]) >= 1, "a drive prefix counts too")
    H.truthy(#find.by_extension("../up/one.lua") >= 1, "'..' counts too")
  end)

  H.check(
    "by_extension: externally-openable extensions are visible to the line extractor",
    function()
      -- A Markdown link to a PDF used to be invisible whenever the cursor sat on
      -- the label instead of the path.
      local out = find.by_extension("[report](docs/report.pdf)")
      H.truthy(#out >= 1, "the .pdf candidate was extracted")
      H.eq(out[1].path, "docs/report.pdf", "and the unbalanced ')' was dropped")

      local img = find.by_extension("![shot](assets/pic.png)")
      H.truthy(#img >= 1)
      H.eq(img[1].path, "assets/pic.png")
    end
  )

  H.check("by_extension: a link to a mail file is found like one to a PDF", function()
    local out = find.by_extension("[SolMan](docs/mail/Anfrage.msg)")
    H.truthy(#out >= 1, "the .msg candidate was extracted")
    H.eq(out[1].path, "docs/mail/Anfrage.msg", "and the unbalanced ')' was dropped")
    -- A field of that name in code has no separator in front of it: not path-like, not a candidate.
    H.same(find.by_extension("print(err.msg)"), {}, "err.msg in code is no path")
  end)

  H.check("by_extension: a user's external.extensions reach the line extractor too", function()
    H.config_sandbox(function(c)
      H.same(find.by_extension("[b](books/x.epub)"), {}, "not known yet")
      c.setup({ external = { extensions = { "epub" } } })
      local out = find.by_extension("[b](books/x.epub)")
      H.truthy(#out >= 1, "the configured extension is picked up")
      H.eq(out[1].path, "books/x.epub")
    end)
    -- The merged list is memoised on the extras table's identity; restoring the
    -- config restores the previous table, so the next call rebuilds.
    H.same(find.by_extension("[b](books/y.epub)"), {}, "and the memo did not outlive the config")
  end)

  H.check("by_extension: a balanced bracket pair inside a name is kept", function()
    local out = find.by_extension([[C:\Program Files (x86)\tool\readme.md]])
    H.truthy(#out >= 1)
    -- The space terminates expansion, so only the last segment survives — what
    -- matters is that the ")" was not stripped from a balanced pair.
    H.no_match(
      table.concat(
        vim.tbl_map(function(e)
          return e.path
        end, out),
        "\n"
      ),
      "%(x86$",
      "an opener with no closer is not produced"
    )
  end)

  H.check("absolute_paths: unix, Windows and UNC forms", function()
    local unix = find.absolute_paths("module '/usr/share/nvim/runtime/lua/vim/lsp.lua' not found")
    H.truthy(#unix >= 1)
    -- Same bleeding as by_extension, from the other direction: the character
    -- class the pattern walks includes every punctuation mark, so a closing
    -- quote that had no opener at the start of the match survives.
    H.eq(
      unix[1].path,
      "/usr/share/nvim/runtime/lua/vim/lsp.lua'",
      "BUG: the trailing quote is kept"
    )

    local win = find.absolute_paths([[loaded from C:\Users\me\init.lua]])
    H.truthy(#win >= 1)
    H.eq(win[1].path, [[C:\Users\me\init.lua]])

    local unc = find.absolute_paths([[\\server\share\file.txt]])
    H.truthy(#unc >= 1)
    H.eq(unc[1].path, [[\\server\share\file.txt]])

    H.eq(#find.absolute_paths("relative/only.lua"), 1, "a relative path yields a bogus '/only.lua'")
    H.eq(
      find.absolute_paths("relative/only.lua")[1].path,
      "/only.lua",
      "harmless: it simply will not exist, and the real candidate comes from by_extension"
    )
    H.same(find.absolute_paths("no slashes here"), {}, "nothing absolute")
    H.same(find.absolute_paths(""), {}, "empty line")
  end)

  -- ── linepath ───────────────────────────────────────────────────────────────

  local linepath = require("gopath.resolvers.common.linepath")

  H.check("linepath: an absolute path anywhere on the line, cursor irrelevant", function()
    H.with_modules(EMPTY_CACHE, function()
      local dir = H.tmpdir()
      local file = H.write(dir .. "/target.lua", { "" })
      H.line_at("Error in " .. file .. ":14:3 unexpected token", "Error", { filetype = "lua" })
      local r = linepath.resolve()
      H.truthy(r, "expected a result")
      H.eq(r.path, vim.fs.normalize(file))
      H.eq(r.source, "linepath-absolute")
      H.eq(r.confidence, 0.92)
      H.same(r.range, { line = 14, col = 3 }, "the stacktrace position came along")
      H.eq(r.exists, true)
    end)
  end)

  H.check("linepath: a cwd-relative path is caught by step 1, not step 2", function()
    H.with_modules(EMPTY_CACHE, function()
      local dir = H.tmpdir()
      H.write(dir .. "/rel/here.lua", { "" })
      local saved = vim.fn.getcwd()
      vim.cmd.cd(vim.fn.fnameescape(dir))
      -- The path sits at the end of the line, so the terminator bug pinned
      -- above cannot colour this case platform-dependently.
      H.line_at("see rel/here.lua", "see", { filetype = "text" })
      local r = linepath.resolve()
      vim.cmd.cd(vim.fn.fnameescape(saved))

      H.truthy(r, "expected a result")
      -- Pinned as behaviour: `fs_stat` resolves a relative path against the
      -- process cwd, so the "absolute" probe already answers for cwd-relative
      -- candidates and the explicit cwd join below it (`linepath-relative`)
      -- is effectively unreachable. The visible consequence is that the
      -- result's `path` stays relative rather than being made absolute.
      H.eq(r.source, "linepath-absolute")
      H.eq(r.confidence, 0.92)
      H.eq(r.path, "rel/here.lua", "returned as written, not resolved to an absolute path")
    end)
  end)

  H.check("linepath: a backslash-spelled relative path resolves on Linux too", function()
    H.with_modules(EMPTY_CACHE, function()
      local dir = H.tmpdir()
      H.write(dir .. "/rel/here.lua", { "" })
      local saved = vim.fn.getcwd()
      vim.cmd.cd(vim.fn.fnameescape(dir))
      -- `vim.fs.normalize` only rewrites "\" to "/" on Windows itself -- a
      -- backslash-spelled candidate extracted verbatim from the line's raw
      -- text (extractor/find.lua's by_extension accepts either separator)
      -- must still resolve on Linux/macOS. Same defect class, and same fix,
      -- as util.path.exists() and tailsearch.normalize() (see commit
      -- 20b3132; linepath.lua was the one direct fs_stat site that commit
      -- missed).
      H.line_at("see rel\\here.lua", "see", { filetype = "text" })
      local r = linepath.resolve()
      vim.cmd.cd(vim.fn.fnameescape(saved))

      H.truthy(r, "expected a result even though the line spelled the path with a backslash")
      H.eq(r.source, "linepath-absolute", "same step-1 shortcut as the forward-slash spelling")
      H.eq(r.path, "rel/here.lua", "normalised to forward slashes")
    end)
  end)

  H.check("linepath: a document-relative link resolves against the buffer's directory", function()
    H.with_modules(EMPTY_CACHE, function()
      local dir = H.tmpdir()
      H.write(dir .. "/docs/assets/report.pdf", { "%PDF" })
      local note = H.write(dir .. "/docs/note.md", { "see [report](assets/report.pdf) please" })
      -- cwd is somewhere else entirely, so only the buffer's own directory can
      -- resolve this.
      vim.cmd.edit(vim.fn.fnameescape(note))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local r = linepath.resolve()
      H.truthy(r, "expected a result")
      H.eq(r.source, "linepath-bufdir", "a link in a document is document-relative")
      H.eq(r.confidence, 0.9)
      H.match(r.path, "docs/assets/report%.pdf$")
    end)
  end)

  H.check("linepath: the cache tail search is the last step and is discounted", function()
    local dir = H.tmpdir()
    local deep = dir .. "/x/y/z/only-here.lua"
    H.write(deep, { "" })
    H.with_modules({
      ["gopath.truncated.cache"] = {
        search = function(tail)
          if tail:find("only%-here") then return { deep } end
          return {}
        end,
      },
    }, function()
      H.line_at("mentioned as y/z/only-here.lua somewhere", "mentioned", { filetype = "text" })
      local r = linepath.resolve()
      H.truthy(r, "expected a result")
      H.eq(r.source, "linepath-tail")
      H.truthy(r.confidence < 0.85, "discounted against a direct hit: " .. tostring(r.confidence))
    end)
  end)

  H.check("linepath: nothing on the line, and the disable switch", function()
    H.with_modules(EMPTY_CACHE, function()
      H.line_at("this line has no file path at all, just words", "words", { filetype = "text" })
      H.is_nil(linepath.resolve(), "no candidates")

      H.line_at("", "", { filetype = "text" })
      H.is_nil(linepath.resolve(), "an empty line")

      H.config_sandbox(function(c)
        c.setup({ linepath = { enable = false } })
        local dir = H.tmpdir()
        local file = H.write(dir .. "/off.lua", { "" })
        H.line_at("see " .. file, "see", { filetype = "text" })
        H.is_nil(linepath.resolve(), "linepath.enable = false")
      end)
    end)
  end)

  -- ── filetoken ──────────────────────────────────────────────────────────────

  local filetoken = require("gopath.resolvers.common.filetoken")

  H.check("filetoken: an existing file under the cursor", function()
    H.with_modules(EMPTY_CACHE, function()
      local dir = H.tmpdir()
      local file = H.write(dir .. "/ft_target.lua", { "" })
      H.line_at("open " .. file .. " now", "ft_target", { filetype = "text" })
      local r = filetoken.resolve()
      H.truthy(r, "expected a result")
      H.eq(r.exists, true)
      -- A plain path is a "file" whether it exists or not: "module" is a language module (require,
      -- import, ...). The menu's Reveal entries are offered for kind == "file" only.
      H.eq(r.kind, "file")
      H.eq(r.confidence, 0.75)
      H.eq(r.path, (file:gsub("\\", "/")), "stored with forward slashes")
    end)
  end)

  H.check("filetoken: a :line:col suffix becomes the range", function()
    H.with_modules(EMPTY_CACHE, function()
      local dir = H.tmpdir()
      local file = H.write(dir .. "/ft_range.lua", { "", "", "" })
      H.line_at(file .. ":2:5", "ft_range", { filetype = "text" })
      local r = filetoken.resolve()
      H.truthy(r)
      H.same(r.range, { line = 2, col = 5 })
    end)
  end)

  H.check("filetoken: a dotted identifier is left to the language resolvers", function()
    H.with_modules(EMPTY_CACHE, function()
      H.line_at('local x = require("a.b.c.d")', "a.b.c", { filetype = "lua" })
      H.is_nil(filetoken.resolve(), "a module name is not a path")
      H.line_at("value = obj.field.sub", "field", { filetype = "lua" })
      H.is_nil(filetoken.resolve(), "a method chain is not a path")
    end)
  end)

  H.check("filetoken: a dotted name whose last segment is a known extension IS a path", function()
    H.with_modules(EMPTY_CACHE, function()
      local dir = H.tmpdir()
      H.write(dir .. "/README.md", { "" })
      local saved = vim.fn.getcwd()
      vim.cmd.cd(vim.fn.fnameescape(dir))
      H.line_at("see README.md for details", "README", { filetype = "text" })
      local r = filetoken.resolve()
      vim.cmd.cd(vim.fn.fnameescape(saved))
      H.truthy(r, "expected a result")
      H.eq(r.exists, true)
    end)
  end)

  H.check("filetoken: a missing path still comes back, marked and low-confidence", function()
    H.with_modules(EMPTY_CACHE, function()
      local dir = H.tmpdir()
      H.write(dir .. "/host.md", { "link to ./sub/missing.lua here" })
      vim.cmd.edit(vim.fn.fnameescape(dir .. "/host.md"))
      H.cursor_on(1, "missing")
      local r = filetoken.resolve()
      H.truthy(r, "a speculative result is still useful to the async layer")
      H.eq(r.exists, false)
      H.eq(r.kind, "file")
      H.eq(r.confidence, 0.3)
      H.match(r.path, "sub/missing%.lua$")
      H.match(
        r.path,
        "^" .. vim.pesc((dir:gsub("\\", "/"))),
        "joined against the buffer's directory"
      )
    end)
  end)

  H.check("filetoken: a URL is handed back verbatim, never joined to a directory", function()
    H.with_modules(EMPTY_CACHE, function()
      H.line_at("See http://www.google.com for details.", "http", { filetype = "markdown" })
      local r = filetoken.resolve()
      H.truthy(r, "expected a result")
      H.eq(r.kind, "url")
      H.eq(r.path, "http://www.google.com", "not '<cwd>/http:/www.google.com'")
      H.eq(r.exists, true, "so create-on-missing is skipped")
      H.eq(r.confidence, 0.9)
    end)
  end)

  H.check("filetoken: noise prefixes from error output are stripped", function()
    H.with_modules(EMPTY_CACHE, function()
      local dir = H.tmpdir()
      H.write(dir .. "/noise.lua", { "" })
      local saved = vim.fn.getcwd()
      vim.cmd.cd(vim.fn.fnameescape(dir))
      -- The "..." prefix marks a truncated path in terminal output.
      H.line_at(".../noise.lua", "noise", { filetype = "text" })
      local r = filetoken.resolve()
      vim.cmd.cd(vim.fn.fnameescape(saved))
      H.truthy(r, "expected a result")
      H.match(r.path, "noise%.lua$")
    end)
  end)

  H.check("filetoken: a runtimepath tail is found via the rtp search", function()
    H.with_modules(EMPTY_CACHE, function()
      local rtp = H.tmpdir()
      H.write(rtp .. "/lua/ftrtp/mod.lua", { "" })
      vim.opt.runtimepath:append(rtp)
      require("gopath.util.path").invalidate_caches()

      H.line_at("at /somewhere/lua/ftrtp/mod.lua:3", "ftrtp", { filetype = "text" })
      local r = filetoken.resolve()

      vim.opt.runtimepath:remove(rtp)
      require("gopath.util.path").invalidate_caches()

      H.truthy(r, "expected a result")
      H.eq(r.exists, true, "the '/lua/<tail>' strip found it on the runtimepath")
      H.match(r.path, "ftrtp/mod%.lua$")
    end)
  end)

  H.check("filetoken: an empty line yields nothing", function()
    H.with_modules(EMPTY_CACHE, function()
      H.line_at("", "", { filetype = "text" })
      H.is_nil(filetoken.resolve())
    end)
  end)

  -- ── env_path ───────────────────────────────────────────────────────────────

  local env_path = require("gopath.resolvers.common.env_path")

  H.check("env_path: $VAR, ${VAR} and backslash separators all resolve", function()
    local dir = H.tmpdir()
    H.write(dir .. "/notes/todo.md", { "" })
    vim.env.GOPATH_SPEC_ROOT = dir

    for _, form in ipairs({
      "$GOPATH_SPEC_ROOT/notes/todo.md",
      "${GOPATH_SPEC_ROOT}/notes/todo.md",
      [[$GOPATH_SPEC_ROOT\notes\todo.md]],
    }) do
      H.line_at("see " .. form .. " there", "GOPATH_SPEC_ROOT", { filetype = "markdown" })
      local r = env_path.resolve()
      H.truthy(r, "expected a result for " .. form)
      H.eq(r.exists, true, form)
      H.eq(r.source, "env-path")
      H.eq(r.confidence, 0.95)
      H.match((r.path:gsub("\\", "/")), "notes/todo%.md$", form)
    end
    vim.env.GOPATH_SPEC_ROOT = nil
  end)

  H.check("env_path: a bare $VAR resolves to the directory itself", function()
    local dir = H.tmpdir()
    H.write(dir .. "/x", { "" })
    vim.env.GOPATH_SPEC_ROOT = dir
    H.line_at("cd $GOPATH_SPEC_ROOT", "GOPATH", { filetype = "sh" })
    local r = env_path.resolve()
    H.truthy(r, "expected a result")
    H.eq(r.exists, false, "a directory is not a regular file")
    H.eq(r.confidence, 0.4, "and is scored accordingly")
    vim.env.GOPATH_SPEC_ROOT = nil
  end)

  H.check("env_path: a :line:col suffix is separated from the path", function()
    local dir = H.tmpdir()
    H.write(dir .. "/code.lua", { "", "", "" })
    vim.env.GOPATH_SPEC_ROOT = dir
    H.line_at("at $GOPATH_SPEC_ROOT/code.lua:3:2 here", "GOPATH", { filetype = "text" })
    local r = env_path.resolve()
    H.truthy(r)
    H.eq(r.exists, true, "the suffix did not end up in the filename")
    H.same(r.range, { line = 3, col = 2 })
    vim.env.GOPATH_SPEC_ROOT = nil
  end)

  H.check("env_path: a Markdown link's parentheses stay out of the token", function()
    local dir = H.tmpdir()
    H.write(dir .. "/doc.md", { "" })
    vim.env.GOPATH_SPEC_ROOT = dir
    H.line_at("[text]($GOPATH_SPEC_ROOT/doc.md)", "GOPATH", { filetype = "markdown" })
    local r = env_path.resolve()
    H.truthy(r)
    H.eq(r.exists, true)
    H.no_match(r.path, "%)", "no trailing paren in the resolved path")
    vim.env.GOPATH_SPEC_ROOT = nil
  end)

  H.check("env_path: an unset variable, a non-$ token, and the disable switch", function()
    vim.env.GOPATH_SPEC_UNSET = nil
    H.line_at("see $GOPATH_SPEC_UNSET/x.md", "GOPATH", { filetype = "text" })
    H.is_nil(env_path.resolve(), "an unset variable resolves to nothing")

    H.line_at("see plain/path.md", "plain", { filetype = "text" })
    H.is_nil(env_path.resolve(), "no $ prefix")

    H.line_at("chain $obj.field", "obj", { filetype = "text" })
    H.is_nil(env_path.resolve(), "a '$VAR.field' chain is not an env path")

    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      H.write(dir .. "/y.md", { "" })
      vim.env.GOPATH_SPEC_ROOT = dir
      c.setup({ env_variable_resolution = { enable = false } })
      H.line_at("see $GOPATH_SPEC_ROOT/y.md", "GOPATH", { filetype = "text" })
      H.is_nil(env_path.resolve(), "switched off")
      vim.env.GOPATH_SPEC_ROOT = nil
    end)
  end)

  H.check("env_path: a name unset in the environment falls back to shorten_known_dirs", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      H.write(dir .. "/init.lua", { "" })
      vim.env.GOPATH_SPEC_KNOWN = nil
      c.setup({
        env_variable_resolution = { shorten_known_dirs = { GOPATH_SPEC_KNOWN = dir } },
      })
      H.line_at("open $GOPATH_SPEC_KNOWN/init.lua", "GOPATH", { filetype = "lua" })
      local r = env_path.resolve()
      H.truthy(r, "resolved via the known-dir fallback, no real env var needed")
      H.eq(r.exists, true)
    end)
  end)

  H.check("env_path: a resolver function is called fresh (needed for stdpath())", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      H.write(dir .. "/x.lua", { "" })
      c.setup({
        env_variable_resolution = {
          shorten_known_dirs = {
            GOPATH_SPEC_KNOWN = function()
              return dir
            end,
          },
        },
      })
      H.line_at("open $GOPATH_SPEC_KNOWN/x.lua", "GOPATH", { filetype = "lua" })
      local r = env_path.resolve()
      H.truthy(r)
      H.eq(r.exists, true)
    end)
  end)

  H.check("env_path: a real environment variable always wins over a known-dir fallback", function()
    H.config_sandbox(function(c)
      local real_dir = H.tmpdir()
      local known_dir = H.tmpdir()
      H.write(real_dir .. "/z.lua", { "" })
      vim.env.GOPATH_SPEC_KNOWN = real_dir
      c.setup({
        env_variable_resolution = { shorten_known_dirs = { GOPATH_SPEC_KNOWN = known_dir } },
      })
      H.line_at("open $GOPATH_SPEC_KNOWN/z.lua", "GOPATH", { filetype = "lua" })
      local r = env_path.resolve()
      H.truthy(r)
      H.eq(r.exists, true, "found under the real env var's directory, not the known-dir one")
      vim.env.GOPATH_SPEC_KNOWN = nil
    end)
  end)

  H.check("env_path: a root of lib.nvim's registry resolves without an env var", function()
    local roots = require("lib.nvim.fs.roots")
    local dir = H.tmpdir()
    H.write(dir .. "/reg.lua", { "" })
    vim.env.GOPATH_SPEC_REG = nil
    local unregister = roots.register("GOPATH_SPEC_REG", dir)
    local ok, err = pcall(function()
      H.line_at("open $GOPATH_SPEC_REG/reg.lua", "GOPATH", { filetype = "lua" })
      local r = env_path.resolve()
      H.truthy(r, "resolved through the registry")
      H.eq(r.exists, true)
    end)
    unregister()
    if not ok then error(err, 0) end
  end)

  H.check("env_path: a stale $NVIM_CONFIG_DIR in the environment loses to stdpath", function()
    H.config_sandbox(function()
      local saved = vim.env.NVIM_CONFIG_DIR
      -- What a parent Neovim with another NVIM_APPNAME leaves behind.
      vim.env.NVIM_CONFIG_DIR = H.tmpdir()
      local ok, err = pcall(function()
        H.line_at("open $NVIM_CONFIG_DIR", "NVIM_CONFIG", { filetype = "lua" })
        local r = env_path.resolve()
        H.truthy(r)
        H.eq((r.path:gsub("\\", "/")), (vim.fn.stdpath("config"):gsub("\\", "/")))
      end)
      vim.env.NVIM_CONFIG_DIR = saved
      if not ok then error(err, 0) end
    end)
  end)

  H.check("env_path.resolve_text: resolves a raw string with no cursor/buffer involved", function()
    H.config_sandbox(function()
      local dir = H.tmpdir()
      H.write(dir .. "/x.lua", { "" })
      vim.env.GOPATH_SPEC_TEXT = dir
      local r = env_path.resolve_text("$GOPATH_SPEC_TEXT/x.lua")
      H.truthy(r, "resolved directly from the string, without a buffer")
      H.eq(r.exists, true)
      vim.env.GOPATH_SPEC_TEXT = nil
    end)
  end)

  H.check("env_path.resolve_text: nil for a non-string, empty string, or non-$ text", function()
    H.is_nil(env_path.resolve_text(nil))
    H.is_nil(env_path.resolve_text(""))
    H.is_nil(env_path.resolve_text("plain/path.md"))
  end)

  H.check("env_path.resolve_text: respects the enable flag, same as M.resolve()", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      vim.env.GOPATH_SPEC_TEXT = dir
      c.setup({ env_variable_resolution = { enable = false } })
      H.is_nil(env_path.resolve_text("$GOPATH_SPEC_TEXT/x.lua"), "switched off")
      vim.env.GOPATH_SPEC_TEXT = nil
    end)
  end)

  H.check("env_path: $NVIM_CONFIG_DIR resolves via stdpath('config') by default", function()
    H.config_sandbox(function()
      local saved = vim.env.NVIM_CONFIG_DIR
      vim.env.NVIM_CONFIG_DIR = nil
      local ok, err = pcall(function()
        H.line_at("open $NVIM_CONFIG_DIR", "NVIM_CONFIG", { filetype = "lua" })
        local r = env_path.resolve()
        H.truthy(r, "resolved without any env var being set")
        H.eq((r.path:gsub("\\", "/")), (vim.fn.stdpath("config"):gsub("\\", "/")))
      end)
      vim.env.NVIM_CONFIG_DIR = saved
      if not ok then error(err, 0) end
    end)
  end)

  -- ── help ───────────────────────────────────────────────────────────────────

  local help = require("gopath.resolvers.common.help")

  H.check("help: the four namespace tokens", function()
    local cases = {
      { "local x = vim", "vim", { "vim" } },
      { "vim.api", "vim.api", { "vim.api" } },
      { "vim.fn", "vim.fn", { "vim.fn" } },
      { "vim.loop", "vim.loop", { "vim.loop", "luv" } },
    }
    for _, case in ipairs(cases) do
      H.line_at(case[1], case[2], { filetype = "lua" })
      local r = help.resolve()
      H.truthy(r, "expected a result for " .. case[2])
      H.eq(r.kind, "help")
      H.eq(r.language, "help")
      H.eq(r.confidence, 1.0)
      H.same(r.subjects, case[3], case[2])
      H.eq(r.subject, case[3][1], "the primary candidate is the first")
    end
  end)

  H.check("help: api and fn functions become `name()` with a namespace fallback", function()
    H.line_at("vim.api.nvim_buf_set_lines(0, 0, -1, false, {})", "nvim_buf", { filetype = "lua" })
    H.same(help.resolve().subjects, { "nvim_buf_set_lines()", "vim.api" })

    H.line_at("vim.fn.expand('%')", "expand", { filetype = "lua" })
    H.same(help.resolve().subjects, { "expand()", "vim.fn" })

    H.line_at("nvim_get_current_line()", "nvim_get", { filetype = "lua" })
    H.same(help.resolve().subjects, { "nvim_get_current_line()", "vim.api" })

    H.line_at("vim.loop.new_timer()", "new_timer", { filetype = "lua" })
    H.same(help.resolve().subjects, { "vim.loop", "luv" }, "no per-function luv tags exist")
  end)

  H.check("help: bracket notation is normalised to dots", function()
    H.line_at('vim.api["nvim_win_close"](0, true)', "nvim_win", { filetype = "lua" })
    H.same(help.resolve().subjects, { "nvim_win_close()", "vim.api" })
    H.line_at("vim.api['nvim_win_close'](0, true)", "nvim_win", { filetype = "lua" })
    H.same(help.resolve().subjects, { "nvim_win_close()", "vim.api" })
  end)

  H.check("help: anything that is not a vim/api/fn token answers nil", function()
    H.line_at("local config = require('gopath.config')", "config", { filetype = "lua" })
    H.is_nil(help.resolve(), "an ordinary identifier")
    H.line_at("", "", { filetype = "lua" })
    H.is_nil(help.resolve(), "an empty line")
    H.line_at("some.other.namespace.fn()", "namespace", { filetype = "lua" })
    H.is_nil(help.resolve(), "a lookalike chain")
  end)
end
