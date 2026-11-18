---@module 'gopath.providers.token'
---@brief Smart token extraction that preserves :line:col and other metadata.

local M = {}

---Extract token at cursor position with context awareness
---Preserves :line:col, (line), and other location formats
---@return string|nil token Full token including location info
function M.extract_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  -- Path characters: alphanumeric, /, \, -, _, ., :, (, ), +, ~, @
  local path_chars = "[%w/\\%.%-%_:%(%)%+~@]"

  -- On blank space with no token right before it, read the next token after the cursor, as
  -- `<cfile>` does. Without this, the `<cfile>` fallback in get_token answers instead and
  -- drops the location suffix: gP on the indent of "  lua/x.lua:77: msg" opened lua/x.lua
  -- without line 77. A cursor right behind a token keeps reading that token.
  if line:sub(col, col):match("%s") and not line:sub(col - 1, col - 1):match(path_chars) then
    local next_col = line:find("%S", col)
    if not next_col then return nil end
    col = next_col
  end

  -- Walk backwards to find start
  local start_col = col
  while start_col > 1 do
    local char = line:sub(start_col - 1, start_col - 1)
    if not char:match(path_chars) then break end
    start_col = start_col - 1
  end

  -- Walk forwards to find end
  local end_col = col
  while end_col <= #line do
    local char = line:sub(end_col, end_col)
    if not char:match(path_chars) then break end
    end_col = end_col + 1
  end
  end_col = end_col - 1

  if start_col > end_col then return nil end

  local token = line:sub(start_col, end_col)

  -- Clean token
  token = token:gsub("^%s+", ""):gsub("%s+$", "") -- Trim whitespace
  -- Strip leading "(" pulled in from a markdown link "](path)" or a wrapping
  -- function call. "(" is part of path_chars (to support "path(10)"), so a
  -- leading one has to be removed explicitly.
  token = token:gsub("^%(+", "")
  -- Strip a single leading dot from chain context (".foo" -> "foo"),
  -- but preserve an ellipsis prefix ("...foo") used for truncated paths AND
  -- relative-path prefixes ("./foo", ".\foo") which must keep their dot.
  if not token:match("^%.%.") and not token:match("^%.[/\\]") then token = token:gsub("^%.", "") end
  token = token:gsub("%)$", "") -- Strip trailing paren (function calls)
  token = token:gsub("%($", "") -- Strip trailing opening paren

  if token == "" then return nil end

  return token
end

---Fallback to vim's <cfile>
---@return string|nil
function M.expand_cfile()
  local cfile = vim.fn.expand("<cfile>")
  if type(cfile) == "string" and cfile ~= "" then return cfile end
  return nil
end

---Get token with smart extraction, fallback to <cfile>
---@return string|nil
function M.get_token()
  local custom = M.extract_at_cursor()
  if custom and custom ~= "" then return custom end
  return M.expand_cfile()
end

return M
