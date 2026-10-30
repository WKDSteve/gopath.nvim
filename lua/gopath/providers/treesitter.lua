---@module 'gopath.providers.treesitter'
---@brief Small helpers around Tree-sitter to get nodes/captures at cursor.

local M = {}

---Check whether the `vim.treesitter` module can be `require`d.
---@internal
---@return boolean
local function has_ts()
  return pcall(require, "vim.treesitter")
end

---@return TSNode|nil
function M.node_at_cursor()
  if not has_ts() then return nil end
  local ts = require("vim.treesitter")
  local ok, parser = pcall(ts.get_parser, 0)
  if not ok or not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end
  local root = tree:root()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  return root and root:named_descendant_for_range(row, col, row, col) or nil
end

---Parse arbitrary source text (not tied to any open buffer) with the given
---language's Tree-sitter parser. Used to run real Treesitter queries against
---files read via `vim.fn.readfile` (e.g. a required module the cursor isn't
---currently in), where `node_at_cursor`'s buffer-0 assumption doesn't apply.
---@param text string
---@param lang string
---@return TSNode|nil root  or nil if `lang`'s parser isn't available
function M.parse_string(text, lang)
  if not has_ts() then return nil end
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then return nil end
  local ok2, trees = pcall(function()
    return parser:parse()
  end)
  if not ok2 or not trees or not trees[1] then return nil end
  return trees[1]:root()
end

--- Return capture names at position (best-effort, core `vim.treesitter` only:
--- `get_captures_at_pos` exists since Neovim 0.9, and nvim-treesitter's
--- `ts_utils` helper is gone in its rewrite).
---@param row integer  -- 0-based
---@param col integer  -- 0-based
---@return string[]
function M.captures_at_pos(row, col)
  if not has_ts() then return {} end
  local ok, list = pcall(vim.treesitter.get_captures_at_pos, 0, row, col)
  if ok and type(list) == "table" then return list end
  return {}
end

return M
