-- TESTS/sheets/_helpers.lua -- what the gopath.nvim test sheets need in their child editor. Not a sheet
-- (`testing.sheet` only reads *.sheet.lua); a sheet's first step runs it with `dofile`, the child's cwd is the
-- project root. The directory is in the spec's @cache-inputs, so a change here re-runs the sheets.

vim.opt.shortmess:append("I")
vim.o.swapfile = false
vim.o.hidden = true

-- Everything a sheet resolves lives in a temp directory, and that directory is the working directory.
_G.DIR = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
vim.fn.mkdir(_G.DIR, "p")
vim.cmd.cd(vim.fn.fnameescape(_G.DIR))

---What the plugin said so far (a long message would otherwise wait at a hit-enter prompt).
---@type string[]
_G.NOTES = {}
vim.notify = function(msg)
  _G.NOTES[#_G.NOTES + 1] = tostring(msg)
end

---Whether the plugin said `text` (plain), and forget what it said so far when it did.
---@param text string
---@return boolean
function _G.noted(text)
  local hit = table.concat(_G.NOTES, "\n"):find(text, 1, true) ~= nil
  if hit then _G.NOTES = {} end
  return hit
end

---Set the plugin up with the key names of the real config (lua/plugins/personal of the nvim config),
---with its caches and searches limited to the temp directory.
---@param opts table|nil
function _G.setup(opts)
  require("gopath").setup(vim.tbl_deep_extend("force", {
    deps_popup = false,
    mappings = {
      open_here = "gF",
      open_split = "g|",
      open_vsplit = "g\\",
      open_tab = "g}",
      copy_location = "gY",
      debug = "g?",
    },
    truncated = { cache_roots = { _G.DIR } },
    tailsearch = { roots = { _G.DIR } },
  }, opts or {}))
end

---Write a file below the temp directory.
---@param rel string
---@param lines string[]|nil
---@return string abs
function _G.write(rel, lines)
  local abs = _G.DIR .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  vim.fn.writefile(lines or { "1", "2", "3", "4", "5", "6" }, abs)
  return abs
end

---One window, one tab, a scratch buffer holding `line`, the cursor on `col` (1-based, default the first column).
---@param line string
---@param col integer|nil
function _G.on(line, col)
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  vim.bo.buftype = "nofile"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  vim.api.nvim_win_set_cursor(0, { 1, (col or 1) - 1 })
end

---Whether the current buffer is the file `rel` of the temp directory, the cursor on `line` when given.
---@param rel string
---@param line integer|nil
---@return boolean
function _G.at(rel, line)
  local name = vim.fs.normalize(vim.fn.resolve(vim.api.nvim_buf_get_name(0)))
  local want = _G.DIR .. "/" .. rel
  local same = name == want
  if vim.fn.has("win32") == 1 then same = name:lower() == want:lower() end
  return same and (line == nil or vim.api.nvim_win_get_cursor(0)[1] == line)
end

---The shape of the current tab: "leaf" (one window), "col" (split) or "row" (vsplit).
---@return string
function _G.layout()
  return vim.fn.winlayout()[1]
end

---Whether a float is focused (the dialog of `create_on_missing`).
---@return boolean
function _G.dialog()
  return vim.api.nvim_win_get_config(0).relative ~= ""
end

---The current line.
---@return string
function _G.line()
  return vim.api.nvim_get_current_line()
end
