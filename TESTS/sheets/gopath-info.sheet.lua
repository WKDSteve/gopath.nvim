-- Bindings checklist: g?, :Gopath debug, :GopathDebug, :GopathResolve; gY, :Gopath copy, :GopathCopy.
return {
  id = "gopath.info",
  title = "gopath.nvim: g? reports the resolution, gY copies path:line:col",
  task = "gopath.nvim/testblatt-bindings-checkliste",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.setup()
      _G.write("src/target.lua")
      _G.on("see src/target.lua:3 for it", 6)
      _G.reported = function()
        local text = table.concat(_G.NOTES, "\n")
        _G.NOTES = {}
        return text:find("=== Gopath Debug ===", 1, true) ~= nil
          and text:find("kind:       file", 1, true) ~= nil
          and text:find("source:     %S") ~= nil
          and text:find("src/target.lua", 1, true) ~= nil
          and text:find("line=3", 1, true) ~= nil
      end
      -- The clipboard leaves the child editor: what would reach it is recorded instead.
      package.loaded["lib.nvim.cross.copy_to_clipboard"] = function(text)
        _G.COPIED = text
        return true
      end
      _G.copied = function()
        local text = _G.COPIED
        _G.COPIED = nil
        return text ~= nil and vim.endswith(text, "src/target.lua:3:1")
      end]],
    },

    { keys = "g?", note = "g?: the report names the kind, the source, the path and the line" },
    { expect = [[_G.reported()]] },
    { keys = ":Gopath debug<CR>" },
    { expect = [[_G.reported()]] },
    { keys = ":GopathDebug<CR>" },
    { expect = [[_G.reported()]] },
    { keys = ":GopathResolve<CR>" },
    { expect = [[_G.reported()]] },
    { expect = [[vim.bo.buftype == "nofile"]], note = "no report opened anything" },

    { keys = "gY", note = "gY: path:line:col, and it says so" },
    { expect = [[_G.copied() and _G.noted("copied to clipboard")]] },
    { keys = ":Gopath copy<CR>" },
    { expect = [[_G.copied() and _G.noted("copied to clipboard")]] },
    { keys = ":GopathCopy<CR>" },
    { expect = [[_G.copied() and _G.noted("copied to clipboard")]] },

    {
      lua = [[package.loaded["lib.nvim.cross.copy_to_clipboard"] = function()
        return false
      end]],
      note = "no clipboard at all: it does not claim to have copied",
    },
    { keys = "gY" },
    { expect = [[_G.noted("could not copy to clipboard")]] },
  },
}
