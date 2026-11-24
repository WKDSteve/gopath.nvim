-- TESTS/config_unknown_spec.lua — an unknown option is reported with a did-you-mean hint
-- (the hint comes from lib.lua.config.schema.describe_unknown).

local config = require("gopath.config")

config.setup({ lsp_timeout_mz = 5, alternate = { enabel = true } })
local text = table.concat(config.issues(), "\n")
assert(text:find("unknown option 'lsp_timeout_mz' (did you mean 'lsp_timeout_ms'?)", 1, true), text)
assert(
  text:find("unknown option 'alternate.enabel' (did you mean 'alternate.enable'?)", 1, true),
  text
)

config.setup({ zzzzzzzzzz = 1 })
assert(config.issues()[1] == "unknown option 'zzzzzzzzzz'", config.issues()[1])

config.setup({})
assert(#config.issues() == 0, "a clean setup() clears the issues")
