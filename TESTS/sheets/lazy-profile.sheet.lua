-- TESTS/sheets/lazy-profile.sheet.lua -- a measure step of testing.nvim (docs/SHEETS.md) on the installed config.
-- What gopath costs when lazy.nvim loads it under VeryLazy in the installed config (the value `:Lazy profile`
-- shows). `config = "user"` starts the real config read only; where there is none (CI) the sheet is a skip.
-- The values are notes in the task (`testing sheets run --task ... --tasks <vault>`).
--
-- The sandbox has its own stdpath("cache"), so the first start has no persisted index. The second start has the
-- user's real one (the newest gopath_fs_cache_*.json over 100 kB, copied under the sandbox's own name): since e0a6412
-- setup() does not read it, so both values stay close; a setup() that parses it again costs 40-60 ms more.
return {
  id = "gopath.lazy-profile",
  title = "gopath under VeryLazy in :Lazy profile",
  task = "gopath.nvim/lazy-profile-cache-measure",
  config = "user",
  steps = {
    {
      wait = "(function() local p = require('lazy.core.config').plugins['gopath.nvim'] "
        .. "return p ~= nil and p._.loaded ~= nil end)()",
      timeout = 30000,
      note = "VeryLazy has loaded gopath",
    },
    {
      measure = "require('lazy.core.config').plugins['gopath.nvim']._.loaded.time / 1e6",
      name = "gopath (VeryLazy)",
      unit = "ms",
      -- measured 76 ms on 2026-11-11 (STEVESPC): a guard against a regression, with room for a loaded machine
      max = 120,
      note = "lazy keeps the load time in ns; one reading per start (runs would read the same value)",
    },
    {
      lua = [[local real = vim.fn.has("win32") == 1 and (vim.env.LOCALAPPDATA or "") .. "/Temp/nvim"
        or (vim.env.HOME or "") .. "/.cache/nvim"
      local best, best_mtime
      for name, kind in vim.fs.dir(real) do
        if kind == "file" and name:match("^gopath_fs_cache_%x+%.json$") then
          local st = vim.uv.fs_stat(real .. "/" .. name)
          if st and st.size > 100000 and (not best_mtime or st.mtime.sec > best_mtime) then
            best, best_mtime = real .. "/" .. name, st.mtime.sec
          end
        end
      end
      local dst = require("gopath.truncated.cache")._get_config().cache_file
      local sandbox = vim.fs.normalize(vim.fn.stdpath("cache"))
      _G.SEEDED = nil
      if best and vim.startswith(vim.fs.normalize(dst), sandbox) then
        assert(vim.uv.fs_copyfile(best, dst))
        _G.SEEDED = vim.uv.fs_stat(dst).size
      end]],
      note = "the user's newest persisted index, copied into the sandbox under the name this start looks for",
    },
    {
      expect = "_G.SEEDED ~= nil",
      note = "an index was found and copied (only ever into the sandbox's own cache folder)",
    },
    { restart = true, note = "a second start, now with a persisted index" },
    {
      wait = "(function() local p = require('lazy.core.config').plugins['gopath.nvim'] "
        .. "return p ~= nil and p._.loaded ~= nil end)()",
      timeout = 30000,
      note = "VeryLazy has loaded gopath again",
    },
    {
      measure = "require('lazy.core.config').plugins['gopath.nvim']._.loaded.time / 1e6",
      name = "gopath (VeryLazy) index on disk",
      unit = "ms",
      max = 120,
      note = "setup() leaves the index on disk (e0a6412): about the value of the first start",
    },
    {
      measure = "vim.uv.fs_stat(require('gopath.truncated.cache')._get_config().cache_file).size / 1e6",
      name = "persisted index",
      unit = "MB",
      note = "the size of the index that was on disk",
    },
  },
}
