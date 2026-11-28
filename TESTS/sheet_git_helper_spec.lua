-- TESTS/sheet_git_helper_spec.lua — the sheet helper _G.git raises with git's own output (command, exit code,
-- stderr), so a failure on the hosted CI is readable instead of a bare stacktrace.

dofile("TESTS/sheets/_helpers.lua")

assert(_G.git("", { "init", "-q", "r" }) == "", "a successful call returns its trimmed stdout")
assert(_G.git("r", { "rev-parse", "--is-inside-work-tree" }) == "true")

local ok, err = pcall(_G.git, "r", { "rev-parse", "--verify", "no-such-ref-xyz" })
assert(not ok, "a failing git call must raise")
err = tostring(err)
assert(
  err:find("rev-parse --verify no-such-ref-xyz", 1, true),
  "the message names the command: " .. err
)
assert(err:find("exit 128", 1, true), "the message names the exit code: " .. err)
-- git's own words for a missing ref; neither the command text nor the format string carries them.
assert(err:find("Needed a single revision", 1, true), "the message carries stderr: " .. err)
