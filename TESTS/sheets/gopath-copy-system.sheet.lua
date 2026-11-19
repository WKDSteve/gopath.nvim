-- gY where Neovim's clipboard register does not hold the text (no provider: a terminal over SSH, a bare install):
-- lib.nvim's copy falls through to the system tool, which starts a process. The tools are recording stand-ins
-- (`fakes`): PowerShell's Set-Clipboard on Windows, pbcopy on macOS, wl-copy / xclip / xsel on Linux, so the real
-- clipboard of the machine is left alone. gopath-info.sheet.lua checks gY with a recorded clipboard; this one the
-- way to the system tool. That the text really lands in the system clipboard is the `manual` part.
return {
  id = "gopath.copy-system",
  feature = "gopath.info",
  title = "gopath.nvim: gY without a clipboard provider copies through the system tool",
  fakes = { "powershell", "pwsh", "pbcopy", "wl-copy", "xclip", "xsel" },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      -- a + register that keeps nothing: setreg succeeds, getreg gives the text back empty
      vim.g.clipboard = {
        name = "sheet-none",
        copy = {
          ["+"] = function() end,
          ["*"] = function() end,
        },
        paste = {
          ["+"] = function()
            return {}
          end,
          ["*"] = function()
            return {}
          end,
        },
      }
      -- Windows: the `.cmd` stand-in puts each argument into a command line, so the | of "$input | Set-Clipboard"
      -- would pipe into a command Set-Clipboard (testing.nvim task
      -- fake-programs-der-windows-stand-in-fuehrt-die-teile-eines-ar). Escaped for cmd.exe here, before the real
      -- copy of lib.nvim starts the stand-in; the start itself stays lib.nvim's.
      if vim.fn.has("win32") == 1 then
        local run = require("lib.nvim.cross.run")
        local argv = run.argv
        run.argv = function(cmd)
          local a = argv(cmd)
          a[#a] = a[#a]:gsub("([&|<>])", "^%1")
          return a
        end
      end
      _G.setup()
      _G.write("src/target.lua")
      local fakes = require("testing.fake_programs")
      _G.tools = function()
        local all = {}
        for _, name in ipairs({ "powershell", "pwsh", "pbcopy", "wl-copy", "xclip", "xsel" }) do
          vim.list_extend(all, fakes.read(vim.env.TESTING_FAKES, name))
        end
        return all
      end]],
      note = "no clipboard provider that keeps the text",
    },

    { lua = [[_G.on("see src/target.lua:3:2 here", 6)]] },
    { keys = "gY", note = "gY: the location goes to the system clipboard tool" },
    { wait = [[_G.noted("copied to clipboard")]], timeout = 8000 },
    {
      expect = [[#_G.tools() == 1]],
      note = "one system tool was started (the first one of the platform succeeded)",
    },
  },
  manual = {
    "On a machine without a clipboard provider (WSL without win32yank, a bare Linux): gY, then paste elsewhere: the text is there",
  },
}
