-- scripts/ci/specs/wiring_spec.lua
-- Everything between `require("gopath").setup()` and the resolvers: the
-- bindings layer (keymaps, `:Gopath` and its aliases, autocommands), the help
-- opener, `:checkhealth gopath`, and setup() itself.
--
-- The command and keymap layers are re-registered against a stand-in
-- `gopath.commands`, so pressing a key or running a subcommand can be checked
-- by what it *dispatches to* rather than by what it resolves — the resolvers
-- have their own specs.

---@param H table
return function(H)
  -- ── bindings: keymaps ──────────────────────────────────────────────────────

  ---Re-register the preset with a recording `gopath.commands`.
  ---@param mappings any  the `mappings` config value
  ---@param fn fun(calls: table, registered: any)
  ---@return nil
  local function with_keymaps(mappings, fn)
    local calls = { open = {}, copy = 0, debug = 0, check = 0, probe = {} }
    H.with_modules({
      ["gopath.commands"] = {
        goto_at_cursor = function(kind)
          calls.open[#calls.open + 1] = kind
        end,
        copy_location = function()
          calls.copy = calls.copy + 1
        end,
        debug_under_cursor = function()
          calls.debug = calls.debug + 1
        end,
        check_under_cursor = function()
          calls.check = calls.check + 1
        end,
        probe_selection = function(opts)
          calls.probe[#calls.probe + 1] = opts
        end,
        shorten_to_env = function() end,
      },
    }, function()
      local keymaps = require("gopath.bindings.keymaps")
      local cfg = vim.deepcopy(require("gopath.config").get())
      cfg.mappings = mappings
      fn(calls, keymaps.setup(cfg))
    end, { unload = { "gopath.bindings.keymaps" } })
    H.fresh("gopath.bindings.keymaps")
  end

  ---The rhs callback bound to `lhs` in mode `mode`, or nil. `<Leader>` is
  ---resolved when a mapping is created, so a leader-prefixed lhs is matched by
  ---its tail.
  ---@param mode string
  ---@param lhs string
  ---@return function|nil
  local function mapped(mode, lhs)
    local leader = lhs:match("^<[Ll]eader>(.*)$")
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      if m.lhs == lhs or (leader and m.lhs:sub(-#leader) == leader and #m.lhs == #leader + 1) then
        return m.callback
      end
    end
    return nil
  end

  ---Remove every mapping the preset (or a spec) may have left behind, so a
  ---stale binding is never mistaken for a fresh one.
  ---@param extra string[]|nil
  ---@return nil
  local function clear_preset(extra)
    local lhss = { "gP", "g|", "g\\", "g}", "gM", "gY", "g?", "gC", "gQ", "gp", "g<F5>" }
    for _, lhs in ipairs(vim.list_extend(lhss, extra or {})) do
      pcall(vim.keymap.del, "n", lhs, {})
      pcall(vim.keymap.del, "v", lhs, {})
    end
    for _, mode in ipairs({ "n", "v" }) do
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        if m.desc and tostring(m.desc):find("probe") then
          pcall(vim.api.nvim_del_keymap, mode, m.lhs)
        end
      end
    end
  end

  H.check("keymaps: the default preset binds every action to its command", function()
    with_keymaps(require("gopath.config").get().mappings, function(calls)
      local pairs_to_check = {
        { "gP", "edit" },
        { "g|", "window" },
        { "g\\", "vsplit" },
        { "g}", "tab" },
        { "gM", "explorer" },
      }
      for _, pair in ipairs(pairs_to_check) do
        local cb = mapped("n", pair[1])
        H.truthy(cb, "expected " .. pair[1] .. " to be bound")
        cb()
        H.eq(calls.open[#calls.open], pair[2], pair[1] .. " opens with mode " .. pair[2])
      end

      H.truthy(mapped("n", "gY"), "copy")
      mapped("n", "gY")()
      H.eq(calls.copy, 1)

      mapped("n", "g?")()
      H.eq(calls.debug, 1)

      mapped("n", "gC")()
      H.eq(calls.check, 1)
    end)
  end)

  H.check("keymaps: the probe action is bound in both normal and visual mode", function()
    with_keymaps(require("gopath.config").get().mappings, function(calls)
      local n = mapped("n", "<Leader>pp")
      H.truthy(n, "normal-mode probe")
      n()
      H.eq(calls.probe[1].open_cmd, "vsplit")
      H.eq(calls.probe[1].ask, true)
      H.is_nil(calls.probe[1].selection, "no selection is claimed from normal mode")

      H.truthy(mapped("v", "<Leader>pp"), "visual-mode probe")
    end)
  end)

  H.check("keymaps: an individual lhs can be overridden or dropped", function()
    clear_preset()
    local cfg = vim.deepcopy(require("gopath.config").get().mappings)
    cfg.open_here = "gQ"
    cfg.debug = false
    with_keymaps(cfg, function(calls)
      local cb = mapped("n", "gQ")
      H.truthy(cb, "the override is bound")
      cb()
      H.eq(calls.open[1], "edit")
      H.is_nil(mapped("n", "gP"), "the default lhs of the overridden action is not bound")
      H.is_nil(mapped("n", "g?"), "`false` drops just that one")
      H.truthy(mapped("n", "gC"), "while its neighbours stay")
    end)
    clear_preset()
    with_keymaps(require("gopath.config").get().mappings, function() end)
  end)

  H.check("keymaps: one action may carry a list of lhs values", function()
    clear_preset()
    local cfg = vim.deepcopy(require("gopath.config").get().mappings)
    cfg.open_here = { "gP", "g<F5>" }
    with_keymaps(cfg, function(calls)
      H.truthy(mapped("n", "gP"), "the first")
      local second = mapped("n", "g<F5>")
      H.truthy(second, "and the second")
      second()
      H.eq(calls.open[1], "edit")
    end)
    clear_preset()
    with_keymaps(require("gopath.config").get().mappings, function() end)
  end)

  H.check("keymaps: mappings = false binds nothing at all", function()
    clear_preset()
    with_keymaps(false, function()
      H.is_nil(mapped("n", "gP"), "nothing bound")
      H.is_nil(mapped("n", "g?"))
      H.is_nil(mapped("n", "<Leader>pp"), "not even the probe")
    end)
    with_keymaps(require("gopath.config").get().mappings, function()
      H.truthy(mapped("n", "gP"), "and the preset comes back")
    end)
  end)

  H.check("keymaps: a probe lhs that is not <leader>-prefixed is still bound", function()
    clear_preset()
    local cfg = vim.deepcopy(require("gopath.config").get().mappings)
    cfg.probe = "gp"
    with_keymaps(cfg, function(_, registered)
      H.eq(type(registered), "table", "the registry reports what it bound")
      H.truthy(mapped("n", "gp"), "bound, just without a which-key group label")
    end)
    clear_preset()
    with_keymaps(require("gopath.config").get().mappings, function() end)
  end)

  -- ── bindings: user commands ────────────────────────────────────────────────

  ---Re-register the command layer against a recording `gopath.commands`.
  ---@param config_overrides table
  ---@param fn fun(calls: table)
  ---@return nil
  local function with_usrcmds(config_overrides, fn)
    local calls = {
      open = {},
      copy = 0,
      debug = 0,
      check = 0,
      probe = {},
      shorten = 0,
      shorten_known = 0,
      shorten_opts = {},
      shorten_known_opts = {},
    }
    H.with_modules({
      ["gopath.commands"] = {
        goto_at_cursor = function(kind)
          calls.open[#calls.open + 1] = kind
        end,
        copy_location = function()
          calls.copy = calls.copy + 1
        end,
        debug_under_cursor = function()
          calls.debug = calls.debug + 1
        end,
        check_under_cursor = function()
          calls.check = calls.check + 1
        end,
        probe_selection = function(opts)
          calls.probe[#calls.probe + 1] = opts
        end,
        shorten_to_env = function(opts)
          calls.shorten = calls.shorten + 1
          calls.shorten_opts[#calls.shorten_opts + 1] = opts
        end,
        shorten_to_known_dir = function(opts)
          calls.shorten_known = calls.shorten_known + 1
          calls.shorten_known_opts[#calls.shorten_known_opts + 1] = opts
        end,
      },
    }, function()
      local usrcmds = require("gopath.bindings.usrcmds")
      local cfg =
        vim.tbl_deep_extend("force", vim.deepcopy(require("gopath.config").get()), config_overrides)
      usrcmds.setup(cfg)
      fn(calls)
    end, { unload = { "gopath.bindings.usrcmds" } })
    H.fresh("gopath.bindings.usrcmds")
  end

  ---Delete every command gopath registers, so "not registered this time" can
  ---be told apart from "left over from the previous registration".
  ---@return nil
  local function clear_commands()
    for _, name in ipairs({
      "Gopath",
      "GopathOpen",
      "GopathCopy",
      "GopathDebug",
      "GopathResolve",
      "GopathCheck",
      "GopathProbe",
      "GopathToReposDir",
      "GopathToNvimDir",
      "GopathCacheBuild",
      "GopathCacheInfo",
      "GopathCacheAddRoot",
    }) do
      pcall(vim.api.nvim_del_user_command, name)
    end
  end

  H.check(":Gopath and its aliases exist after setup", function()
    for _, name in ipairs({
      "Gopath",
      "GopathOpen",
      "GopathCopy",
      "GopathDebug",
      "GopathResolve",
      "GopathCheck",
      "GopathProbe",
      "GopathToReposDir",
      "GopathToNvimDir",
    }) do
      H.eq(vim.fn.exists(":" .. name), 2, ":" .. name .. " is registered")
    end
  end)

  H.check(":Gopath open/copy/debug/check/to-repos-dir/to-nvim-dir each dispatch once", function()
    with_usrcmds({}, function(calls)
      vim.cmd("Gopath open")
      H.same(calls.open, { "edit" }, "no argument means edit")
      vim.cmd("Gopath open vsplit")
      vim.cmd("Gopath open split")
      vim.cmd("Gopath open tab")
      vim.cmd("Gopath open explorer")
      H.same(calls.open, { "edit", "vsplit", "window", "tab", "explorer" }, "'split' normalises")

      vim.cmd("Gopath copy")
      H.eq(calls.copy, 1)
      vim.cmd("Gopath debug")
      H.eq(calls.debug, 1)
      vim.cmd("Gopath check")
      H.eq(calls.check, 1)
      vim.cmd("Gopath to-repos-dir")
      H.eq(calls.shorten, 1)
      vim.cmd("Gopath to-nvim-dir")
      H.eq(calls.shorten_known, 1)
    end)
  end)

  H.check(
    ":Gopath to-repos-dir/to-nvim-dir and their aliases report selection = true only with a range",
    function()
      with_usrcmds({}, function(calls)
        H.buf({ "one", "two", "three" }, { filetype = "text" })

        vim.cmd("Gopath to-repos-dir")
        H.eq(calls.shorten_opts[1].selection, false, "no range given")
        vim.cmd("1,2Gopath to-repos-dir")
        H.eq(calls.shorten_opts[2].selection, true, "a range was given")

        vim.cmd("Gopath to-nvim-dir")
        H.eq(calls.shorten_known_opts[1].selection, false)
        vim.cmd("1,2Gopath to-nvim-dir")
        H.eq(calls.shorten_known_opts[2].selection, true)

        vim.cmd("GopathToReposDir")
        H.eq(calls.shorten_opts[3].selection, false, "alias, no range")
        vim.cmd("1,2GopathToReposDir")
        H.eq(calls.shorten_opts[4].selection, true, "alias, with a range")

        vim.cmd("GopathToNvimDir")
        H.eq(calls.shorten_known_opts[3].selection, false, "alias, no range")
        vim.cmd("1,2GopathToNvimDir")
        H.eq(calls.shorten_known_opts[4].selection, true, "alias, with a range")
      end)
    end
  )

  H.check(":Gopath probe knows whether a range was given", function()
    with_usrcmds({}, function(calls)
      H.buf({ "a", "b", "c" }, { filetype = "text" })
      vim.cmd("Gopath probe")
      H.eq(calls.probe[1].selection, false, "no range")
      H.eq(calls.probe[1].open_cmd, "vsplit", "the default mode")

      vim.cmd("1,2Gopath probe")
      H.eq(calls.probe[2].selection, true, "a range means a selection was given")
    end)
  end)

  H.check(":Gopath cache routes exist only when the cache is enabled", function()
    clear_commands()
    with_usrcmds({ truncated = { enable = false } }, function()
      H.eq(vim.fn.exists(":GopathCacheBuild"), 0, "not registered")
      H.eq(vim.fn.exists(":GopathCacheInfo"), 0, "nor the info one")
      H.eq(vim.fn.exists(":Gopath"), 2, "the unified command is there regardless")
    end)
    clear_commands()
    with_usrcmds({ truncated = { enable = true } }, function()
      H.eq(vim.fn.exists(":GopathCacheBuild"), 2, "back again")
      H.eq(vim.fn.exists(":GopathCacheInfo"), 2)
      H.eq(vim.fn.exists(":GopathCacheAddRoot"), 2)
    end)
  end)

  H.check(":GopathCacheAddRoot expands its argument and reports a missing directory", function()
    with_usrcmds({ truncated = { enable = true } }, function()
      local notes = H.capture_notify(function()
        vim.cmd("GopathCacheAddRoot " .. vim.fn.fnameescape("/definitely/not/a/directory"))
      end)
      H.match(H.notify_text(notes), "Directory does not exist")

      local usage = H.capture_notify(function()
        pcall(vim.cmd, "GopathCacheAddRoot")
      end)
      H.truthy(H.notify_text(usage) ~= nil, "an empty argument is handled rather than raised")
    end)
  end)

  H.check("individual aliases can be switched off one at a time", function()
    clear_commands()
    with_usrcmds({ commands = { copy = false, debug = false } }, function()
      H.eq(vim.fn.exists(":GopathCopy"), 0, "dropped")
      H.eq(vim.fn.exists(":GopathDebug"), 0, "dropped")
      H.eq(vim.fn.exists(":GopathOpen"), 2, "the others stay")
      H.eq(vim.fn.exists(":Gopath"), 2, "and the unified command is never affected")
    end)
    with_usrcmds({}, function()
      H.eq(vim.fn.exists(":GopathCopy"), 2, "and they come back")
    end)
  end)

  H.check("commands = false registers nothing at all", function()
    clear_commands()
    local registered = false
    H.with_modules({
      ["gopath.commands"] = setmetatable({}, {
        __index = function()
          registered = true
          return function() end
        end,
      }),
    }, function()
      local usrcmds = require("gopath.bindings.usrcmds")
      local cfg = vim.deepcopy(require("gopath.config").get())
      cfg.commands = false
      usrcmds.setup(cfg)
    end, { unload = { "gopath.bindings.usrcmds" } })
    H.fresh("gopath.bindings.usrcmds")
    H.falsy(registered, "the command module was not even consulted")
    H.eq(vim.fn.exists(":Gopath"), 0, "and nothing was registered")
    -- Restore the real registration for the rest of the run.
    require("gopath.bindings.usrcmds").setup(require("gopath.config").get())
    H.eq(vim.fn.exists(":Gopath"), 2, "restored")
  end)

  H.check(":GopathOpen accepts the legacy 'window_vsplit' mode name", function()
    with_usrcmds({}, function(calls)
      vim.cmd("GopathOpen window_vsplit")
      H.same(calls.open, { "vsplit" })
      vim.cmd("GopathOpen")
      H.same(calls.open, { "vsplit", "edit" }, "no argument means edit")
    end)
  end)

  H.check(":GopathProbe's bang selects a split", function()
    with_usrcmds({}, function(calls)
      vim.cmd("GopathProbe!")
      H.eq(calls.probe[1].open_cmd, "split")
      vim.cmd("GopathProbe edit")
      H.eq(calls.probe[2].open_cmd, "edit")
    end)
  end)

  -- ── bindings: autocommands ─────────────────────────────────────────────────

  H.check("autocmds: BufWritePost drops the path caches so a new file is findable", function()
    local PATH = require("gopath.util.path")
    local autocmds = require("gopath.bindings.autocmds")
    autocmds.setup(require("gopath.config").get())

    local dir = H.tmpdir()
    vim.opt.runtimepath:append(dir)
    PATH.invalidate_caches()
    H.is_nil(PATH.search_in_rtp({ "written.lua" }), "indexes the empty root")

    H.write(dir .. "/written.lua", { "" })
    H.is_nil(PATH.search_in_rtp({ "written.lua" }), "the stale index still hides it")

    vim.api.nvim_exec_autocmds("BufWritePost", {})
    local hit = PATH.search_in_rtp({ "written.lua" })

    vim.opt.runtimepath:remove(dir)
    PATH.invalidate_caches()
    H.truthy(hit, "after the write event it resolves")
  end)

  H.check("autocmds: the rebuild-on-save autocmd is opt-in and pattern-driven", function()
    local autocmds = require("gopath.bindings.autocmds")

    local function rebuild_autocmds()
      local ok, list = pcall(vim.api.nvim_get_autocmds, { group = "GopathCacheAutoRebuild" })
      return ok and list or {}
    end

    local cfg = vim.deepcopy(require("gopath.config").get())
    cfg.truncated.auto_rebuild_on_save = false
    autocmds.setup(cfg)
    H.eq(#rebuild_autocmds(), 0, "off by default")

    cfg.truncated.auto_rebuild_on_save = true
    cfg.truncated.watch_patterns = { "*.md" }
    autocmds.setup(cfg)
    local list = rebuild_autocmds()
    H.truthy(#list >= 1, "registered once opted in")
    H.eq(list[1].pattern, "*.md", "with the configured pattern")

    -- Leave the augroup empty again so later runs are not surprised by it.
    pcall(vim.api.nvim_del_augroup_by_name, "GopathCacheAutoRebuild")
    autocmds.setup(require("gopath.config").get())
  end)

  -- ── open.help ──────────────────────────────────────────────────────────────

  local help_open = require("gopath.open.help")

  ---Record every `vim.cmd` string issued while `fn` runs.
  ---@param fail_pattern string|nil  commands matching this raise, as a missing tag would
  ---@param fn fun()
  ---@return string[]
  local function with_cmd_recorder(fail_pattern, fn)
    local issued = {}
    H.with_field(vim, "cmd", function(cmd)
      issued[#issued + 1] = cmd
      if fail_pattern and type(cmd) == "string" and cmd:find(fail_pattern) then
        error("E149: Sorry, no help for " .. cmd)
      end
    end, fn)
    return issued
  end

  H.check("help.open: the window target decides the Ex command", function()
    H.eq(
      with_cmd_recorder(nil, function()
        help_open.open({ kind = "help", subject = "vim.api" }, { target = "tab" })
      end)[1],
      "tab help vim.api"
    )

    H.eq(
      with_cmd_recorder(nil, function()
        help_open.open({ kind = "help", subject = "vim.api" }, { target = "window" })
      end)[1],
      "belowright help vim.api"
    )

    H.eq(
      with_cmd_recorder(nil, function()
        help_open.open({ kind = "help", subject = "vim.api" }, nil)
      end)[1],
      "help vim.api",
      "no opts at all means the current window"
    )
  end)

  H.check("help.open: subjects are tried in order, first success wins", function()
    local issued = with_cmd_recorder("help nvim_absent%(%)", function()
      help_open.open({ kind = "help", subjects = { "nvim_absent()", "vim.api" } }, {})
    end)
    H.eq(#issued, 2, "the second candidate was needed")
    H.eq(issued[1], "help nvim_absent()")
    H.eq(issued[2], "help vim.api")
  end)

  H.check("help.open: a failing subject is retried with its parens toggled", function()
    local issued = with_cmd_recorder("help expand$", function()
      help_open.open({ kind = "help", subject = "expand" }, {})
    end)
    H.eq(issued[1], "help expand")
    H.eq(issued[2], "help expand()", "the '()' variant is the second attempt")
  end)

  H.check("help.open: everything failing ends in helpgrep, then the quickfix list", function()
    H.with_field(vim.fn, "getqflist", function()
      return { size = 3 }
    end, function()
      local issued = with_cmd_recorder("^[a-z ]*help ", function()
        help_open.open({ kind = "help", subject = "nothing_at_all" }, {})
      end)
      local text = table.concat(issued, "\n")
      H.match(text, "silent! helpgrep nothing_at_all")
      H.match(text, "cfirst", "and it jumps to the first match")
    end)
  end)

  H.check(
    "help.open: an empty quickfix list lands on the generic page, with a warning (LLS-31)",
    function()
      H.with_field(vim.fn, "getqflist", function()
        return { size = 0 }
      end, function()
        local issued, notes
        notes = H.capture_notify(function()
          issued = with_cmd_recorder("^[a-z ]*help nothing", function()
            help_open.open({ kind = "help", subject = "nothing_at_all" }, {})
          end)
        end)
        H.eq(issued[#issued], "help vim.api", "the documented last-resort landing page")

        -- LLS-31: this generic page looks exactly like an on-topic hit for
        -- "nothing_at_all" unless the fallback says otherwise -- warn, naming
        -- what was actually searched for, rather than opening it silently.
        H.match(
          H.notify_text(notes),
          'no help found for "nothing_at_all"',
          "the last-resort fallback says what it gave up looking for"
        )
      end)
    end
  )

  H.check("help.open: a non-help result is ignored", function()
    local issued = with_cmd_recorder(nil, function()
      help_open.open({ kind = "file", path = "/a.lua" }, {})
      ---@diagnostic disable-next-line: param-type-mismatch
      help_open.open(nil, {})
    end)
    H.same(issued, {}, "nothing was issued")
  end)

  -- ── health ─────────────────────────────────────────────────────────────────

  H.check("health.check: reports every section without erroring", function()
    local report = {}
    local recorder = {
      start = function(s)
        report[#report + 1] = { "start", s }
      end,
      ok = function(s)
        report[#report + 1] = { "ok", s }
      end,
      warn = function(s)
        report[#report + 1] = { "warn", s }
      end,
      error = function(s)
        report[#report + 1] = { "error", s }
      end,
      info = function(s)
        report[#report + 1] = { "info", s }
      end,
    }
    H.with_field(vim, "health", recorder, function()
      -- health.lua resolves vim.health.* into upvalues at load time.
      local health = require("gopath.health")
      health.check()
    end, { unload = { "gopath.health" } })
    -- (with_field cannot unload; do it explicitly.)
    H.fresh("gopath.health")

    local sections, text = {}, {}
    for _, entry in ipairs(report) do
      if entry[1] == "start" then sections[#sections + 1] = entry[2] end
      text[#text + 1] = tostring(entry[2])
    end
    local joined = table.concat(text, "\n")

    H.contains(sections, "Neovim version")
    H.contains(sections, "External CLI tools")
    H.contains(sections, "LSP")
    H.contains(sections, "which-key")
    H.contains(sections, "open.nvim")
    H.contains(sections, "lib.nvim")
    H.contains(sections, "filetree.nvim")
    H.contains(sections, "pdfport.nvim")
    H.contains(sections, "Tree-sitter")
    H.contains(sections, "Configuration")
    H.match(joined, "Neovim %d+%.%d+%.%d+", "the running version is named")
    H.match(joined, "lib%.nvim detected", "lib.nvim is on the runtimepath in this run")
  end)

  H.check("health.check: never touches the deprecated vim.lsp.get_active_clients", function()
    local called = false
    local function no_op() end
    local recorder = { start = no_op, ok = no_op, warn = no_op, error = no_op, info = no_op }
    local real = vim.lsp.get_active_clients
    H.fresh("gopath.health") -- it binds vim.health.* at load time
    -- Neovim 0.12 raises a deprecation warning on the CALL, not on the lookup.
    vim.lsp.get_active_clients = function()
      called = true
      return {}
    end
    local ok, err = pcall(function()
      H.with_field(vim, "health", recorder, function()
        require("gopath.health").check()
      end)
    end)
    vim.lsp.get_active_clients = real
    H.fresh("gopath.health")
    if not ok then error(err, 0) end
    H.falsy(called, "get_clients exists, so the legacy name is not called")
  end)

  ---Run `fn`, then close every window and wipe every buffer it opened and go back to the tab and
  ---window it started in -- also when `fn` raises, so a failing check leaves no layout behind for
  ---the next one. New windows close before the buffers go: wiping a buffer that a window of
  ---another tab shows would close that window (and its tab) too.
  ---@generic T
  ---@param fn fun(): T
  ---@return T
  local function in_scratch_layout(fn)
    local tab, win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
    local wins, bufs = {}, {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      wins[w] = true
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      bufs[b] = true
    end
    local ok, res = pcall(fn)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not wins[w] then pcall(vim.api.nvim_win_close, w, true) end
    end
    if vim.api.nvim_tabpage_is_valid(tab) then vim.api.nvim_set_current_tabpage(tab) end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if not bufs[b] then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
    if not ok then error(res, 0) end
    return res
  end

  ---Run `gopath.health.check()` directly (not through `:checkhealth`) from the current buffer
  ---and return the "Tree-sitter" section's lines as one string.
  ---@return string
  local function record_treesitter_section()
    local lines, inside = {}, false
    local function rec(kind)
      return function(s)
        if kind == "start" then inside = s == "Tree-sitter" end
        if inside and kind ~= "start" then lines[#lines + 1] = kind .. ": " .. tostring(s) end
      end
    end
    local recorder = {
      start = rec("start"),
      ok = rec("ok"),
      warn = rec("warn"),
      error = rec("error"),
      info = rec("info"),
    }
    -- health.lua binds vim.health.* at load time: load it while the recorder is in place.
    H.unload({ "gopath.health" })
    local ok, err = pcall(function()
      H.with_field(vim, "health", recorder, function()
        require("gopath.health").check()
      end)
    end)
    H.fresh("gopath.health")
    if not ok then error(err, 0) end
    return table.concat(lines, "\n")
  end

  ---`record_treesitter_section()` run from a buffer of the last filetype in `fts`. Each filetype
  ---gets a buffer of its own, opened in that order in the current window, so the one before the
  ---last is the alternate buffer. The buffers are wiped afterwards.
  ---@param fts string|string[]
  ---@return string
  local function treesitter_section(fts)
    return in_scratch_layout(function()
      for _, ft in ipairs(type(fts) == "table" and fts or { fts }) do
        H.buf({ "" }, { filetype = ft })
      end
      return record_treesitter_section()
    end)
  end

  H.check(
    "health.check: finds the parser through core vim.treesitter, without nvim-treesitter",
    function()
      -- Neovim bundles the lua parser; nvim-treesitter is not on this runtimepath.
      H.with_modules(
        { ["nvim-treesitter"] = false, ["nvim-treesitter.parsers"] = false },
        function()
          local text = treesitter_section("lua")
          H.match(text, "ok: Parser available for filetype: lua", "the bundled lua parser is found")
          H.no_match(text, "No Tree%-sitter parser", "not reported as missing")
          H.match(text, "uses core vim%.treesitter", "nvim-treesitter is not required")
          H.no_match(text, "resolvers disabled", "nothing is claimed to be disabled")
        end
      )
    end
  )

  H.check(
    "health.check: ignores the nvim-treesitter rewrite's parsers module (no has_parser)",
    function()
      local touched = false
      local rewrite = setmetatable({}, {
        __index = function()
          touched = true
        end,
      })
      H.with_modules({ ["nvim-treesitter"] = {}, ["nvim-treesitter.parsers"] = rewrite }, function()
        local text = treesitter_section("lua")
        H.match(text, "ok: Parser available for filetype: lua")
        H.match(text, "ok: nvim%-treesitter installed")
      end)
      H.falsy(touched, "nvim-treesitter.parsers is never consulted")
    end
  )

  H.check("health.check: a filetype without any parser is reported as such", function()
    local text = treesitter_section("gopath_no_such_parser")
    H.match(text, "info: No Tree%-sitter parser for filetype 'gopath_no_such_parser'")
  end)

  H.check("health.check: a filetype mapped to another language uses that language", function()
    -- Core itself maps the `help` filetype onto the vimdoc parser it bundles (0.10+). No
    -- vim.treesitter.language.register() of our own: core has no API to undo one.
    local text = treesitter_section("help")
    H.match(text, "ok: Parser available for filetype: help %(language 'vimdoc'%)")
  end)

  H.check("health.check: tolerates the 0.10 language.add contract (raise / no value)", function()
    -- 0.10 raises when there is no parser and returns nothing on success; 0.11+ return true or
    -- `nil, err`. The CI runs one (current) Neovim only, so the 0.10 contract is stubbed here.
    local function add_0_10(lang)
      if lang ~= "lua" then
        error("no parser for '" .. lang .. "' language, see :help treesitter-parsers")
      end
    end
    ---The section for a buffer of `ft`, with the stub in place for check() only: the lua
    ---ftplugin starts Tree-sitter when the buffer gets its filetype, and that needs the real add.
    local function section_on_0_10(ft)
      return in_scratch_layout(function()
        H.buf({ "" }, { filetype = ft })
        local text
        H.with_field(vim.treesitter.language, "add", add_0_10, function()
          text = record_treesitter_section()
        end)
        return text
      end)
    end
    H.match(section_on_0_10("lua"), "ok: Parser available for filetype: lua")
    H.match(
      section_on_0_10("gopath_no_such_parser"),
      "info: No Tree%-sitter parser for filetype 'gopath_no_such_parser'"
    )
  end)

  H.check("health.check: skips a 'checkhealth' buffer, as 0.10's health:// buffer is", function()
    -- 0.10 sets the health:// buffer's filetype to "checkhealth" before the checks run (0.11+
    -- only afterwards, so it is "" there); the buffer it was run from is the alternate buffer.
    local text = treesitter_section({ "lua", "checkhealth" })
    H.match(text, "ok: Parser available for filetype: lua %(language 'lua'%)")
    H.no_match(
      text,
      "filetype:? '?checkhealth",
      "the health:// buffer's own filetype is not checked"
    )
  end)

  ---Run the real `:checkhealth gopath` (as a user does) from a buffer of filetype `ft`, laid out
  ---by `style`/`mods`, and return the lines of the resulting health:// buffer. Everything the run
  ---opens is closed and wiped afterwards, also when `:checkhealth` raises.
  ---@param ft string
  ---@param lines string[]  content of the buffer the command is run from
  ---@param style 'float'|nil  value for vim.g.health.style
  ---@param mods string|nil  command modifiers, e.g. "vertical"
  ---@param alt_ft string|nil  filetype of a buffer opened first in the same window, so that it is
  ---  the alternate buffer of the window `:checkhealth` is run from
  ---@return string
  local function real_checkhealth(ft, lines, style, mods, alt_ft)
    return in_scratch_layout(function()
      if alt_ft then H.buf({ "" }, { filetype = alt_ft, listed = true }) end
      H.buf(lines, { filetype = ft, listed = true })
      H.with_field(vim.g, "health", style and { style = style } or nil, function()
        vim.cmd((mods and (mods .. " ") or "") .. "checkhealth gopath")
      end)
      local health_buf = vim.fn.bufnr("health://")
      if health_buf < 0 then return "" end
      return table.concat(vim.api.nvim_buf_get_lines(health_buf, 0, -1, false), "\n")
    end)
  end

  H.check("health: real_checkhealth leaves no tab, window or buffer behind on a failure", function()
    local tabs, wins = #vim.api.nvim_list_tabpages(), #vim.api.nvim_list_wins()
    local opened
    -- Fails the way a broken vim.health._check would: after its new tab is open. (:checkhealth
    -- turns any such error into E5009 "Invalid $VIMRUNTIME".)
    local function failing_check()
      opened = vim.api.nvim_create_buf(true, true)
      vim.cmd("tab sbuffer " .. opened)
      error("gopath_check_failed", 0)
    end
    local ok, err = pcall(H.with_field, vim.health, "_check", failing_check, function()
      real_checkhealth("lua", { "local x = 1" })
    end)
    H.falsy(ok, "the failure reaches the check")
    H.match(tostring(err), "Vim%(checkhealth%)")
    H.eq(#vim.api.nvim_list_tabpages(), tabs, "the new tab is closed")
    H.eq(#vim.api.nvim_list_wins(), wins, "no window is left")
    H.falsy(opened and vim.api.nvim_buf_is_valid(opened), "the buffer it opened is wiped")
  end)

  for _, case in ipairs({
    { label = "in a new tab (default)", lines = { "local x = 1" } },
    { label = "in a split (:vertical)", lines = { "local x = 1" }, mods = "vertical" },
    { label = "in a float (vim.g.health.style)", lines = { "local x = 1" }, style = "float" },
    -- :keepalt reaches the float (opened by nvim_open_win, not by an Ex command): it inherits
    -- the alternate buffer of the window it was run from (the "vim" decoy below), not that
    -- window's own lua buffer.
    {
      label = "in a float under :keepalt",
      lines = { "local x = 1" },
      style = "float",
      mods = "keepalt",
    },
  }) do
    H.check(
      "health: the real :checkhealth gopath checks the filetype it was run from, " .. case.label,
      function()
        -- A "vim" buffer as the alternate of the window it is run from: a decoy that must never
        -- be reported instead of the lua buffer.
        local text = real_checkhealth("lua", case.lines, case.style, case.mods, "vim")
        H.match(text, "Tree%-sitter", "the Tree-sitter section was rendered")
        H.match(
          text,
          "Parser available for filetype: lua %(language 'lua'%)",
          "the lua buffer's parser is reported, not the health:// buffer's empty filetype"
        )
        H.no_match(text, "No filetype to check", "a filetype was found")
      end
    )
  end

  H.check(
    "health: the real :checkhealth gopath says so when there is no filetype to check",
    function()
      local text = real_checkhealth("", { "plain text" }, nil, nil, "vim")
      H.match(text, "No filetype to check a parser for", "no silent gap in the section")
      H.no_match(text, "Parser available for filetype", "nothing is claimed")
    end
  )

  -- ── setup ──────────────────────────────────────────────────────────────────

  H.check("setup: merges the config and wires the bindings exactly once", function()
    H.config_sandbox(function()
      local bound
      H.with_modules({
        ["gopath.bindings"] = {
          setup = function(cfg)
            bound = cfg
          end,
        },
        ["gopath.truncated.cache"] = {
          setup = function() end,
          load_from_disk = function() end,
          start_periodic_refresh = function() end,
          needs_refresh = function()
            return false
          end,
          build_async = function() end,
        },
        ["lib.nvim.deps"] = { show_once = function() end },
      }, function()
        local gopath = require("gopath")
        gopath.setup({ lsp_timeout_ms = 321 })
        H.truthy(bound, "the bindings layer was set up")
        H.eq(bound.lsp_timeout_ms, 321, "with the merged config, not the raw options")
        H.eq(bound.mode, "hybrid", "including the defaults")
      end, { unload = { "gopath" } })
      H.fresh("gopath")
    end)
  end)

  H.check(
    "setup: the cache subsystem is configured from `truncated`, and skipped when off",
    function()
      H.config_sandbox(function()
        local seen = {}
        local cache_double = {
          setup = function(opts)
            seen.setup = opts
          end,
          load_from_disk = function()
            seen.loaded = true
          end,
          start_periodic_refresh = function(interval)
            seen.interval = interval
          end,
          needs_refresh = function()
            return false
          end,
          build_async = function() end,
        }
        H.with_modules({
          ["gopath.bindings"] = { setup = function() end },
          ["gopath.truncated.cache"] = cache_double,
          ["lib.nvim.deps"] = { show_once = function() end },
        }, function()
          local gopath = require("gopath")
          gopath.setup({
            truncated = {
              enable = true,
              use_cache = true,
              cache_refresh_interval = 111,
              max_depth = 4,
              cache_roots = { "/r" },
              excluded_dirs = { "x" },
            },
          })
          H.same(seen.setup.roots, { "/r" })
          H.eq(seen.setup.max_depth, 4)
          H.same(seen.setup.excluded_dirs, { "x" })
          -- Not read in setup(): about 30 ms of the VeryLazy wave for an index
          -- `search()` loads on its own (gopath.nvim/cache-load-from-disk-lazy).
          H.is_nil(seen.loaded, "the persisted index is not read during setup()")
          H.eq(seen.interval, 111, "and the refresh interval is forwarded")

          seen = {}
          gopath.setup({ truncated = { enable = false } })
          H.is_nil(seen.setup, "nothing is configured when the feature is off")
        end, { unload = { "gopath" } })
        H.fresh("gopath")
      end)
    end
  )

  H.check("setup: use_cache = false skips the periodic refresh even with the feature on", function()
    H.config_sandbox(function()
      local seen = {}
      H.with_modules({
        ["gopath.bindings"] = { setup = function() end },
        ["gopath.truncated.cache"] = {
          setup = function() end,
          load_from_disk = function() end,
          start_periodic_refresh = function(interval)
            seen.interval = interval
          end,
          needs_refresh = function()
            return false
          end,
          build_async = function() end,
        },
        ["lib.nvim.deps"] = { show_once = function() end },
      }, function()
        local gopath = require("gopath")
        gopath.setup({ truncated = { enable = true, use_cache = false } })
        H.is_nil(seen.interval, "use_cache = false means no periodic refresh is scheduled")
      end, { unload = { "gopath" } })
      H.fresh("gopath")
    end)
  end)

  H.check("setup: a stale cache schedules exactly one deferred async rebuild", function()
    H.config_sandbox(function()
      local deferred_ms, built
      H.with_modules({
        ["gopath.bindings"] = { setup = function() end },
        ["gopath.truncated.cache"] = {
          setup = function() end,
          load_from_disk = function() end,
          start_periodic_refresh = function() end,
          needs_refresh = function(max_age)
            H.eq(max_age, 3600, "the default max_cache_age")
            return true
          end,
          building = function()
            return false
          end,
          build_async = function(cb)
            built = true
            cb(true)
          end,
        },
        ["lib.nvim.deps"] = { show_once = function() end },
      }, function()
        H.with_field(vim, "defer_fn", function(fn, ms)
          deferred_ms = ms
          fn()
        end, function()
          local gopath = require("gopath")
          gopath.setup({ truncated = { enable = true, use_cache = true } })
        end)
      end, { unload = { "gopath" } })
      H.fresh("gopath")
      H.eq(deferred_ms, 2000, "the initial build is scheduled 2s out, not run inline")
      H.truthy(built, "build_async ran once the deferred timer fired")
    end)
  end)

  H.check("setup: the deferred start build steps aside for a build already running", function()
    H.config_sandbox(function()
      local built = false
      H.with_modules({
        ["gopath.bindings"] = { setup = function() end },
        ["gopath.truncated.cache"] = {
          setup = function() end,
          start_periodic_refresh = function() end,
          needs_refresh = function()
            return true
          end,
          building = function()
            return true
          end,
          build_async = function()
            built = true
          end,
        },
        ["lib.nvim.deps"] = { show_once = function() end },
      }, function()
        H.with_field(vim, "defer_fn", function(fn)
          fn()
        end, function()
          local notes = H.capture_notify(function()
            require("gopath").setup({ truncated = { enable = true, use_cache = true } })
          end)
          H.falsy(
            H.notify_text(notes):find("failed", 1, true),
            "no 'build failed' for a build that is running"
          )
        end)
      end, { unload = { "gopath" } })
      H.fresh("gopath")
      H.falsy(built, "no second build was asked for")
    end)
  end)

  H.check("setup: the one-time deps popup is skipped when deps_popup = false", function()
    H.config_sandbox(function()
      local shown = 0
      H.with_modules({
        ["gopath.bindings"] = { setup = function() end },
        ["gopath.truncated.cache"] = { setup = function() end },
        ["lib.nvim.deps"] = {
          show_once = function()
            shown = shown + 1
          end,
        },
      }, function()
        local gopath = require("gopath")
        gopath.setup({ deps_popup = false, truncated = { enable = false } })
        H.eq(shown, 0, "opted out right in the spec")
        -- `truncated.enable` repeated: setup() resets to defaults on every
        -- call (LUA-87), so leaving it out here would flip the cache
        -- subsystem back on and pull in cache-double methods this test
        -- never stubbed.
        gopath.setup({ deps_popup = true, truncated = { enable = false } })
        H.eq(shown, 1, "and shown otherwise")
      end, { unload = { "gopath" } })
      H.fresh("gopath")
    end)
  end)

  H.check("setup: an older lib.nvim without the deps module does not break setup()", function()
    H.config_sandbox(function()
      H.with_modules({
        ["gopath.bindings"] = { setup = function() end },
        ["gopath.truncated.cache"] = { setup = function() end },
        ["lib.nvim.deps"] = false,
      }, function()
        local gopath = require("gopath")
        gopath.setup({ truncated = { enable = false } })
        H.truthy(true, "setup() completed")
      end, { unload = { "gopath" } })
      H.fresh("gopath")
    end)
  end)

  H.check("the public API: resolve() delegates, commands is the command table", function()
    local gopath = require("gopath")
    H.eq(gopath.commands, require("gopath.commands"), "exposed for custom keymaps")
    H.eq(type(gopath.commands.goto_at_cursor), "function")

    local asked
    H.with_modules({
      ["gopath.resolve"] = {
        resolve_at_cursor = function(opts)
          asked = opts
          return { kind = "file", path = "/x" }, nil
        end,
      },
    }, function()
      local fresh = require("gopath")
      local r = fresh.resolve({ order = { "builtin" } })
      H.eq(r.path, "/x")
      H.same(asked.order, { "builtin" }, "the options are passed straight through")
    end, { unload = { "gopath" } })
    H.fresh("gopath")
  end)

  -- Re-register the real bindings, so the suite ends in the state
  -- `require("gopath").setup({})` left at the start.
  require("gopath.bindings").setup(require("gopath.config").get())
end
