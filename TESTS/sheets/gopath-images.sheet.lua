-- gF on an image with the real images.nvim and the real chooser of ui.nvim (lib.nvim's kit): the chooser lists
-- "System app" first, Esc opens nothing, "inline" and "zen" reach images.nvim's own functions (which run for real; a
-- fall-back to the system app would show here), and `optout` / `picker = false, default = "zen"` skip the chooser.
-- The system app is a recorder. images.nvim, ui.nvim and filetree.nvim (what images.nvim needs) come from their
-- *_NVIM_DIR or the checkouts beside this one; without them (CI) the sheet is a reported skip, never green. No `feature`:
-- the CI workflow provides none of them. Whether the picture itself looks right in a real terminal is the `manual` part.
return {
  id = "gopath.images-chooser",
  title = "gopath.nvim: gF on an image offers System app / inline / zen with the real images.nvim",
  task = "gopath.nvim/gf-auf-ein-bild-chooser-mit-images-nvim-live-pruefen",
  requires = {
    {
      lua = [[(function()
        local up = vim.fs.dirname(vim.fn.getcwd())
        for name, marker in pairs({ IMAGES = "images", UI = "ui", FILETREE = "filetree" }) do
          local dir = vim.env[name .. "_NVIM_DIR"] or (up .. "/" .. marker .. ".nvim")
          if vim.fn.isdirectory(dir .. "/lua/" .. marker) ~= 1 then return false end
        end
        return true
      end)()]],
      reason = "images.nvim, ui.nvim or filetree.nvim is not beside this checkout (*_NVIM_DIR unset)",
    },
  },
  manual = {
    "In a terminal that draws images (WezTerm, Windows Terminal), inline and zen show the picture itself",
  },
  steps = {
    {
      lua = [[local up = vim.fs.dirname(vim.fn.getcwd())
      for name, marker in pairs({ IMAGES = "images", UI = "ui", FILETREE = "filetree" }) do
        vim.opt.rtp:append(vim.env[name .. "_NVIM_DIR"] or (up .. "/" .. marker .. ".nvim"))
      end
      dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      vim.g.have_nerd_font = false
      _G.setup()
      -- a real 1x1 PNG
      _G.pic = _G.DIR .. "/img/pic.png"
      vim.fn.mkdir(_G.DIR .. "/img", "p")
      local f = assert(io.open(_G.pic, "wb"))
      f:write(vim.base64.decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
      ))
      f:close()
      require("images").setup({})
      -- The system app: recorded, nothing starts.
      _G.OPENED = nil
      package.loaded["gopath.external.helpers.opener"] = {
        open_with_system = function(path)
          _G.OPENED = path
          return true
        end,
      }
      vim.ui.open = function(path)
        _G.OPENED = path
        return nil, "not in a test"
      end
      -- images.nvim's own show and zen run for real; the first one called is what gopath chose (zen draws through
      -- show itself).
      _G.MODE = nil
      local images = require("images")
      for _, mode in ipairs({ "show", "zen" }) do
        local real = images[mode]
        images[mode] = function(path, ...)
          _G.MODE = _G.MODE or (mode .. ":" .. vim.fs.basename(path))
          return real(path, ...)
        end
      end
      ---The rows of the focused float (the chooser), trimmed, joined by "|".
      _G.rows = function()
        if not _G.dialog() then return "" end
        local out = {}
        for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
          local t = vim.trim(l)
          if t ~= "" then out[#out + 1] = t end
        end
        return table.concat(out, "|")
      end
      ---The cursor back on the image link in a scratch buffer, nothing recorded, no float left over.
      _G.fresh = function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_config(w).relative ~= "" then pcall(vim.api.nvim_win_close, w, true) end
        end
        _G.OPENED, _G.MODE = nil, nil
        _G.on("img/pic.png")
      end]],
      note = "real images.nvim and chooser; a 1x1 PNG; the system app is a recorder",
    },
    {
      expect = [[require("gopath.external.images").available()]],
      note = "gopath sees images.nvim",
    },

    { lua = [[_G.fresh()]] },
    { keys = "gF", note = "gF on a png: the chooser, System app first" },
    { wait = [[_G.rows():find("System app", 1, true) ~= nil]], timeout = 8000 },
    {
      expect = [[(function()
        local r = _G.rows()
        local s, i, z = r:find("System app", 1, true), r:find("inline", 1, true), r:find("zen", 1, true)
        return s and i and z and s < i and i < z
      end)()]],
      note = "the order is System app, inline, zen",
    },
    { keys = "<Esc>", note = "Esc closes the chooser" },
    { wait = [[not _G.dialog()]], timeout = 5000 },
    { lua = [[vim.wait(300)]], note = "a moment for a late open" },
    { expect = [[_G.OPENED == nil and _G.MODE == nil]], note = "and opens nothing" },

    { lua = [[_G.fresh()]] },
    { keys = "gF" },
    { wait = [[_G.rows():find("inline", 1, true) ~= nil]], timeout = 8000 },
    { keys = "j<CR>", note = "inline: images.nvim's show draws the picture" },
    { wait = [[_G.MODE == "show:pic.png"]], timeout = 8000 },
    { lua = [[vim.wait(300)]], note = "a moment for a late open" },
    { expect = [[_G.OPENED == nil]], note = "no fall-back to the system app" },

    { lua = [[_G.fresh()]] },
    { keys = "gF" },
    { wait = [[_G.rows():find("zen", 1, true) ~= nil]], timeout = 8000 },
    { keys = "jj<CR>", note = "zen: images.nvim's zoomable float" },
    { wait = [[_G.MODE == "zen:pic.png"]], timeout = 8000 },
    { lua = [[vim.wait(300)]], note = "a moment for a late open" },
    { expect = [[_G.OPENED == nil]], note = "no fall-back to the system app" },

    { lua = [[_G.fresh()]] },
    { keys = "gF" },
    { wait = [[_G.rows():find("System app", 1, true) ~= nil]], timeout = 8000 },
    { keys = "<CR>", note = "System app: the system viewer gets the file" },
    {
      wait = [[_G.OPENED ~= nil and vim.endswith((_G.OPENED:gsub("\\", "/")), "img/pic.png")]],
      timeout = 8000,
    },
    { expect = [[_G.MODE == nil]] },

    {
      lua = [[_G.setup({ external = { images = { optout = true } } }); _G.fresh()]],
      note = "optout = true: images.nvim is never offered",
    },
    { keys = "gF" },
    {
      wait = [[_G.OPENED ~= nil and vim.endswith((_G.OPENED:gsub("\\", "/")), "img/pic.png")]],
      timeout = 8000,
    },
    {
      expect = [[_G.MODE == nil and not _G.dialog()]],
      note = "straight to the system app, no chooser",
    },

    {
      lua = [[_G.setup({ external = { images = { optout = false, picker = false, default = "zen" } } }); _G.fresh()]],
      note = 'picker = false, default = "zen": no chooser, the zen float',
    },
    { keys = "gF" },
    { wait = [[_G.MODE == "zen:pic.png"]], timeout = 8000 },
    { lua = [[vim.wait(300)]], note = "a moment for a late open" },
    { expect = [[_G.OPENED == nil]] },
  },
}
