-- Bindings checklist: gC, :Gopath check, :GopathCheck, and the create offer of a missing path.
return {
  id = "gopath.check",
  title = "gopath.nvim: gC reports an existing path and offers to create a missing one",
  task = "gopath.nvim/testblatt-bindings-checkliste",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.setup()
      _G.write("src/target.lua")
      _G.exists = function(rel)
        return vim.fn.filereadable(_G.DIR .. "/" .. rel) == 1
      end]],
    },

    { lua = [[_G.on("src/target.lua")]] },
    { keys = "gC", note = "gC on a file that is there: says so, opens nothing, asks nothing" },
    { expect = [[_G.noted("exists: ") and vim.bo.buftype == "nofile" and not _G.dialog()]] },
    { keys = ":Gopath check<CR>" },
    { expect = [[_G.noted("exists: ") and vim.bo.buftype == "nofile"]] },
    { keys = ":GopathCheck<CR>" },
    { expect = [[_G.noted("exists: ") and vim.bo.buftype == "nofile"]] },

    { lua = [[_G.on("new/dir/one.lua")]] },
    { keys = "gC", note = "gC on a missing file: the dialog" },
    { wait = [[_G.dialog()]] },
    { keys = "<CR>", note = "the first button is Create: file, parents, and it opens" },
    { wait = [[_G.at("new/dir/one.lua") and not _G.dialog()]] },
    { expect = [[_G.exists("new/dir/one.lua")]] },

    { lua = [[_G.on("new/dir/two.lua")]] },
    { keys = ":Gopath check<CR>" },
    { wait = [[_G.dialog()]] },
    { keys = "q", note = "q cancels: nothing is created, and it says so" },
    { wait = [[not _G.dialog()]] },
    { expect = [[not _G.exists("new/dir/two.lua") and _G.noted("File not created")]] },

    {
      lua = [[_G.setup({ create_on_missing = { enable = false } })
      _G.on("new/dir/three.lua")]],
      note = "gC is an explicit request: it asks even with create_on_missing.enable = false",
    },
    { keys = ":GopathCheck<CR>" },
    { wait = [[_G.dialog()]] },
    { keys = "<CR>" },
    { wait = [[_G.at("new/dir/three.lua") and _G.exists("new/dir/three.lua")]] },

    {
      lua = [[_G.setup({ create_on_missing = { enable = true } })
      _G.on("new/dir/four.lua")]],
      note = "g| on a missing file: Create opens it in the split that was asked for",
    },
    { keys = "g|" },
    { wait = [[_G.dialog()]], timeout = 8000 },
    { keys = "<CR>" },
    { wait = [[_G.at("new/dir/four.lua") and _G.layout() == "col"]] },
  },
}
