-- gF on a PDF, an image and a URL hands them to the system's default application through lib.nvim's opener, never
-- into a buffer. The openers are recording stand-ins (`fakes`): xdg-open on Linux, open on macOS. On Windows lib.nvim
-- starts explorer.exe / rundll32.exe, names a `.cmd` stand-in cannot catch (testing.nvim task
-- fakes-unter-windows-exe-namen-explorer-exe-rundll32-exe-und), so there the opener of lib.nvim itself is replaced by a
-- recording one and the sheet checks the hand-over only. Which application comes up is the `manual` part.
return {
  id = "gopath.external",
  feature = "gopath.external",
  title = "gopath.nvim: gF on a PDF, an image or a URL hands it to the system opener, not to a buffer",
  fakes = { "xdg-open", "open" },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.WIN = vim.fn.has("win32") == 1
      _G.OPENED = {}
      if _G.WIN then
        package.loaded["lib.nvim.cross.open_default"] = function(target)
          _G.OPENED[#_G.OPENED + 1] = target
          return true
        end
      end
      _G.setup()
      _G.write("docs/manual.pdf")
      _G.write("docs/pic.png")
      -- the targets handed over so far, from the stand-ins or the recording opener; each is read once
      local fakes = require("testing.fake_programs")
      _G.seen = 0
      _G.handed = function()
        local all = vim.deepcopy(_G.OPENED)
        if not _G.WIN then
          for _, name in ipairs({ "xdg-open", "open" }) do
            for _, call in ipairs(fakes.read(vim.env.TESTING_FAKES, name)) do
              all[#all + 1] = call.argv[#call.argv]
            end
          end
        end
        local new = vim.list_slice(all, _G.seen + 1)
        _G.seen = #all
        return new
      end
      -- one target was handed over, it ends with `tail`, and gF opened no buffer for it
      _G.opened = function(tail)
        local new = _G.handed()
        -- not vim.fs.normalize: it would fold the // of a URL
        return #new == 1 and vim.endswith((new[1]:gsub("\\", "/")), tail) and vim.bo.buftype == "nofile"
      end]],
      note = "a PDF and an image in the project",
    },

    { lua = [[_G.on("see docs/manual.pdf for the details", 5)]] },
    { keys = "gF", note = "gF on the PDF: the system opener gets it" },
    { wait = [[_G.opened("docs/manual.pdf")]], timeout = 8000 },
    { wait = [[_G.noted("Opening externally: manual.pdf")]], note = "and it says so" },

    { lua = [[_G.on("docs/pic.png")]] },
    { keys = "gF", note = "gF on the image (no images.nvim): the system opener" },
    { wait = [[_G.opened("docs/pic.png")]], timeout = 8000 },

    { lua = [[_G.on("read https://example.test/a?b=1&c=2#top please", 8)]] },
    {
      keys = "gF",
      note = "gF on a URL with a query and a fragment: the whole URL goes to the browser",
    },
    { wait = [[_G.opened("https://example.test/a?b=1&c=2#top")]], timeout = 8000 },
  },
  manual = {
    "gF on a PDF opens the PDF reader of the system, on a URL the browser with that page",
  },
}
