-- Bindings checklist, the rest of ALL/manual-test-checklists/gopath.md: gF on a bare identifier, a table
-- chain, the origin of a config value, a path in a comment or a string and a :help tag; the similarity
-- threshold of the fuzzy alternate; a bare host with a known TLD. The system opener is recorded here.
return {
  id = "gopath.resolve",
  title = "gopath.nvim: gF resolves identifiers, chains, values, comments, help tags, near names and bare hosts",
  task = "gopath.nvim/restliche-kaestchen-der-gopath-checkliste-als-testblaetter",
  manual = {
    "gF on `config.get()` with lua_ls running opens the definition of `get`, not just the file (without a language server it opens the file)",
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.setup()
      vim.opt.rtp:append(_G.DIR)
      _G.write("lua/proj/resolve.lua", { "local M = {}", "function M.run() end", "return M" })
      _G.write("lua/proj/config.lua", {
        "local M = {}",
        "M.defaults = {",
        "  highlight = {",
        "    enable_x = true,",
        "  },",
        "}",
        "function M.get()",
        "  return M.defaults",
        "end",
        "return M",
      })
      _G.write("src/target.lua")
      _G.main = _G.write("lua/proj/main.lua", {
        'local resolver = require("proj.resolve")',
        'local config = require("proj.config")',
        "config.get()",
        'local cfg = require("proj.config")',
        "local on = cfg.highlight.enable_x",
        "-- see src/target.lua:3 for the notes",
        'local p = "src/target.lua:2"',
      })
      -- What would start the browser.
      package.loaded["gopath.external.helpers.opener"] = {
        open_with_system = function(path)
          _G.OPENED = path
          return true
        end,
      }
      -- The cursor on `word` in line `row` of lua/proj/main.lua.
      _G.in_main = function(row, word)
        vim.cmd("silent! tabonly!")
        vim.cmd("silent! only!")
        vim.cmd("edit! " .. vim.fn.fnameescape(_G.main))
        local col = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]:find(word, 1, true)
        vim.api.nvim_win_set_cursor(0, { row, col - 1 })
      end
      -- The picker of the fuzzy alternate: records the rows it was handed, then takes the first or none.
      _G.ALT = nil
      _G.PICK = false
      vim.ui.select = function(items, opts, on_choice)
        local rows = {}
        for _, item in ipairs(items) do
          rows[#rows + 1] = opts.format_item and opts.format_item(item) or tostring(item)
        end
        _G.ALT = table.concat(rows, "|")
        on_choice(_G.PICK and items[1] or nil)
      end]],
    },

    { lua = [[_G.in_main(1, "resolver")]] },
    { keys = "gF", note = "a bare identifier bound by require: the module's file" },
    { wait = [[_G.at("lua/proj/resolve.lua")]], timeout = 8000 },

    { lua = [[_G.in_main(3, "get")]] },
    {
      keys = "gF",
      note = "a table-chain call: the module's file (the exact definition needs a language server)",
    },
    { wait = [[_G.at("lua/proj/config.lua")]], timeout = 8000 },

    { lua = [[_G.in_main(5, "enable_x")]] },
    { keys = "gF", note = "a config value: traced back to the line that sets it" },
    { wait = [[_G.at("lua/proj/config.lua", 4)]], timeout = 8000 },

    { lua = [[_G.in_main(6, "src/target.lua")]] },
    { keys = "gF", note = "a relative path in a comment, with its line" },
    { wait = [[_G.at("src/target.lua", 3)]], timeout = 8000 },

    { lua = [[_G.in_main(7, "src/target.lua")]] },
    { keys = "gF", note = "a relative path in a string, with its line" },
    { wait = [[_G.at("src/target.lua", 2)]], timeout = 8000 },

    { lua = [[_G.on("vim.api.nvim_win_set_cursor")]] },
    { keys = "gF", note = "a :help tag opens the real help" },
    { wait = [[vim.bo.buftype == "help"]], timeout = 8000 },
    { lua = [[vim.cmd("silent! helpclose")]] },

    { lua = [[_G.on("https://github.com/search?q=test&type=code")]] },
    { keys = "gF", note = "a URL keeps its whole query" },
    { wait = [[_G.OPENED == "https://github.com/search?q=test&type=code"]], timeout = 8000 },

    { lua = [[_G.OPENED = nil; _G.on("github.com/neovim/neovim")]] },
    { keys = "gF", note = "a bare host with a known TLD is a URL once no file matches" },
    { wait = [[_G.OPENED == "https://github.com/neovim/neovim"]], timeout = 8000 },

    {
      lua = [[_G.OPENED = nil; _G.write("github.com/neovim/neovim", { "a file" }); _G.on("github.com/neovim/neovim")]],
    },
    { keys = "gF", note = "but a real file of that name wins" },
    { wait = [[_G.at("github.com/neovim/neovim")]], timeout = 8000 },
    { expect = [[_G.OPENED == nil]] },

    {
      lua = [[_G.write("docs/architecture-overview.md"); _G.ALT = nil; _G.PICK = false; _G.on("docs/architecture-overveiw.md")]],
    },
    {
      keys = "gF",
      note = "a near name offers the similar file with its score, before it offers to create",
    },
    { wait = [[_G.ALT ~= nil]], timeout = 8000 },
    { expect = [[_G.ALT:find("architecture-overview.md (92%)", 1, true) ~= nil]] },
    { wait = [[_G.dialog()]], timeout = 8000, note = "declined: now the create offer" },
    { keys = "q" },
    { wait = [[not _G.dialog()]] },

    { lua = [[_G.ALT = nil; _G.PICK = true; _G.on("docs/architecture-overveiw.md")]] },
    { keys = "gF", note = "picking it opens that file" },
    { wait = [[_G.at("docs/architecture-overview.md")]], timeout = 8000 },

    { lua = [[_G.ALT = nil; _G.PICK = false; _G.on("docs/zzzzzz-qqqq.md")]] },
    { keys = "gF", note = "a barely similar name is no suggestion: only the create offer" },
    { wait = [[_G.dialog()]], timeout = 8000 },
    { expect = [[_G.ALT == nil]] },
    { keys = "q" },
    { wait = [[not _G.dialog()]] },
  },
}
