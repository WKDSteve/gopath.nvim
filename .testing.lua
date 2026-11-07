-- .testing.lua -- configuration of testing.nvim for this project.
-- Keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "gopath",
  -- The automated suites live in scripts/ci; TESTS/ holds manual guides (TESTS/README.md) and the
  -- test sheets (TESTS/sheets_spec.lua).
  roots = { "scripts/ci", "TESTS" },
  -- The 20 `return function(H)` specs are named *_spec.lua; the two self-running scripts that the
  -- CI used to start one by one are named explicitly.
  spec_pattern = {
    "_spec%.lua$",
    "^scripts/ci/headless_tests%.lua$",
    "^scripts/ci/functional_tests%.lua$",
  },
  -- The specs run on scripts/ci/harness.lua (found upwards from scripts/ci/specs); the two scripts
  -- run in a process of their own.
  dialect = {
    ["TESTS/sheets_spec.lua"] = "busted",
    ["scripts/ci/specs/*"] = "h",
    ["*"] = "script",
  },
  deps = { "lib.nvim" },
  -- The worktree of `ci commit` has no sibling checkouts: the child editors of the sheets find them this way.
  env_allow = { "LIB_NVIM_DIR", "TESTING_NVIM_DIR" },
  -- All test sheets run in one spec file, one child editor each: the defaults of 10 s per case and 60 s per file
  -- are reached under load (fileops, 2026-11-07).
  timeouts = { case_ms = 30000, file_ms = 300000 },
  -- gopath switches its whole keymap preset off with `mappings = false` (covered by the
  -- "mappings = false binds nothing at all" case of scripts/ci/specs/wiring_spec.lua).
  conformance = {
    -- gated: a failed check makes `scripts/test.sh conformance` exit 1
    gate = true,
    keymaps_off = { mappings = false },
    waivers = {
      {
        check = "K1",
        level = "warn",
        file = "lua/gopath/init.lua",
        reason = "the 4 autocmds are cache invalidation (BufDelete/BufWipeout) of the lua alias and binding indexes, created when those resolver modules load via gopath.commands; deferring them would change when stale entries are dropped",
        expires = "2027-04-14",
      },
      {
        check = "K6",
        level = "warn",
        text = "Cache is empty",
        reason = "the minimal conformance editor has never run :Gopath cache build; an empty filesystem index is a normal state there",
        expires = "2027-04-14",
      },
    },
  },
  -- One editor per file, started like the old CI line (`-c "lua dofile(...)"`): the specs use
  -- vim.fn.expand("<cfile>"), which raises under `nvim -l`.
  isolated = "file",
  host = "c",
  -- Guards (testing.nvim docs/GUARDS.md). The suite passes the fs, state, scheduled-error, prompt
  -- and deprecation guards cleanly (each spec file runs in an editor of its own), so those are
  -- errors: a new call of a deprecated API turns the run red.
  guards = {
    fs = "error",
    state = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    -- warn, not error: the python resolver probes whichever interpreter the machine has (python,
    -- python3, python3.12, python3.14 ...); allow_exec matches exact names, so it cannot be listed.
    process_net = "warn",
  },
  guard_allow = {
    -- lua_resolvers_spec and util_path_spec run `git` (repository root lookup) through vim.system.
    -- The python resolver specs probe the interpreter (python3 -c "import ...") through vim.system.
    -- sheets_spec.lua: every test sheet (TESTS/sheets/) runs in a child editor.
    spawn = { "git", "python3", "nvim" },
    fs = {},
    network = {},
  },
}
