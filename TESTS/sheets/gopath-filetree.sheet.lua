-- gT with the real filetree.nvim (its own tree, adapter "native"): the tree opens beside the buffer with its cursor on
-- the resolved file, and no buffer is opened for it. filetree.nvim and ui.nvim come from $FILETREE_NVIM_DIR /
-- $UI_NVIM_DIR or the checkouts beside this one; where they are not (CI, the worktree of `ci commit`) the sheet is a
-- reported skip, never green. No `feature`: the CI workflow provides neither, so its skip there is no mistake of the
-- provision (testing.nvim docs/SHEETS.md, `requires`). gopath-reveal.sheet.lua checks the hand-over with a stand-in.
return {
  id = "gopath.filetree-real",
  title = "gopath.nvim: gT reveals the resolved file in the real filetree.nvim, without opening a buffer",
  task = "gopath.nvim/gm-gt-echt-pruefen",
  requires = {
    {
      lua = [[(function()
        local up = vim.fs.dirname(vim.fn.getcwd())
        local tree = vim.env.FILETREE_NVIM_DIR or (up .. "/filetree.nvim")
        local ui = vim.env.UI_NVIM_DIR or (up .. "/ui.nvim")
        return vim.fn.isdirectory(tree .. "/lua/filetree") == 1 and vim.fn.isdirectory(ui .. "/lua/ui") == 1
      end)()]],
      reason = "filetree.nvim or ui.nvim is not beside this checkout ($FILETREE_NVIM_DIR / $UI_NVIM_DIR unset)",
    },
  },
  steps = {
    {
      lua = [[local up = vim.fs.dirname(vim.fn.getcwd())
      vim.opt.rtp:append(vim.env.FILETREE_NVIM_DIR or (up .. "/filetree.nvim"))
      vim.opt.rtp:append(vim.env.UI_NVIM_DIR or (up .. "/ui.nvim"))
      dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      vim.g.have_nerd_font = false
      _G.setup()
      _G.write("src/deep/target.lua")
      _G.write("src/other.lua")
      require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
        },
      })
      _G.tree = require("filetree").adapter()
      ---Whether the tree is open with its cursor on `rel` and the current window still shows the scratch buffer.
      _G.revealed = function(rel)
        local want = _G.DIR .. "/" .. rel
        local open = _G.tree.is_open()
        local win = _G.tree.get_winid()
        local node = _G.tree.get_current_node()
        if not (open and win and node and node.path) then return false end
        local got = vim.fs.normalize(vim.fn.resolve(node.path))
        if vim.fn.has("win32") == 1 then got, want = got:lower(), want:lower() end
        return got == want and vim.api.nvim_get_current_win() ~= win and vim.bo.buftype == "nofile"
      end]],
      note = "the real filetree.nvim with its own tree; watcher, git and auto-reveal off",
    },
    { expect = [[require("filetree").is_initialized()]], note = "filetree.nvim is set up" },

    { lua = [[_G.on("src/deep/target.lua")]] },
    {
      keys = "gT",
      note = "gT on a file: the tree opens with its cursor on it, the scratch buffer stays",
    },
    { wait = [[_G.revealed("src/deep/target.lua")]], timeout = 10000 },
    {
      expect = [[#vim.tbl_filter(function(b)
        return vim.endswith((vim.api.nvim_buf_get_name(b):gsub("\\", "/")), "src/deep/target.lua")
      end, vim.api.nvim_list_bufs()) == 0]],
      note = "no buffer was opened for the file",
    },

    { lua = [[_G.on("src/other.lua")]] },
    {
      keys = ":Gopath open filetree<CR>",
      note = "the command does the same with the tree already open",
    },
    { wait = [[_G.revealed("src/other.lua")]], timeout = 10000 },
  },
}
