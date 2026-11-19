-- scripts/ci/specs/util_path_spec.lua
-- gopath.util.path: separator-normalising join, existence, and the four search
-- strategies (runtimepath, &path, package.path, plugin install dirs).
--
-- Everything here runs against real directories under vim.fn.tempname(): the
-- module's whole job is to stat and scandir, so a mocked filesystem would test
-- the mock. The one substituted dependency is lazy.nvim's `lazy.core.config`,
-- which is not installed in CI and is the documented source for strategy 4.

---@param H table
return function(H)
  local PATH = require("gopath.util.path")

  -- ── join ───────────────────────────────────────────────────────────────────

  H.check("join: normalises every separator to '/'", function()
    H.eq(PATH.join("a", "b", "c"), "a/b/c", "plain")
    H.eq(PATH.join("a\\b", "c"), "a/b/c", "backslashes in a segment")
    H.eq(PATH.join("a/b\\c", "d\\e"), "a/b/c/d/e", "mixed separators in one call")
  end)

  H.check("join: collapses runs of separators and drops inner trailing ones", function()
    H.eq(PATH.join("a//b", "c"), "a/b/c", "doubled forward slashes")
    H.eq(PATH.join("a\\\\b", "c"), "a/b/c", "doubled backslashes (a UNC-looking prefix)")
    H.eq(PATH.join("a/", "b"), "a/b", "trailing separator on a non-final segment")
  end)

  H.check("join: a Windows drive prefix survives intact", function()
    H.eq(PATH.join("C:\\repos", "gopath.nvim", "init.lua"), "C:/repos/gopath.nvim/init.lua")
    H.eq(PATH.join("E:/repos", "x"), "E:/repos/x")
  end)

  H.check("join: empty segments (a documented quirk, not a defect)", function()
    H.eq(PATH.join(), "", "no arguments at all")
    H.eq(PATH.join("a", ""), "a/", "an explicit empty tail keeps its separator")
    H.eq(PATH.join("a", "", "b"), "a//b", "and an empty middle doubles it")
    H.eq(PATH.join("", "b"), "/b", "an empty leading segment yields a rooted-looking path")
  end)

  -- ── exists ─────────────────────────────────────────────────────────────────

  H.check("exists: files yes, directories no, junk no", function()
    local dir = H.tmpdir()
    local file = H.write(dir .. "/real.lua", { "return {}" })
    H.eq(PATH.exists(file), true, "a regular file")
    H.eq(PATH.exists(dir), false, "a directory is not a file")
    H.eq(PATH.exists(dir .. "/nope.lua"), false, "a missing path")
    H.eq(PATH.exists(""), false, "the empty string")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.eq(PATH.exists(nil), false, "nil")
  end)

  H.check("exists: accepts a backslash spelling of the same file", function()
    local dir = H.tmpdir()
    H.write(dir .. "/win.lua", { "" })
    H.eq(PATH.exists(dir .. "/win.lua"), true, "forward slashes")
    H.eq(PATH.exists((dir .. "/win.lua"):gsub("/", "\\")), true, "backslashes")
  end)

  -- ── search_in_rtp ──────────────────────────────────────────────────────────

  H.check("search_in_rtp: probes <rtp>/<cand> before <rtp>/lua/<cand>", function()
    local dir = H.tmpdir()
    H.write(dir .. "/top/mod.lua", { "-- top" })
    H.write(dir .. "/lua/top/mod.lua", { "-- lua" })

    vim.opt.runtimepath:append(dir)
    PATH.invalidate_caches()
    local hit = PATH.search_in_rtp({ "top/mod.lua" })
    vim.opt.runtimepath:remove(dir)
    PATH.invalidate_caches()

    H.truthy(hit, "expected a hit")
    H.match(hit, "top/mod%.lua$", "resolved file")
    H.no_match(hit, "/lua/top", "the root-level candidate wins over the lua/ one")
  end)

  H.check("search_in_rtp: falls back to <rtp>/lua/<cand>", function()
    local dir = H.tmpdir()
    H.write(dir .. "/lua/only/there.lua", { "" })

    vim.opt.runtimepath:append(dir)
    PATH.invalidate_caches()
    local hit = PATH.search_in_rtp({ "only/there.lua" })
    vim.opt.runtimepath:remove(dir)
    PATH.invalidate_caches()

    H.truthy(hit, "expected a hit under lua/")
    H.match(hit, "lua/only/there%.lua$")
  end)

  H.check("search_in_rtp: candidate order decides, not runtimepath order", function()
    local dir = H.tmpdir()
    H.write(dir .. "/a/x.lua", { "" })
    H.write(dir .. "/b/x.lua", { "" })

    vim.opt.runtimepath:append(dir)
    PATH.invalidate_caches()
    local first = PATH.search_in_rtp({ "b/x.lua", "a/x.lua" })
    vim.opt.runtimepath:remove(dir)
    PATH.invalidate_caches()

    H.match(first, "/b/x%.lua$", "the first candidate that exists wins")
  end)

  H.check("search_in_rtp: empty input and total misses answer nil", function()
    H.is_nil(PATH.search_in_rtp({}), "no candidates")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.is_nil(PATH.search_in_rtp(nil), "nil candidates")
    H.is_nil(
      PATH.search_in_rtp({ "definitely/not/here_" .. os.time() .. ".lua" }),
      "a candidate no root has"
    )
  end)

  H.check("search_in_rtp: cwd is the last resort", function()
    local dir = H.tmpdir()
    H.write(dir .. "/cwdonly.lua", { "" })
    local saved = vim.fn.getcwd()
    vim.cmd.cd(vim.fn.fnameescape(dir))
    PATH.invalidate_caches()
    local hit = PATH.search_in_rtp({ "cwdonly.lua" })
    vim.cmd.cd(vim.fn.fnameescape(saved))
    PATH.invalidate_caches()

    H.truthy(hit, "expected the cwd fallback to fire")
    H.match(hit, "cwdonly%.lua$")
  end)

  H.check("invalidate_caches: a file created after the index was built is found", function()
    local dir = H.tmpdir()
    H.mkdir(dir)
    vim.opt.runtimepath:append(dir)
    PATH.invalidate_caches()

    -- Build the index while the root is still empty.
    H.is_nil(PATH.search_in_rtp({ "late.lua" }), "not there yet")

    H.write(dir .. "/late.lua", { "" })
    -- Without the invalidation the cached name index still says the root is
    -- empty, and the first-segment gate rejects the candidate without a stat.
    H.is_nil(PATH.search_in_rtp({ "late.lua" }), "stale index hides the new top-level name")

    PATH.invalidate_caches()
    local hit = PATH.search_in_rtp({ "late.lua" })
    vim.opt.runtimepath:remove(dir)
    PATH.invalidate_caches()
    H.truthy(hit, "after invalidation it resolves")
  end)

  H.check(
    "search_in_rtp: a file added under an already-indexed directory needs no invalidation",
    function()
      local dir = H.tmpdir()
      H.write(dir .. "/pkg/first.lua", { "" })
      vim.opt.runtimepath:append(dir)
      PATH.invalidate_caches()
      H.truthy(PATH.search_in_rtp({ "pkg/first.lua" }), "builds the index")

      -- Only the FIRST path segment is indexed, so "pkg" being known is enough.
      H.write(dir .. "/pkg/second.lua", { "" })
      local hit = PATH.search_in_rtp({ "pkg/second.lua" })
      vim.opt.runtimepath:remove(dir)
      PATH.invalidate_caches()
      H.truthy(hit, "a sibling under a known root resolves without invalidation")
    end
  )

  -- ── search_with_vim_path ───────────────────────────────────────────────────

  H.check("search_with_vim_path: an existing path is returned absolute", function()
    local dir = H.tmpdir()
    local file = H.write(dir .. "/direct.txt", { "" })
    local hit = PATH.search_with_vim_path(file)
    H.truthy(hit, "expected a hit")
    H.eq(vim.fn.fnamemodify(hit, ":p"), vim.fn.fnamemodify(file, ":p"), "same file")
  end)

  H.check("search_with_vim_path: &path lookup and suffixesadd", function()
    local dir = H.tmpdir()
    H.write(dir .. "/inpath.lua", { "" })
    local saved_path, saved_sfx = vim.o.path, vim.o.suffixesadd
    vim.o.path = dir
    vim.o.suffixesadd = ".lua"

    local by_name = PATH.search_with_vim_path("inpath.lua")
    local by_suffix = PATH.search_with_vim_path("inpath")
    local miss = PATH.search_with_vim_path("absent_" .. os.time())

    vim.o.path, vim.o.suffixesadd = saved_path, saved_sfx

    H.truthy(by_name, "found via &path")
    H.truthy(by_suffix, "found by appending a &suffixesadd entry")
    H.is_nil(miss, "a name nothing on &path has")
  end)

  H.check("search_with_vim_path: empty token", function()
    H.is_nil(PATH.search_with_vim_path(""), "empty string")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.is_nil(PATH.search_with_vim_path(nil), "nil")
  end)

  -- ── search_with_package_path ───────────────────────────────────────────────

  H.check("search_with_package_path: resolves a dotted name via package.path", function()
    local dir = H.tmpdir()
    H.write(dir .. "/rock/inner.lua", { "return {}" })
    local saved = package.path
    package.path = dir .. "/?.lua;" .. package.path
    local hit = PATH.search_with_package_path("rock.inner")
    local miss = PATH.search_with_package_path("rock.absent")
    package.path = saved

    H.truthy(hit, "expected a hit")
    H.match(hit:gsub("\\", "/"), "rock/inner%.lua$")
    H.is_nil(miss, "a module package.path cannot find")
  end)

  H.check("search_with_package_path: rejects non-strings and empties", function()
    H.is_nil(PATH.search_with_package_path(""), "empty")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.is_nil(PATH.search_with_package_path(nil), "nil")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.is_nil(PATH.search_with_package_path(42), "a number")
  end)

  -- ── search_in_plugin_dirs ──────────────────────────────────────────────────

  -- The plugin-dir list is keyed on the runtimepath string alone, and (see the
  -- BUG check at the end of this file) `invalidate_caches()` does not clear it.
  -- Moving the runtimepath is therefore the only way to force a rebuild, which
  -- is exactly what installing a plugin does in real life.
  ---@param fn fun()
  local function with_fresh_plugin_index(fn)
    local nudge = H.tmpdir()
    vim.opt.runtimepath:append(nudge)
    PATH.invalidate_caches()
    local ok, err = pcall(fn)
    vim.opt.runtimepath:remove(nudge)
    PATH.invalidate_caches()
    if not ok then error(err, 0) end
  end

  H.check("search_in_plugin_dirs: finds a module in an installed-but-unloaded plugin", function()
    local plugin = H.tmpdir()
    H.write(plugin .. "/lua/fakeplug/init.lua", { "return {}" })
    H.write(plugin .. "/lua/fakeplug/sub.lua", { "return {}" })

    H.with_modules({
      ["lazy.core.config"] = { plugins = { fakeplug = { dir = plugin } } },
    }, function()
      with_fresh_plugin_index(function()
        local init_hit = PATH.search_in_plugin_dirs("fakeplug")
        local sub_hit = PATH.search_in_plugin_dirs("fakeplug.sub")
        local miss = PATH.search_in_plugin_dirs("fakeplug.nothere")

        H.truthy(init_hit, "bare root resolves to its init.lua")
        H.match(init_hit:gsub("\\", "/"), "fakeplug/init%.lua$")
        H.match(sub_hit:gsub("\\", "/"), "fakeplug/sub%.lua$")
        H.is_nil(miss, "a submodule the plugin does not have")
      end)
    end)
    PATH.invalidate_caches()
  end)

  H.check("BUG: invalidate_caches() does not clear the plugin-directory list", function()
    -- `invalidate_caches()` clears `_rtpidx` and `_pidx_*`, but not
    -- `_pdir_str`/`_pdir_list`, which sit in the same block of module locals.
    -- Since `get_plugin_lua_index` builds on `get_plugin_dirs`, a plugin set
    -- that changed without the runtimepath moving stays invisible until the
    -- runtimepath does move.
    local plugin = H.tmpdir()
    H.write(plugin .. "/lua/laterplug/init.lua", { "return {}" })

    -- Prime the (empty) plugin-dir list for the current runtimepath.
    PATH.invalidate_caches()
    H.is_nil(PATH.search_in_plugin_dirs("laterplug"), "nothing knows about it yet")

    H.with_modules({
      ["lazy.core.config"] = { plugins = { laterplug = { dir = plugin } } },
    }, function()
      PATH.invalidate_caches()
      H.is_nil(
        PATH.search_in_plugin_dirs("laterplug"),
        "BUG: the manager now reports it, but the cached dir list is not rebuilt"
      )
      with_fresh_plugin_index(function()
        H.truthy(
          PATH.search_in_plugin_dirs("laterplug"),
          "only moving the runtimepath brings it into view"
        )
      end)
    end)
    PATH.invalidate_caches()
  end)

  H.check(
    "search_in_plugin_dirs: an unknown module root costs one hash lookup, not a walk",
    function()
      H.with_modules({ ["lazy.core.config"] = { plugins = {} } }, function()
        PATH.invalidate_caches()
        H.is_nil(PATH.search_in_plugin_dirs("no_such_root_" .. os.time()))
        H.is_nil(PATH.search_in_plugin_dirs(""), "empty module name")
        ---@diagnostic disable-next-line: param-type-mismatch
        H.is_nil(PATH.search_in_plugin_dirs(nil), "nil module name")
      end)
      PATH.invalidate_caches()
    end
  )

  H.check("search_in_plugin_dirs: a restructured/absent plugin manager is not an error", function()
    H.with_modules({ ["lazy.core.config"] = { plugins = "not a table" } }, function()
      PATH.invalidate_caches()
      H.is_nil(PATH.search_in_plugin_dirs("anything"), "degrades to an empty index")
    end)
    H.with_modules({ ["lazy.core.config"] = false }, function()
      PATH.invalidate_caches()
      H.is_nil(PATH.search_in_plugin_dirs("anything"), "no lazy.nvim at all")
    end)
    PATH.invalidate_caches()
  end)

  H.check("search_in_plugin_dirs: vim.pack is asked for its paths only, no git", function()
    -- `vim.pack.get()` with its default `info = true` first runs `git version` synchronously and then reads git
    -- information of every plugin (a 215 ms freeze on the first resolution, testing perf 2026-11-19). gopath
    -- reads `path` only.
    local plugin = H.tmpdir()
    H.write(plugin .. "/lua/packplug/init.lua", { "return {}" })
    local saved = rawget(vim, "pack")
    local asked
    rawset(vim, "pack", {
      get = function(names, opts)
        asked = { names = names, opts = opts }
        return { { spec = { name = "packplug" }, path = plugin } }
      end,
    })
    local ok, err = pcall(function()
      H.with_modules({ ["lazy.core.config"] = false }, function()
        with_fresh_plugin_index(function()
          H.truthy(PATH.search_in_plugin_dirs("packplug"), "the vim.pack path is indexed")
        end)
      end)
    end)
    rawset(vim, "pack", saved)
    PATH.invalidate_caches()
    if not ok then error(err, 0) end
    H.truthy(asked, "vim.pack.get was asked")
    H.is_nil(asked.names, "all plugins")
    H.eq(asked.opts and asked.opts.info, false, "info = false: no git version, no git per plugin")
  end)

  -- ── search_module (the composed chain) ─────────────────────────────────────

  H.check("search_module: runtimepath wins over the plugin-dir fallback", function()
    local rtp = H.tmpdir()
    local plugin = H.tmpdir()
    H.write(rtp .. "/lua/dualmod/init.lua", { "-- rtp copy" })
    H.write(plugin .. "/lua/dualmod/init.lua", { "-- plugin copy" })

    vim.opt.runtimepath:append(rtp)
    H.with_modules({
      ["lazy.core.config"] = { plugins = { dual = { dir = plugin } } },
    }, function()
      PATH.invalidate_caches()
      local hit = PATH.search_module("dualmod")
      H.truthy(hit, "expected a hit")
      H.match(
        hit:gsub("\\", "/"),
        vim.pesc(rtp) .. "/lua/dualmod/init%.lua$",
        "a loaded module beats a merely installed one"
      )
    end)
    vim.opt.runtimepath:remove(rtp)
    PATH.invalidate_caches()
  end)

  H.check("search_module: dotted names map onto both <rel>.lua and <rel>/init.lua", function()
    local rtp = H.tmpdir()
    H.write(rtp .. "/lua/dotted/leaf.lua", { "" })
    H.write(rtp .. "/lua/dotted/branch/init.lua", { "" })

    vim.opt.runtimepath:append(rtp)
    PATH.invalidate_caches()
    local leaf = PATH.search_module("dotted.leaf")
    local branch = PATH.search_module("dotted.branch")
    vim.opt.runtimepath:remove(rtp)
    PATH.invalidate_caches()

    H.match(leaf:gsub("\\", "/"), "dotted/leaf%.lua$")
    H.match(branch:gsub("\\", "/"), "dotted/branch/init%.lua$")
  end)

  H.check("search_module: rejects non-strings and empties", function()
    H.is_nil(PATH.search_module(""), "empty")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.is_nil(PATH.search_module(nil), "nil")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.is_nil(PATH.search_module({}), "a table")
  end)

  H.check("rtp index TTL: 0 means rebuild on every lookup", function()
    local config = require("gopath.config")
    local dir = H.tmpdir()
    H.mkdir(dir)
    vim.opt.runtimepath:append(dir)

    config.setup({ truncated = { rtp_index_ttl_ms = 0 } })
    PATH.invalidate_caches()
    H.is_nil(PATH.search_in_rtp({ "ttl.lua" }), "not there yet")
    H.write(dir .. "/ttl.lua", { "" })
    local hit = PATH.search_in_rtp({ "ttl.lua" })

    config.setup({ truncated = { rtp_index_ttl_ms = 30000 } })
    vim.opt.runtimepath:remove(dir)
    PATH.invalidate_caches()

    H.truthy(hit, "a zero TTL re-reads the directory without an explicit invalidation")
  end)
end
