-- scripts/ci/headless_tests.lua
-- Headless CI smoke test: verifies gopath.nvim loads, `setup()` runs without
-- error, and every fixture in TESTS/ is valid, side-effect-free Lua.
--
-- The TESTS/*.lua files are written as manual, interactive test guides
-- (place cursor on a marked token, press a keymap, inspect the result) rather
-- than automated assertions, so this runner can't verify resolution outcomes.
-- What it *can* verify cheaply, on every push, is that the plugin still loads
-- cleanly and that none of the fixtures have bit-rotted into a syntax error
-- or a require() of a module that no longer exists.
--
-- Run via:
--   nvim --headless --noplugin -u NONE -c "lua dofile('scripts/ci/headless_tests.lua')"

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local failures = {}

---@param name string
---@param fn fun()
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print(("[ OK ] %s"):format(name))
  else
    print(("[FAIL] %s: %s"):format(name, err))
    failures[#failures + 1] = name
  end
end

check("require('gopath')", function()
  require("gopath")
end)

check("gopath.setup({})", function()
  require("gopath").setup({})
end)

local tests_dir = root .. "/TESTS"

-- `vim.fn.globpath` reads its directory argument as a glob PATTERN, not a
-- path -- fatal on Windows when the checkout sits under an 8.3 short name,
-- which glob tries to resolve as a home-directory reference and answers an
-- empty list for, no error (XP-01). `vim.fs.dir` takes `tests_dir` as an
-- actual path, so no directory spelling can be misread as pattern syntax.
--
-- `minimal_init.lua` is the test runner's init (scripts/test.sh) and `sheets_spec.lua` a
-- spec of the runner (it needs `describe`): neither is a guide.
local NOT_A_GUIDE = { ["minimal_init.lua"] = true, ["sheets_spec.lua"] = true }
local fixtures = {}
for name, typ in vim.fs.dir(tests_dir) do
  if typ == "file" and name:sub(-4) == ".lua" and not NOT_A_GUIDE[name] then
    fixtures[#fixtures + 1] = tests_dir .. "/" .. name
  end
end
table.sort(fixtures)

if #fixtures == 0 then
  print("[FAIL] no fixtures found under TESTS/")
  failures[#failures + 1] = "TESTS discovery"
end

for _, path in ipairs(fixtures) do
  check("TESTS/" .. vim.fn.fnamemodify(path, ":t"), function()
    local chunk = assert(loadfile(path))
    chunk()
  end)
end

if #failures > 0 then
  print(("\n%d/%d check(s) failed"):format(#failures, #fixtures + 2))
  vim.cmd("cquit 1")
else
  print(("\nAll %d checks passed."):format(#fixtures + 2))
  vim.cmd("qa!")
end
