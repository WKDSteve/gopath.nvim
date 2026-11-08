-- Bindings checklist: :Gopath cache build/info/add-root and their aliases.
return {
  id = "gopath.cache",
  title = "gopath.nvim: the cache commands build, report and grow the index a truncated path resolves through",
  task = "gopath.nvim/testblatt-bindings-checkliste",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.write("one/deep/first.lua")
      _G.write("two/deep/second.lua")
      _G.write("three/deep/third.lua")
      _G.setup({ truncated = { cache_roots = { _G.DIR .. "/one" } }, tailsearch = { enable = false } })
      _G.cache = require("gopath.truncated.cache")
      _G.finds = function(tail)
        return #(_G.cache.search(tail) or {}) > 0
      end
      _G.START = vim.uv.now()]],
    },
    {
      wait = [[vim.uv.now() - _G.START > 2200 and not _G.cache.building()]],
      timeout = 8000,
      note = "setup() starts a build of its own after 2 s: a build asked for meanwhile would be refused",
    },

    { keys = ":Gopath cache build<CR>", note = "a build, and it reports its end" },
    { wait = [[_G.noted("Cache build complete")]], timeout = 8000 },
    { expect = [[_G.finds("deep/first.lua") and not _G.finds("deep/second.lua")]] },

    { keys = ":Gopath cache info<CR>", note = "the stats: one file" },
    { expect = [[_G.noted("Files indexed : 1")]] },
    { keys = ":GopathCacheInfo<CR>" },
    { expect = [[_G.noted("Files indexed : 1")]] },

    { keys = ":GopathCacheBuild<CR>", note = "the alias builds too" },
    { wait = [[_G.noted("Cache built")]], timeout = 8000 },

    {
      lua = [[_G.on("...cut/off/deep/first.lua:4")]],
      note = "what the index is for: a truncated path, with its line",
    },
    { keys = "gF" },
    { wait = [[_G.at("one/deep/first.lua", 4)]], timeout = 8000 },

    {
      expect = [[vim.fs.normalize(vim.fn.getcompletion("Gopath cache add-root o", "cmdline")[1] or "") == "one"]],
      note = "<Tab> offers the directory",
    },
    {
      expect = [[#vim.fn.getcompletion("Gopath cache add-root one/deep/fi", "cmdline") == 0]],
      note = "<Tab> offers no file",
    },
    {
      expect = [[vim.fs.normalize(vim.fn.getcompletion("GopathCacheAddRoot o", "cmdline")[1] or "") == "one"]],
      note = "the alias offers the directory too",
    },
    {
      expect = [[#vim.fn.getcompletion("GopathCacheAddRoot one/deep/fi", "cmdline") == 0]],
      note = "and no file (Neovim's own -complete=dir lists files on Windows)",
    },
    {
      keys = ":Gopath cache add-root one/deep/first.lua<CR>",
      ignore_errmsg = true,
      note = "a file is refused before anything is added",
    },
    {
      expect = [[not _G.noted("Added to cache roots") and not _G.noted("Directory does not exist")]],
    },

    { keys = ":Gopath cache add-root two<CR>", note = "add-root: the new root is indexed" },
    { wait = [[_G.finds("deep/second.lua") and _G.noted("Added to cache roots")]], timeout = 8000 },
    { keys = ":GopathCacheAddRoot three<CR>", note = "and through the alias" },
    { wait = [[_G.finds("deep/third.lua") and _G.noted("Added to cache roots")]], timeout = 8000 },
  },
}
