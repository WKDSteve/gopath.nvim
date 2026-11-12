-- Bindings checklist: :Gopath to-repos-dir, :Gopath to-nvim-dir and their aliases, on a line and on a selection.
return {
  id = "gopath.shorten",
  feature = "gopath.shorten",
  title = "gopath.nvim: to-repos-dir and to-nvim-dir rewrite the line or just the selection to $VAR",
  task = "gopath.nvim/testblatt-bindings-checkliste",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.setup()
      _G.CONFIG = vim.fs.normalize(vim.fn.stdpath("config"))]],
    },

    { lua = [[_G.on("see E:/repos/foo/bar.lua here")]] },
    { keys = ":Gopath to-repos-dir<CR>" },
    { expect = [[_G.line() == "see $REPOS_DIR/foo/bar.lua here"]] },

    { lua = [[_G.on("see ~/repos/foo/bar.lua here")]] },
    { keys = ":GopathToReposDir<CR>", note = "the alias, another root form" },
    { expect = [[_G.line() == "see $REPOS_DIR/foo/bar.lua here"]] },

    { lua = [[_G.on("/repos/a.lua /repos/b.lua")]] },
    { keys = "vE:Gopath to-repos-dir<CR>", note = "a selection: only that span" },
    { expect = [[_G.line() == "$REPOS_DIR/a.lua /repos/b.lua"]] },

    { lua = [[_G.on("/repos/a.lua /repos/b.lua")]] },
    { keys = "WvE:GopathToReposDir<CR>", note = "the alias takes a selection too" },
    { expect = [[_G.line() == "/repos/a.lua $REPOS_DIR/b.lua"]] },

    { lua = [[_G.on("see " .. _G.CONFIG .. "/init.lua here")]] },
    { keys = ":Gopath to-nvim-dir<CR>" },
    { expect = [[_G.line() == "see $NVIM_CONFIG_DIR/init.lua here"]] },

    { lua = [[_G.on("see " .. _G.CONFIG .. "/init.lua here")]] },
    { keys = ":GopathToNvimDir<CR>" },
    { expect = [[_G.line() == "see $NVIM_CONFIG_DIR/init.lua here"]] },

    { lua = [[_G.on(_G.CONFIG .. "/a.lua " .. _G.CONFIG .. "/b.lua")]] },
    { keys = "vE:Gopath to-nvim-dir<CR>", note = "a selection: only that span" },
    { expect = [[_G.line() == "$NVIM_CONFIG_DIR/a.lua " .. _G.CONFIG .. "/b.lua"]] },
  },
}
