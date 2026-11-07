-- Bindings checklist: <leader>pp in both modes, :Gopath probe, :GopathProbe.
return {
  id = "gopath.probe",
  title = "gopath.nvim: <leader>pp, :Gopath probe and :GopathProbe find the token or the selection by suffix",
  task = "gopath.nvim/testblatt-bindings-checkliste",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.setup()
      _G.write("deep/er/needle.lua")
      _G.LINE = "log: needle.lua (other words)"
      _G.COL = 6
      _G.found = function(want_layout)
        return _G.at("deep/er/needle.lua") and _G.layout() == want_layout
      end]],
    },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = "<leader>pp", note = "normal mode: the token under the cursor, in a vsplit" },
    { wait = [[_G.found("row")]], timeout = 8000 },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = "vt <leader>pp", note = "visual mode: just the selected span, in a vsplit" },
    { wait = [[_G.found("row")]], timeout = 8000 },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":Gopath probe<CR>", note = ":Gopath probe defaults to a vsplit" },
    { wait = [[_G.found("row")]], timeout = 8000 },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":Gopath probe edit<CR>", note = "it takes a mode" },
    { wait = [[_G.found("leaf")]], timeout = 8000 },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = "vt :Gopath probe<CR>", note = "with a range it reads the selection" },
    { wait = [[_G.found("row")]], timeout = 8000 },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":GopathProbe<CR>", note = "the alias: a vsplit" },
    { wait = [[_G.found("row")]], timeout = 8000 },

    { lua = [[_G.on(_G.LINE, _G.COL)]] },
    { keys = ":GopathProbe!<CR>", note = "the bang: a split" },
    { wait = [[_G.found("col")]], timeout = 8000 },

    { lua = [[_G.on("nothing-called-like-this.lua")]] },
    { keys = ":GopathProbe<CR>", note = "no match: it says so" },
    { wait = [[_G.noted("probe: no match found")]], timeout = 8000 },
    { expect = [[vim.bo.buftype == "nofile"]] },
  },
}
