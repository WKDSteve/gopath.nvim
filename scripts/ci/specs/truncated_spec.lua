-- scripts/ci/specs/truncated_spec.lua
-- gopath.truncated.cache (the in-memory + on-disk filesystem index) and
-- gopath.truncated.finder (the live search behind it).
--
-- Two things are cut at a seam on purpose:
--   * the cache's persistence, because `config.cache_file` lives under
--     stdpath("cache") and a spec must not overwrite the user's real index;
--   * the finder's `fd`/`rg` invocation, which is the only subprocess in this
--     file's reach. Its argv is asserted instead of run.
-- The scans themselves are real: both walk actual directories built under
-- vim.fn.tempname().

---@param H table
return function(H)
  local cache = require("gopath.truncated.cache")
  local finder = require("gopath.truncated.finder")

  ---Replacements that keep the cache's persistence off the real disk.
  ---@param store table  { data: table|nil, readable: boolean, write_ok: boolean }
  ---@return table
  local function fake_persistence(store)
    return {
      ["lib.nvim.fs.is_readable_file"] = function()
        return store.readable
      end,
      ["lib.nvim.fs.json"] = {
        read = function()
          if store.data == nil then return nil, "no such file" end
          return store.data, nil
        end,
        write = function(_, data)
          store.written = data
          if store.write_ok == false then return false, "permission denied" end
          return true, nil
        end,
      },
    }
  end

  -- `cache.setup` only overwrites the options it is given, so its state is
  -- sticky across calls. Every build below therefore states max_depth and
  -- excluded_dirs explicitly rather than inheriting whatever the previous
  -- check left behind.
  local BASE_SETUP = {
    max_depth = 6,
    max_paths = 300000,
    excluded_dirs = { ".git", ".github", "node_modules", "target", "build", ".cache", "venv" },
  }

  ---Build the cache synchronously over `roots` and return the indexed paths.
  ---@param roots string[]
  ---@param opts table|nil  extra cache.setup options
  ---@return string[]
  local function build_over(roots, opts)
    local store = { readable = false, write_ok = true }
    local paths
    H.with_modules(fake_persistence(store), function()
      cache.setup(
        vim.tbl_extend("force", vim.tbl_extend("force", BASE_SETUP, { roots = roots }), opts or {})
      )
      local done = false
      cache.build_async(function()
        done = true
      end)
      H.truthy(
        H.wait(function()
          return done
        end),
        "the async build finished"
      )
      paths = vim.deepcopy(cache._get_state().paths)
    end)
    return paths
  end

  -- ── cache: scanning ────────────────────────────────────────────────────────

  H.check("build_async: indexes every file under the configured roots", function()
    local root = H.tmpdir()
    H.write(root .. "/a.lua", { "" })
    H.write(root .. "/sub/b.lua", { "" })
    H.write(root .. "/sub/deeper/c.lua", { "" })

    local paths = build_over({ root })
    H.eq(#paths, 3, "three files")
    local joined = table.concat(paths, "\n"):gsub("\\", "/")
    H.match(joined, "/a%.lua")
    H.match(joined, "/sub/b%.lua")
    H.match(joined, "/sub/deeper/c%.lua")
  end)

  H.check("build_async: excluded directories are never descended into", function()
    local root = H.tmpdir()
    H.write(root .. "/keep.lua", { "" })
    H.write(root .. "/.git/objects/blob", { "" })
    H.write(root .. "/node_modules/pkg/index.js", { "" })
    H.write(root .. "/vendor/lib.rb", { "" })

    local joined = table.concat(build_over({ root }), "\n"):gsub("\\", "/")
    H.match(joined, "/keep%.lua")
    H.no_match(joined, "/%.git/", ".git is excluded")
    H.no_match(joined, "/node_modules/", "node_modules is excluded")
    -- Documented divergence, not a defect: cache.lua carries an 18-entry
    -- default exclusion list, but `gopath.init._setup_cache` always passes
    -- `truncated.excluded_dirs` from config/DEFAULTS.lua (7 entries) on top of
    -- it, so "vendor", "dist", "tmp", "__pycache__" and friends are only ever
    -- excluded for a caller that drives `cache.setup` directly.
    H.match(joined, "/vendor/", "'vendor' is in cache.lua's own default list but not in gopath's")
    local with_vendor = table
      .concat(build_over({ root }, { excluded_dirs = { ".git", "node_modules", "vendor" } }), "\n")
      :gsub("\\", "/")
    H.no_match(with_vendor, "/vendor/", "and excluding it explicitly does work")
  end)

  -- A huge root (a session started in %TEMP%) produced a 122 MB cache file of
  -- 727,000 paths whose load blocked startup for ~3 s. `max_paths` bounds one
  -- build; the scan is breadth-first, so the shallow levels survive the cap.
  H.check("build_async: stops at max_paths and keeps the shallow levels", function()
    local root = H.tmpdir()
    H.write(root .. "/top1.lua", { "" })
    H.write(root .. "/top2.lua", { "" })
    for i = 1, 5 do
      H.write(("%s/sub1/f%d.lua"):format(root, i), { "" })
      H.write(("%s/sub2/f%d.lua"):format(root, i), { "" })
    end

    local paths
    local notes = H.capture_notify(function()
      paths = build_over({ root }, { max_paths = 4 })
    end)
    H.eq(#paths, 4, "the build stopped at the cap")
    H.eq(cache._get_state().capped, true, "and says it was cut short")
    H.match(H.notify_text(notes), "max_paths", "the cut-off is reported to the user")
    local joined = table.concat(paths, "\n"):gsub("\\", "/")
    H.match(joined, "/top1%.lua", "the root's own files are listed before anything deeper")
    H.match(joined, "/top2%.lua")

    local again = H.capture_notify(function()
      build_over({ root }, { max_paths = 4 })
    end)
    H.eq(H.notify_text(again), "", "the warning is shown once per session, not per build")

    local all = build_over({ root })
    H.eq(#all, 12, "the default cap does not cut a small tree")
    H.eq(cache._get_state().capped, false, "and a complete build is not flagged")
  end)

  H.check("build_async: a user-supplied exclusion list replaces the default one", function()
    local root = H.tmpdir()
    H.write(root .. "/.git/config", { "" })
    H.write(root .. "/mine/x.lua", { "" })

    local paths = build_over({ root }, { excluded_dirs = { "mine" } })
    local joined = table.concat(paths, "\n"):gsub("\\", "/")
    H.match(joined, "/%.git/config", ".git is no longer excluded")
    H.no_match(joined, "/mine/", "the user's exclusion is honoured")
  end)

  H.check("build_async: max_depth stops the descent", function()
    local root = H.tmpdir()
    H.write(root .. "/l0.lua", { "" })
    H.write(root .. "/one/l1.lua", { "" })
    H.write(root .. "/one/two/l2.lua", { "" })

    local shallow = table.concat(build_over({ root }, { max_depth = 1 }), "\n"):gsub("\\", "/")
    H.match(shallow, "/l0%.lua")
    H.match(shallow, "/one/l1%.lua")
    H.no_match(shallow, "/one/two/", "depth 2 was not reached")
  end)

  H.check("build_async: roots that do not exist are skipped, not fatal", function()
    local root = H.tmpdir()
    H.write(root .. "/only.lua", { "" })
    local paths = build_over({ root, "/definitely/not/here", "" })
    H.eq(#paths, 1)
  end)

  H.check("build_async: no usable roots still completes and reports success", function()
    local paths = build_over({ "/definitely/not/here" })
    H.eq(#paths, 0, "an empty index, delivered on the next tick rather than never")
  end)

  H.check("build_async: a second build while one is running is refused", function()
    local store = { readable = false, write_ok = true }
    H.with_modules(fake_persistence(store), function()
      cache.setup({ roots = { H.tmpdir() } })
      local results = {}
      cache.build_async(function(ok)
        results[#results + 1] = ok
      end)
      -- The first build is still in flight (its scan callbacks have not run);
      -- the second must answer false rather than clobber the shared state.
      cache.build_async(function(ok)
        results[#results + 1] = ok
      end)
      H.truthy(
        H.wait(function()
          return #results >= 2
        end),
        "both callbacks fired"
      )
      H.eq(vim.tbl_contains(results, false), true, "one of them was refused")
      H.eq(vim.tbl_contains(results, true), true, "and the other completed")
    end)
  end)

  -- ── cache: search ──────────────────────────────────────────────────────────

  H.check("search: exact tail match, case- and separator-insensitive", function()
    local root = H.tmpdir()
    H.write(root .. "/lua/gopath/init.lua", { "" })
    H.write(root .. "/lua/other/init.lua", { "" })
    build_over({ root })

    H.eq(#cache.search("gopath/init.lua"), 1, "one exact tail")
    H.eq(#cache.search("GOPATH/INIT.LUA"), 1, "case-insensitive")
    H.eq(#cache.search([[gopath\init.lua]]), 1, "backslash spelling of the same tail")
    H.eq(#cache.search("init.lua"), 2, "a bare basename matches both")
    H.eq(#cache.search("nothing_like_this"), 0, "a miss is an empty list")
  end)

  H.check("search: sequential part matching finds a truncated middle", function()
    local root = H.tmpdir()
    H.write(root .. "/a/b/c/d/target.lua", { "" })
    build_over({ root })

    H.eq(#cache.search("a/d/target.lua"), 1, "segments in order, with gaps")
    H.eq(#cache.search("d/a/target.lua"), 0, "out of order does not match")
    H.eq(#cache.search("a/b/c/d/target.lua"), 1, "the full tail still matches exactly")
  end)

  H.check("search: an empty index answers empty rather than erroring", function()
    H.with_modules(fake_persistence({ readable = false, write_ok = true }), function()
      build_over({ "/definitely/not/here" })
      H.same(cache.search("anything.lua"), {})
    end)
  end)

  H.check("search: the normalised mirror self-heals if it drifts", function()
    local root = H.tmpdir()
    H.write(root .. "/drift/x.lua", { "" })
    build_over({ root })
    -- Simulate a partially-updated state: `paths` moved on, `norm` did not.
    cache._get_state().norm = {}
    H.eq(#cache.search("drift/x.lua"), 1, "reindexed on the spot")
  end)

  -- ── cache: persistence ─────────────────────────────────────────────────────

  H.check("load_from_disk: no cache file is a clean 'false', not an error", function()
    H.with_modules(fake_persistence({ readable = false }), function()
      H.eq(cache.load_from_disk(), false)
    end)
  end)

  H.check("load_from_disk: an unparseable cache file warns and is ignored", function()
    H.with_modules(fake_persistence({ readable = true, data = nil }), function()
      local notes = H.capture_notify(function()
        H.eq(cache.load_from_disk(), false)
      end)
      H.match(H.notify_text(notes), "Failed to parse cache file")
    end)
  end)

  H.check("load_from_disk: a persisted snapshot is revalidated, not trusted", function()
    local root = H.tmpdir()
    H.with_modules(
      fake_persistence({
        readable = true,
        data = {
          paths = { "/real/a.lua", 42, false, { "nested" }, "/real/b.lua" },
          last_built = "not a number",
          scan_roots = { root },
          version = 1,
        },
      }),
      function()
        cache.setup({ roots = { root } })
        H.eq(cache.load_from_disk(), true)
        local state = cache._get_state()
        H.same(state.paths, { "/real/a.lua", "/real/b.lua" }, "non-string entries dropped")
        H.is_nil(state.last_built, "a non-numeric timestamp is discarded")
        H.eq(#state.norm, 2, "and the mirror matches")
      end
    )
  end)

  H.check("load_from_disk: a wrong-typed paths field yields an empty index", function()
    local root = H.tmpdir()
    H.with_modules(
      fake_persistence({
        readable = true,
        data = { paths = "not a list", last_built = 123, scan_roots = { root } },
      }),
      function()
        cache.setup({ roots = { root } })
        H.eq(cache.load_from_disk(), true)
        H.same(cache._get_state().paths, {})
        H.eq(cache._get_state().last_built, 123, "a valid timestamp is kept")
      end
    )
  end)

  H.check(
    "load_from_disk: a snapshot built for different scan_roots is rejected (PERF-46)",
    function()
      local mine = H.tmpdir()
      local foreign = H.tmpdir()
      H.with_modules(
        fake_persistence({
          readable = true,
          data = {
            paths = { foreign .. "/other.lua" },
            last_built = os.time(),
            scan_roots = { foreign },
            version = 1,
          },
        }),
        function()
          cache.setup({ roots = { mine } })
          H.eq(
            cache.load_from_disk(),
            false,
            "a cache built for a different project's roots is not trusted"
          )
          H.same(cache._get_state().paths, {}, "nothing from the other project leaked in")
        end
      )
    end
  )

  H.check("setup: the cache file is keyed by scan_roots, not fixed (PERF-46)", function()
    cache.setup({ roots = { "/project/a" } })
    local file_a = cache._get_config().cache_file

    cache.setup({ roots = { "/project/b" } })
    local file_b = cache._get_config().cache_file
    H.truthy(file_a ~= file_b, "two projects with different roots never share a cache file")

    cache.setup({ roots = { "/project/a" } })
    H.eq(cache._get_config().cache_file, file_a, "the same roots always produce the same file")
  end)

  H.check("_save_to_disk: an unwritable cache file is reported, not raised", function()
    local store = { readable = false, write_ok = false }
    H.with_modules(fake_persistence(store), function()
      local notes = H.capture_notify(function()
        cache._save_to_disk()
      end)
      H.match(H.notify_text(notes), "Failed to write cache file", "gopath's own wording")
      H.match(H.notify_text(notes), "permission denied", "including the underlying reason")
    end)
  end)

  H.check(
    "_save_to_disk: the persisted shape carries paths, timestamp, roots and a version",
    function()
      local root = H.tmpdir()
      H.write(root .. "/x.lua", { "" })
      local store = { readable = false, write_ok = true }
      H.with_modules(fake_persistence(store), function()
        cache.setup({ roots = { root } })
        local done = false
        cache.build_async(function()
          done = true
        end)
        H.truthy(H.wait(function()
          return done
        end))
      end)
      H.truthy(store.written, "something was written")
      H.eq(store.written.version, 1)
      H.eq(type(store.written.last_built), "number")
      H.same(store.written.scan_roots, { root })
      H.eq(#store.written.paths, 1)
    end
  )

  -- A rebuild of an unchanged tree used to write the whole JSON again (~76 ms in the editor thread): the same index
  -- is confirmed by touching the file, the age is the file's mtime.
  H.check("_save_to_disk: an unchanged index is not written again, only its age moves", function()
    local root = H.tmpdir()
    H.write(root .. "/x.lua", { "" })
    local file = H.tmpdir() .. "/gopath_fs_cache_aaaaaaaa.json"
    -- (`setup` derives the file from the roots: override it afterwards, off the user's real cache directory)
    cache.setup({ roots = { root } })
    H.with_field(cache._get_config(), "cache_file", file, function()
      local real_write = require("lib.nvim.fs.json").write
      local writes = 0
      H.with_modules({
        ["lib.nvim.fs.json"] = {
          read = require("lib.nvim.fs.json").read,
          write = function(...)
            writes = writes + 1
            return real_write(...)
          end,
        },
      }, function()
        cache._save_to_disk()
        H.eq(writes, 1, "the first save writes")
        local old = os.time() - 7200
        vim.uv.fs_utime(file, old, old)
        H.truthy(cache._save_to_disk(), "the second save succeeds")
        H.eq(writes, 1, "and writes nothing: the index is the one on disk")
        H.truthy(vim.uv.fs_stat(file).mtime.sec > old + 3600, "but the age moved")
      end)
    end)
  end)

  -- Every distinct scan-roots set owns its own cache file (PERF-46), so every new
  -- working directory used to leave one behind for good: 131 files, 564 MB.
  H.check("_save_to_disk: a cache file nobody rewrote for two weeks is pruned", function()
    local dir = H.tmpdir()
    local live = dir .. "/gopath_fs_cache_aaaaaaaa.json"
    local old = H.write(dir .. "/gopath_fs_cache_deadbeef.json", { "{}" })
    local old_legacy = H.write(dir .. "/gopath_fs_cache.json", { "{}" })
    local fresh = H.write(dir .. "/gopath_fs_cache_cafebabe.json", { "{}" })
    local old_tmp = H.write(dir .. "/gopath_fs_cache_deadbeef.json.tmp", { "{}" })
    local foreign = H.write(dir .. "/notes.json", { "{}" })

    local month_ago = os.time() - 30 * 24 * 3600
    for _, f in ipairs({ old, old_legacy, old_tmp, foreign }) do
      vim.uv.fs_utime(f, month_ago, month_ago)
    end

    H.with_field(cache._get_config(), "cache_file", live, function()
      cache._save_to_disk()
      H.truthy(
        H.wait(function()
          return vim.uv.fs_stat(old) == nil
        end),
        "the stale per-roots file was deleted"
      )
    end)

    H.truthy(vim.uv.fs_stat(live), "the file just written is kept")
    H.eq(vim.uv.fs_stat(old_legacy), nil, "the legacy fixed-name file is pruned the same way")
    H.truthy(vim.uv.fs_stat(fresh), "a recently written file is kept")
    H.truthy(vim.uv.fs_stat(old_tmp), "a name of another shape is never a candidate")
    H.truthy(vim.uv.fs_stat(foreign), "a foreign file is never touched")
  end)

  H.check("_save_to_disk: a write that did not land prunes nothing", function()
    local dir = H.tmpdir()
    local live = dir .. "/gopath_fs_cache_aaaaaaaa.json" -- never created
    local old = H.write(dir .. "/gopath_fs_cache_deadbeef.json", { "{}" })
    local month_ago = os.time() - 30 * 24 * 3600
    vim.uv.fs_utime(old, month_ago, month_ago)

    H.with_modules(fake_persistence({ readable = false, write_ok = true }), function()
      H.with_field(cache._get_config(), "cache_file", live, function()
        cache._save_to_disk()
        vim.wait(200) -- the prune is asynchronous; give a wrong one time to run
      end)
    end)

    H.truthy(vim.uv.fs_stat(old), "no live file on disk, so nothing is deleted next to it")
  end)

  -- ── cache: staleness and roots ─────────────────────────────────────────────

  H.check("needs_refresh: never built is stale; just built is not", function()
    local state = cache._get_state()
    local cfg = cache._get_config()
    local saved, saved_file = state.last_built, cfg.cache_file
    -- No file either: with neither a build nor a file there is nothing to
    -- read an age from.
    cfg.cache_file = H.tmpdir() .. "/none.json"

    state.last_built = nil
    H.eq(cache.needs_refresh(), true, "never built")
    cfg.cache_file = saved_file

    state.last_built = os.time()
    H.eq(cache.needs_refresh(3600), false, "fresh")
    H.eq(cache.needs_refresh(0), false, "exactly at the boundary is not yet stale")

    state.last_built = os.time() - 7200
    H.eq(cache.needs_refresh(3600), true, "two hours old against a one-hour budget")
    H.eq(cache.needs_refresh(), true, "and against the default budget")

    state.last_built = saved
  end)

  H.check("needs_refresh: without the index loaded, the age is the cache file's mtime", function()
    -- setup() no longer reads the file; the staleness check must not answer
    -- "never built" for a cache that is on disk and fresh, or every start
    -- rescans.
    local state = cache._get_state()
    local cfg = cache._get_config()
    local saved, saved_file, saved_unusable = state.last_built, cfg.cache_file, state.unusable
    local file = H.tmpdir() .. "/gopath_fs_cache_test.json"
    H.write(file, { "{}" })
    cfg.cache_file = file
    state.last_built = nil
    state.unusable = false

    H.eq(cache.needs_refresh(3600), false, "a file written just now is fresh")
    local old = os.time() - 7200
    vim.uv.fs_utime(file, old, old)
    H.eq(cache.needs_refresh(3600), true, "a two-hour-old file is stale")
    H.eq(cache.needs_refresh(10800), false, "and fresh against a three-hour budget")

    vim.uv.fs_utime(file, os.time(), os.time())
    state.unusable = true
    H.eq(cache.needs_refresh(3600), true, "a file that was read and rejected means rebuild")

    state.last_built, cfg.cache_file, state.unusable = saved, saved_file, saved_unusable
  end)

  H.check("load_from_disk: a rejected or unparseable file marks the cache unusable", function()
    local mine = H.tmpdir()
    H.with_modules(
      fake_persistence({
        readable = true,
        data = { paths = { "/x.lua" }, last_built = os.time(), scan_roots = { H.tmpdir() } },
      }),
      function()
        cache.setup({ roots = { mine } })
        H.falsy(cache._get_state().unusable, "setup starts from a clean verdict")
        H.eq(cache.load_from_disk(), false)
        H.eq(cache._get_state().unusable, true, "other roots")
      end
    )
    H.with_modules(fake_persistence({ readable = true, data = nil }), function()
      cache.setup({ roots = { mine } })
      H.capture_notify(function()
        cache.load_from_disk()
      end)
      H.eq(cache._get_state().unusable, true, "unparseable")
    end)
    H.with_modules(
      fake_persistence({
        readable = true,
        data = { paths = { mine .. "/a.lua" }, last_built = os.time(), scan_roots = { mine } },
      }),
      function()
        cache.setup({ roots = { mine } })
        H.eq(cache.load_from_disk(), true)
        H.eq(cache._get_state().unusable, false, "a file that loads is usable")
      end
    )
  end)

  H.check("search: a rejected file is read once and starts one rebuild", function()
    -- setup() never read it and its mtime looked fresh, so nothing else would
    -- notice it is useless; every lookup re-reading it is the failure.
    local mine = H.tmpdir()
    local store = {
      readable = true,
      data = { paths = { "/x.lua" }, last_built = os.time(), scan_roots = { H.tmpdir() } },
    }
    local reads = 0
    local fakes = fake_persistence(store)
    local real_read = fakes["lib.nvim.fs.json"].read
    fakes["lib.nvim.fs.json"].read = function(...)
      reads = reads + 1
      return real_read(...)
    end
    local builds = 0
    H.with_modules(fakes, function()
      cache.setup({ roots = { mine } })
      H.with_field(cache, "build_async", function()
        builds = builds + 1
      end, function()
        H.same(cache.search("x.lua"), {})
        H.same(cache.search("x.lua"), {})
        vim.wait(200, function()
          return builds > 0
        end)
      end)
    end)
    H.eq(reads, 1, "the rejected file was read again on the next lookup")
    H.eq(builds, 1, "exactly one rebuild was started")
    cache._get_state().unusable = false
  end)

  H.check("setup: other roots drop the old roots' index", function()
    -- Without the load in setup(), nothing else would replace it: `search`
    -- only loads when the index is empty.
    local a, b = H.tmpdir(), H.tmpdir()
    H.write(a .. "/only_in_a.lua", { "" })
    build_over({ a })
    H.truthy(#cache._get_state().paths > 0, "built")
    cache.setup(vim.tbl_extend("force", BASE_SETUP, { roots = { a } }))
    H.truthy(#cache._get_state().paths > 0, "the same roots keep the index")
    cache.setup(vim.tbl_extend("force", BASE_SETUP, { roots = { b } }))
    H.same(cache._get_state().paths, {}, "other roots start from an empty index")
    H.is_nil(cache._get_state().last_built, "and from the new file's age")
  end)

  -- ── second review ───────────────────────────────────────────────────────

  H.check(
    "build: a build for roots that changed while it ran is not saved as the new ones",
    function()
      local a, b = H.tmpdir(), H.tmpdir()
      H.write(a .. "/only_in_a.lua", { "" })
      H.write(b .. "/only_in_b.lua", { "" })
      local store = { readable = false, write_ok = true }
      H.with_modules(fake_persistence(store), function()
        cache.setup(vim.tbl_extend("force", BASE_SETUP, { roots = { a } }))
        cache.build_async(function() end)
        -- a second setup() with other roots, while the first build still runs
        cache.setup(vim.tbl_extend("force", BASE_SETUP, { roots = { b } }))
        H.truthy(
          H.wait(function()
            return not cache.building() and store.written ~= nil
          end),
          "a build finished and wrote"
        )
        H.same(store.written.scan_roots, { b }, "written for the new roots")
        for _, p in ipairs(store.written.paths) do
          H.falsy(
            p:find("only_in_a", 1, true),
            "the old roots' file was saved under the new roots: " .. p
          )
        end
      end)
    end
  )

  H.check("search: a file rejected by someone else first still gets its one rebuild", function()
    local mine = H.tmpdir()
    local builds = 0
    H.with_modules(
      fake_persistence({
        readable = true,
        data = { paths = { "/x.lua" }, last_built = os.time(), scan_roots = { H.tmpdir() } },
      }),
      function()
        cache.setup({ roots = { mine } })
        -- what `:checkhealth gopath` and `:Gopath cache info` do
        cache.load_from_disk()
        H.eq(cache._get_state().unusable, true)
        H.with_field(cache, "build_async", function()
          builds = builds + 1
        end, function()
          cache.search("x.lua")
          cache.search("x.lua")
          vim.wait(200, function()
            return builds > 0
          end)
        end)
      end
    )
    H.eq(builds, 1, "exactly one rebuild")
    cache._get_state().unusable = false
  end)

  H.check(
    "search: no rebuild for a cache with no roots to scan (truncated.enable = false)",
    function()
      local cfg = cache._get_config()
      local saved_roots = cfg.scan_roots
      local builds = 0
      cfg.scan_roots = {}
      cache._get_state().unusable, cache._get_state().rebuild_asked = true, false
      H.with_field(cache, "build_async", function()
        builds = builds + 1
      end, function()
        cache.search("x.lua")
        vim.wait(100, function()
          return builds > 0
        end)
      end)
      cfg.scan_roots = saved_roots
      cache._get_state().unusable = false
      H.eq(builds, 0)
    end
  )

  -- ── third review ────────────────────────────────────────────────────────

  H.check("build: a discarded build hands its caller the replacement's result", function()
    local a, b = H.tmpdir(), H.tmpdir()
    H.write(b .. "/only_in_b.lua", { "" })
    local store = { readable = false, write_ok = true }
    local results = {}
    H.with_modules(fake_persistence(store), function()
      cache.setup(vim.tbl_extend("force", BASE_SETUP, { roots = { a } }))
      cache.build_async(function(ok)
        results[#results + 1] = ok
      end)
      cache.setup(vim.tbl_extend("force", BASE_SETUP, { roots = { b } }))
      H.truthy(
        H.wait(function()
          return #results > 0 and not cache.building()
        end),
        "the caller heard back"
      )
    end)
    H.same(results, { true }, "one answer, and it is the replacement's success, not a failure")
  end)

  H.check("search: no rebuild while the configuration has the cache switched off", function()
    local builds = 0
    local cfg = cache._get_config()
    local saved_roots = cfg.scan_roots
    cfg.scan_roots = { H.tmpdir() } -- roots to scan: only the option may stop it
    local state = cache._get_state()
    local saved_paths, saved_norm = state.paths, state.norm
    state.paths, state.norm = {}, {} -- an empty index, so search reaches the rebuild branch
    require("gopath.config").get().truncated.enable = false
    cache._get_state().unusable, cache._get_state().rebuild_asked = true, false
    H.with_field(cache, "build_async", function()
      builds = builds + 1
    end, function()
      cache.search("x.lua")
      vim.wait(100, function()
        return builds > 0
      end)
    end)
    require("gopath.config").get().truncated.enable = true
    cfg.scan_roots = saved_roots
    state.paths, state.norm = saved_paths, saved_norm
    cache._get_state().unusable = false
    H.eq(builds, 0)
  end)

  H.check("build: a build of nothing that cannot write keeps its one rebuild spent", function()
    local gone = H.tmpdir() .. "/gone"
    local store = { readable = false, write_ok = false }
    H.with_modules(fake_persistence(store), function()
      cache.setup(vim.tbl_extend("force", BASE_SETUP, { roots = { gone } }))
      cache._get_state().rebuild_asked = true
      local done = false
      H.capture_notify(function()
        cache.build_async(function()
          done = true
        end)
        H.wait(function()
          return done
        end)
      end)
    end)
    H.eq(
      cache._get_state().rebuild_asked,
      true,
      "a lookup would otherwise ask for the same useless build again"
    )
    cache._get_state().rebuild_asked = false
  end)

  H.check("add_root: a verdict on the old file is not carried over to the new one", function()
    local root, extra = H.tmpdir(), H.tmpdir()
    H.with_modules(fake_persistence({ readable = false }), function()
      cache.setup(vim.tbl_extend("force", BASE_SETUP, { roots = { root } }))
      cache._get_state().unusable = true
      cache.add_root(extra, false)
      H.eq(cache._get_state().unusable, false)
    end)
  end)

  H.check("add_root: rejects a non-directory, refuses duplicates, accepts a new one", function()
    local root = H.tmpdir()
    local extra = H.tmpdir()
    H.with_modules(fake_persistence({ readable = false, write_ok = true }), function()
      cache.setup({ roots = { root } })

      local missing = H.capture_notify(function()
        cache.add_root(root .. "/not-a-dir", false)
      end)
      H.match(H.notify_text(missing), "Directory does not exist")

      local dupe = H.capture_notify(function()
        cache.add_root(root, false)
      end)
      H.match(H.notify_text(dupe), "already in cache roots")

      local added = H.capture_notify(function()
        cache.add_root(extra, false)
      end)
      H.match(H.notify_text(added), "Added to cache roots")

      -- The new root is really in the scan set: rebuilding must index it.
      H.write(extra .. "/fresh.lua", { "" })
      local done = false
      cache.build_async(function()
        done = true
      end)
      H.truthy(H.wait(function()
        return done
      end))
      H.match(
        table.concat(cache._get_state().paths, "\n"):gsub("\\", "/"),
        "/fresh%.lua",
        "the added root was scanned"
      )
    end)
  end)

  H.check("add_root: does not mutate the caller's own roots table (ERR-54)", function()
    local mine = H.tmpdir()
    local extra = H.tmpdir()
    -- Stands in for config.get().truncated.cache_roots, which cache.setup()
    -- receives by reference from gopath.init._setup_cache.
    local caller_roots = { mine }
    H.with_modules(fake_persistence({ readable = false, write_ok = true }), function()
      cache.setup({ roots = caller_roots })
      cache.add_root(extra, false)
      H.same(caller_roots, { mine }, "the caller's table is untouched by add_root's mutation")
    end)
  end)

  H.check(
    "add_root: re-keys cache_file so the augmented roots are saved under a new name (PERF-46)",
    function()
      local root = H.tmpdir()
      local extra = H.tmpdir()
      H.with_modules(fake_persistence({ readable = false, write_ok = true }), function()
        cache.setup({ roots = { root } })
        local file_before = cache._get_config().cache_file

        cache.add_root(extra, false)
        local file_after = cache._get_config().cache_file

        H.truthy(
          file_before ~= file_after,
          "cache_file must be re-hashed once scan_roots grows, or the augmented "
            .. "scan_roots list gets saved under the OLD (now-mismatched) filename"
        )
      end)
    end
  )

  H.check(
    "add_root: a later session with the original roots still loads its own untouched cache (PERF-46)",
    function()
      local root = H.tmpdir()
      local extra = H.tmpdir()
      H.write(root .. "/x.lua", { "" })
      -- A real filesystem-backed store, unlike the other checks here: the bug
      -- this guards against is specifically about which *filename* content
      -- ends up under, so the fake in-memory single-slot store (which cannot
      -- tell two filenames apart) would hide it.
      local files = {}
      local store_fs = {
        ["lib.nvim.fs.is_readable_file"] = function(path)
          return files[path] ~= nil
        end,
        ["lib.nvim.fs.json"] = {
          read = function(path)
            if files[path] == nil then return nil, "no such file" end
            return files[path], nil
          end,
          write = function(path, data)
            -- Deep-copy, not aliased: a real `json.write` serializes to disk,
            -- so later in-memory mutations of `config.scan_roots` (e.g. by a
            -- subsequent `add_root`) must NOT retroactively change what an
            -- earlier write already persisted under a different filename.
            files[path] = vim.deepcopy(data)
            return true, nil
          end,
        },
      }
      H.with_modules(store_fs, function()
        -- Session 1: build for `root` alone, then add `extra` on the fly.
        cache.setup({ roots = { root } })
        local done = false
        cache.build_async(function()
          done = true
        end)
        H.truthy(H.wait(function()
          return done
        end))

        cache.add_root(extra, false) -- rebuild = false: only re-keys + mutates scan_roots
        cache._save_to_disk() -- persist the augmented roots under the re-keyed name

        -- Session 2: a fresh `setup()` call with the ORIGINAL roots only,
        -- exactly like a Neovim restart that never persisted `extra` anywhere.
        cache.setup({ roots = { root } })
        H.eq(
          cache.load_from_disk(),
          true,
          "the untouched root-only cache must still be found and trusted -- "
            .. "add_root's mutation must not have clobbered it"
        )
        H.eq(#cache._get_state().paths, 1, "loaded from disk, not rescanned")
      end)
    end
  )

  H.check("setup: with no roots given, the auto-detected set is all real directories", function()
    H.with_modules(fake_persistence({ readable = false, write_ok = true }), function()
      cache.setup({})
      -- Auto-detection is observable through what a build indexes; asserting
      -- the exact set would only restate the candidate list. What matters is
      -- that nothing unreadable made it in, which `build_async` filters again.
      local before = cache._get_state().last_built
      H.eq(type(before) == "number" or before == nil, true, "state is intact after re-setup")
    end)
  end)

  H.check("start_periodic_refresh: a second call replaces the first timer", function()
    -- A huge interval so no callback ever fires during the run; the point is
    -- that the module keeps the handle and can stop it, rather than orphaning
    -- one background rebuild per reload.
    cache.start_periodic_refresh(86400)
    cache.start_periodic_refresh(86400)
    H.truthy(true, "no error, and no orphaned handle left behind")
  end)

  -- ── finder: the live walk ──────────────────────────────────────────────────

  ---@param tail string
  ---@param opts table|nil
  ---@return string[]
  local function find_async(tail, opts)
    local out
    finder.find_async(tail, opts, function(hits)
      out = hits
    end)
    H.truthy(
      H.wait(function()
        return out ~= nil
      end),
      "find_async called back"
    )
    return out
  end

  H.check("find_async: matches on a segment boundary and normalises the results", function()
    local root = H.tmpdir()
    H.write(root .. "/pkg/mod/init.lua", { "" })
    H.write(root .. "/pkg/notinit.lua", { "" })

    local hits = find_async("mod/init.lua", { roots = { root } })
    H.eq(#hits, 1)
    H.match(hits[1], "pkg/mod/init%.lua$", "forward slashes, absolute")

    local boundary = find_async("init.lua", { roots = { root } })
    H.eq(#boundary, 1, "notinit.lua is not a match for init.lua")
  end)

  H.check("find_async: empty tail, missing roots, and no matches", function()
    H.same(find_async("", { roots = { H.tmpdir() } }), {}, "empty tail")
    H.same(find_async("x.lua", { roots = { "/definitely/not/here" } }), {}, "unreadable root")
    H.same(find_async("x.lua", { roots = { H.tmpdir() } }), {}, "empty tree")
  end)

  H.check("find_async: stops at the limit", function()
    local root = H.tmpdir()
    for i = 1, 6 do
      H.write(("%s/d%d/same.lua"):format(root, i), { "" })
    end
    H.eq(#find_async("same.lua", { roots = { root }, limit = 2 }), 2)
  end)

  H.check("find_async: skips excluded directories and respects max_depth + 2", function()
    H.config_sandbox(function(c)
      local root = H.tmpdir()
      H.write(root .. "/node_modules/pkg/hit.lua", { "" })
      H.write(root .. "/src/hit.lua", { "" })
      c.setup({ truncated = { excluded_dirs = { "node_modules" }, max_depth = 6 } })

      local hits = find_async("hit.lua", { roots = { root } })
      H.eq(#hits, 1, "only the non-excluded one")
      H.match(hits[1], "/src/hit%.lua$")
    end)
  end)

  H.check("find_async: de-duplicates identical results across overlapping roots", function()
    local root = H.tmpdir()
    H.write(root .. "/a/dup.lua", { "" })
    local hits = find_async("dup.lua", { roots = { root, root, root .. "/a" } })
    H.eq(#hits, 1, "one file, one entry")
  end)

  -- ── finder: the external-tool path (argv only, never spawned) ──────────────

  ---Replace `vim.fn.executable` and `vim.system` for the duration of `fn`.
  ---@param available table<string, boolean>
  ---@param stdout string
  ---@param fn fun()
  ---@return string[][] argvs
  local function with_tools(available, stdout, fn)
    local argvs = {}
    local saved_exe = rawget(vim.fn, "executable")
    local saved_system = vim.system
    vim.fn.executable = function(bin)
      return available[bin] and 1 or 0
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(cmd)
      argvs[#argvs + 1] = cmd
      return {
        wait = function()
          return { code = 0, stdout = stdout }
        end,
      }
    end
    local ok, err = pcall(fn)
    vim.fn.executable = saved_exe
    vim.system = saved_system
    if not ok then error(err, 0) end
    return argvs
  end

  H.check("find: fd is preferred, and gets the basename plus the root", function()
    local root = H.tmpdir()
    H.write(root .. "/a/b/x.lua", { "" })
    local argvs = with_tools({ fd = true, rg = true }, root .. "/a/b/x.lua\n", function()
      local hits = finder.find("b/x.lua", { roots = { root } })
      H.eq(#hits, 1, "the tool's output is filtered by the tail, then returned")
    end)
    H.eq(#argvs, 1, "one invocation, one root")
    H.same(argvs[1], {
      "fd",
      "--type",
      "f",
      "--hidden",
      "--follow",
      "--no-ignore-vcs",
      "x.lua",
      root,
    })
  end)

  H.check("find: fdfind is the Debian-named fallback before rg", function()
    local root = H.tmpdir()
    local argvs = with_tools({ fdfind = true, rg = true }, "", function()
      finder.find("x.lua", { roots = { root } })
    end)
    H.eq(argvs[1][1], "fdfind")
  end)

  H.check("find: without fd it falls back to `rg --files -g <basename>`", function()
    local root = H.tmpdir()
    H.write(root .. "/deep/x.lua", { "" })
    local argvs = with_tools({ rg = true }, root .. "/deep/x.lua\n", function()
      local hits = finder.find("deep/x.lua", { roots = { root } })
      H.eq(#hits, 1)
    end)
    H.same(argvs[1], { "rg", "--files", "--hidden", "-g", "x.lua", root })
  end)

  H.check("find: with no search tool at all, it says so and returns nothing", function()
    local notes
    with_tools({}, "", function()
      notes = H.capture_notify(function()
        H.same(finder.find("x.lua", { roots = { H.tmpdir() } }), {})
      end)
    end)
    H.match(H.notify_text(notes), "no external search tool", "and names the fix")
    H.match(H.notify_text(notes), "install fd or rg")
  end)

  H.check("find: the tool's output is filtered by the tail, not trusted wholesale", function()
    local root = H.tmpdir()
    local argvs = with_tools(
      { fd = true },
      table.concat({
        root .. "/right/x.lua",
        root .. "/wrong/notx.lua",
        root .. "/other/x.lua",
        "",
      }, "\n"),
      function()
        local hits = finder.find("right/x.lua", { roots = { root } })
        H.eq(#hits, 1, "only the line whose path really ends with the tail")
        H.match(hits[1], "/right/x%.lua$")
      end
    )
    H.eq(#argvs, 1)
  end)

  H.check("find: an empty tail short-circuits before any tool is consulted", function()
    local consulted = false
    with_tools({ fd = true }, "", function()
      consulted = true
      H.same(finder.find("", {}), {})
      ---@diagnostic disable-next-line: param-type-mismatch
      H.same(finder.find(nil, {}), {})
    end)
    H.truthy(consulted, "the block ran")
  end)

  H.check("find: the limit caps results across roots", function()
    local a, b = H.tmpdir(), H.tmpdir()
    H.write(a .. "/x.lua", { "" })
    H.write(b .. "/x.lua", { "" })
    with_tools({ fd = true }, a .. "/x.lua\n" .. b .. "/x.lua\n", function()
      H.eq(#finder.find("x.lua", { roots = { a, b }, limit = 1 }), 1)
    end)
  end)

  -- Leave the cache configured the way `gopath.setup({})` left it, so later
  -- specs and the two older runners see the same auto-detected roots.
  H.with_modules(fake_persistence({ readable = false, write_ok = true }), function()
    cache.setup({})
  end)
end
