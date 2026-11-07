-- Bindings checklist: gF, g|, g\, g} and :Gopath open / :GopathOpen with every window mode.
return {
  id = "gopath.open",
  title = "gopath.nvim: gF, g|, g\\, g} and :Gopath open open the file under the cursor where they say",
  task = "gopath.nvim/testblatt-bindings-checkliste",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.setup()
      _G.write("src/target.lua")
      _G.LINE = "see src/target.lua:3 for it"
      _G.COL = 6
      _G.opened = function(want_layout, want_tabs)
        return _G.at("src/target.lua", 3)
          and _G.layout() == want_layout
          and #vim.api.nvim_list_tabpages() == want_tabs
      end]],
    },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = "gF", note = "gF: here" },
    { wait = [[_G.opened("leaf", 1)]] },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = "g|", note = "g|: a split" },
    { wait = [[_G.opened("col", 1)]] },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = "g\\", note = "g\\: a vsplit" },
    { wait = [[_G.opened("row", 1)]] },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = "g}", note = "g}: a tab" },
    { wait = [[_G.opened("leaf", 2)]] },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":Gopath open<CR>", note = ":Gopath open: here" },
    { wait = [[_G.opened("leaf", 1)]] },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":Gopath open split<CR>" },
    { wait = [[_G.opened("col", 1)]] },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":Gopath open vsplit<CR>" },
    { wait = [[_G.opened("row", 1)]] },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":Gopath open tab<CR>" },
    { wait = [[_G.opened("leaf", 2)]] },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":GopathOpen<CR>", note = "the alias: here" },
    { wait = [[_G.opened("leaf", 1)]] },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":GopathOpen vsplit<CR>", note = "the alias takes a mode too" },
    { wait = [[_G.opened("row", 1)]] },
  },
}
