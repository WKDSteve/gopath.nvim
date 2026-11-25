---@module 'gopath.util.dotted'
---@brief Split a dotted string ("a.b.c") into its non-empty segments.

local M = {}

---Empty segments are dropped: "a..b" and ".a." both give { "a", "b" } / { "a" }.
---@nodiscard
---@param s string
---@return string[]
function M.split(s)
  local t = {}
  for p in s:gmatch("[^%.]+") do
    t[#t + 1] = p
  end
  return t
end

return M
