-- Bindings checklist: gM and gT. gM runs the real reveal of lib.nvim against stand-ins for the programs it starts
-- (`fakes`: PowerShell on Windows, a file manager on Linux, `open` on macOS), so the call itself is checked; that the
-- file manager and filetree.nvim really show the file is the `manual` part.
return {
  id = "gopath.reveal",
  feature = "gopath.reveal",
  title = "gopath.nvim: gM and gT hand the resolved file over and open no buffer",
  task = "gopath.nvim/gm-gt-echt-pruefen",
  -- what lib.nvim's reveal_in_fm starts: powershell/pwsh (win_reveal.ps1), nautilus (the first manager that selects a
  -- file on Linux), open -R (macOS), and under WSL powershell.exe/pwsh.exe through Windows interop (explorer.exe is its
  -- fallback there). On Windows explorer.exe is only the fallback when PowerShell fails, and a stand-in answers 0.
  fakes = { "powershell", "pwsh", "nautilus", "open", "powershell.exe", "pwsh.exe", "explorer.exe" },
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
      -- An image viewer: vim.ui.open must not be reached by gM.
      vim.ui.open = function(path)
        _G.LAUNCHED = path
        return nil, "not in a test"
      end
      -- the calls of the stand-ins so far, from every program; each is read once
      local fakes = require("testing.fake_programs")
      _G.seen = 0
      _G.revealed = function()
        local all = {}
        for _, name in ipairs({ "powershell", "pwsh", "nautilus", "open", "powershell.exe", "pwsh.exe", "explorer.exe" }) do
          vim.list_extend(all, fakes.read(vim.env.TESTING_FAKES, name))
        end
        local new = vim.list_slice(all, _G.seen + 1)
        _G.seen = #all
        return new
      end
      -- a call names the file as one of its arguments (backslashes on Windows; under WSL a Windows path)
      _G.handed = function(tail)
        if _G.REVEALED then
          local path = _G.REVEALED
          _G.REVEALED = nil
          return vim.endswith(vim.fs.normalize(path), tail) and vim.bo.buftype == "nofile"
        end
        for _, call in ipairs(_G.revealed()) do
          for _, arg in ipairs(call.argv) do
            if vim.endswith(vim.fs.normalize((arg:gsub("\\", "/"))), tail) then
              return vim.bo.buftype == "nofile"
            end
          end
        end
        return false
      end]],
    },
    {
      expect = [[type(require("lib.nvim.cross.reveal_in_fm")) == "function"]],
      note = "lib.nvim's reveal is there: without it gopath would start explorer.exe itself, which no stand-in covers",
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
    { expect = [[not _G.dialog() and #_G.revealed() == 0]], note = "nothing was started" },

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
