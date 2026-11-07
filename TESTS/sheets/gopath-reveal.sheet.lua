-- Bindings checklist: gM and gT. The file manager and filetree.nvim are recorded here: that they really show the
-- file is the `manual` part.
return {
  id = "gopath.reveal",
  title = "gopath.nvim: gM and gT hand the resolved file over and open no buffer",
  task = "gopath.nvim/gm-gt-echt-pruefen",
  manual = {
    "gM on a file opens the system file manager with that file selected",
    "gT on a file reveals it in the real filetree.nvim",
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.setup()
      _G.write("src/target.lua")
      _G.write("src/pic.png")
      -- What would start the file manager or an image viewer.
      package.loaded["gopath.external.helpers.revealer"] = {
        reveal = function(path)
          _G.REVEALED = path
          return true
        end,
      }
      vim.ui.open = function(path)
        _G.LAUNCHED = path
        return nil, "not in a test"
      end
      _G.handed = function(tail)
        local path = _G.REVEALED
        _G.REVEALED = nil
        return path ~= nil and vim.endswith(vim.fs.normalize(path), tail) and vim.bo.buftype == "nofile"
      end]],
    },

    { lua = [[_G.on("src/target.lua")]] },
    { keys = "gM", note = "gM: the file goes to the file manager, no buffer" },
    { wait = [[_G.handed("src/target.lua")]] },
    { keys = ":Gopath open explorer<CR>" },
    { wait = [[_G.handed("src/target.lua")]] },

    { lua = [[_G.on("src/pic.png")]] },
    { keys = "gM", note = "gM goes before the image heuristic: revealed, not launched" },
    { wait = [[_G.handed("src/pic.png") and _G.LAUNCHED == nil]] },

    { lua = [[_G.on("src/no-such-thing.txt")]] },
    { keys = "gM", note = "gM on a missing path warns and offers nothing" },
    { wait = [[_G.noted("cannot reveal")]], timeout = 8000 },
    { expect = [[not _G.dialog() and _G.REVEALED == nil]] },

    { lua = [[_G.on("src/target.lua")]] },
    { keys = "gT", note = "gT without filetree.nvim: a warning" },
    { wait = [[_G.noted("filetree.nvim not available")]] },
    {
      lua = [[package.loaded["filetree"] = {
        is_initialized = function()
          return true
        end,
        adapter = function()
          return {
            open_reveal = function(path)
              _G.REVEALED = path
              return true
            end,
          }
        end,
      }]],
      note = "a stand-in for filetree.nvim's adapter, which is not on the runtimepath",
    },
    { keys = "gT", note = "gT: the file goes to the tree, no buffer" },
    { wait = [[_G.handed("src/target.lua")]] },
    { keys = ":Gopath open filetree<CR>" },
    { wait = [[_G.handed("src/target.lua")]] },
  },
}
