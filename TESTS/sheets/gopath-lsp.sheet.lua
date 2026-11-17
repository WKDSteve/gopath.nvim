-- gF on a table-chain call with a real language server: lua_ls answers the definition request, gopath's lsp
-- provider (`order = { "lsp", "treesitter", "builtin" }`) takes its location. Needs `lua-language-server` on the
-- PATH; where there is none (CI) the sheet is a reported skip, never green. No `feature`: a CI job provides no
-- language server, so its skip there is not a mistake of the provision (testing.nvim docs/SHEETS.md, `requires`).
return {
  id = "gopath.lsp-definition",
  title = "gopath.nvim: gF on config.get() with lua_ls running opens the definition of get",
  task = "gopath.nvim/gf-config-get-mit-lua-ls-definitionszeile",
  requires = {
    {
      lua = [[vim.fn.executable("lua-language-server") == 1]],
      reason = "lua-language-server is not on the PATH",
    },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      -- The pipeline waits `lsp_timeout_ms` for the server (resolve_at_cursor has no per-call timeout); the
      -- default 200 ms is too short for lua_ls on a busy machine.
      _G.setup({ lsp_timeout_ms = 5000 })
      vim.opt.rtp:append(_G.DIR)
      _G.write("lua/proj/config.lua", {
        "local M = {}",
        "M.defaults = {",
        "  enable_x = true,",
        "}",
        "",
        "-- the definition is below the first lines, so line 1 is no answer",
        "function M.get()",
        "  return M.defaults",
        "end",
        "return M",
      })
      _G.main = _G.write("lua/proj/main.lua", {
        'local config = require("proj.config")',
        "config.get()",
      })
      vim.cmd("edit! " .. vim.fn.fnameescape(_G.main))
      vim.bo.filetype = "lua"
      _G.main_buf = vim.api.nvim_get_current_buf()
      vim.lsp.start({
        name = "lua_ls",
        cmd = { "lua-language-server" },
        root_dir = _G.DIR,
        settings = {
          Lua = {
            runtime = { version = "LuaJIT", path = { "lua/?.lua", "lua/?/init.lua" } },
            workspace = { checkThirdParty = false, library = {} },
            telemetry = { enable = false },
          },
        },
      })
      -- The cursor on `get` in `config.get()`. Back to the buffer, not `:edit!`: reloading it detaches lua_ls.
      _G.on_get = function()
        vim.cmd("silent! tabonly!")
        vim.cmd("silent! only!")
        vim.api.nvim_set_current_buf(_G.main_buf)
        vim.api.nvim_win_set_cursor(0, { 2, 7 })
      end
      -- Whether lua_ls already answers the definition request for `get` (it indexes the workspace first).
      _G.lsp_ready = function()
        _G.on_get()
        local params = vim.lsp.util.make_position_params(0, "utf-8")
        local res = vim.lsp.buf_request_sync(0, "textDocument/definition", params, 2000) or {}
        for _, r in pairs(res) do
          if type(r.result) == "table" and next(r.result) ~= nil then return true end
        end
        return false
      end]],
    },
    {
      wait = [[#vim.lsp.get_clients({ bufnr = 0, name = "lua_ls" }) > 0]],
      timeout = 20000,
      note = "lua_ls is attached to lua/proj/main.lua",
    },
    {
      wait = [[_G.lsp_ready()]],
      timeout = 60000,
      note = "lua_ls has indexed the workspace and knows get",
    },
    { lua = [[_G.on_get()]] },
    {
      expect = [[(require("gopath.resolve").resolve_at_cursor() or {}).source == "lsp"]],
      note = "the answer comes from the language server, not the treesitter pass",
    },
    {
      lua = [[_G.setup({ lsp_timeout_ms = 5000, order = { "lsp" } }); _G.on_get()]],
      note = 'order = { "lsp" }: only the language server can answer gF now (treesitter finds line 7 as well)',
    },
    { keys = "gF", note = "gF on get: config.lua at the line of function M.get(), not line 1" },
    { wait = [[_G.at("lua/proj/config.lua", 7)]], timeout = 15000 },
  },
}
