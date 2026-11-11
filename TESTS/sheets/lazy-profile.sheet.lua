-- TESTS/sheets/lazy-profile.sheet.lua -- a measure step of testing.nvim (docs/SHEETS.md) on the installed config.
-- What gopath costs when lazy.nvim loads it under VeryLazy in the installed config (the value `:Lazy profile`
-- shows). `config = "user"` starts the real config read only; where there is none (CI) the sheet is a skip.
-- The value is a note in the task (`testing sheets run --task ... --tasks <vault>`).
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
  },
}
