-- TESTS/dotted_spec.lua — gopath.util.dotted.split drops empty segments.

local dotted = require("gopath.util.dotted")

assert(vim.deep_equal(dotted.split("M.cfg.highlight"), { "M", "cfg", "highlight" }))
assert(vim.deep_equal(dotted.split("one"), { "one" }))
assert(vim.deep_equal(dotted.split("a..b"), { "a", "b" }), "consecutive dots")
assert(vim.deep_equal(dotted.split(".a."), { "a" }), "leading and trailing dot")
assert(vim.deep_equal(dotted.split(""), {}), "empty string")

-- Both Lua resolvers share it instead of carrying a copy each.
for _, mod in ipairs({ "table_locator", "value_origin" }) do
  local f = assert(io.open("lua/gopath/resolvers/lua/" .. mod .. ".lua", "rb"))
  local src = f:read("*a")
  f:close()
  assert(src:find("gopath.util.dotted", 1, true), mod .. " must use gopath.util.dotted")
  assert(not src:find("[^%.]+", 1, true), mod .. " must not carry its own dot splitter")
end
