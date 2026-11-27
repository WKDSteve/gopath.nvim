-- scripts/ci/specs/commands_spec.lua
-- gopath.commands: the layer between a keymap/`:Gopath` subcommand and the
-- resolver pipeline — window-mode routing, the async tailsearch fallback, the
-- clipboard format, the existence check and the debug report.
--
-- `gopath.resolve`, `gopath.open` and `gopath.open.help` are bound to upvalues
-- when the module loads, so they are substituted before it is required.
-- Everything else (`gopath.alternate`, `gopath.create`, tailsearch) is required
-- lazily and can be replaced in place.

---@param H table
return function(H)
  ---Load `gopath.commands` with the three upvalue-bound collaborators replaced.
  ---@param resolve_result any
  ---@param resolve_err string|nil
  ---@param fn fun(commands: table, calls: table)
  ---@return nil
  local function with_commands(resolve_result, resolve_err, fn)
    local calls = { open = {}, help = {}, resolve = 0 }
    H.with_modules({
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          calls.resolve = calls.resolve + 1
          return resolve_result, resolve_err
        end,
      },
      ["gopath.open"] = {
        open = function(res, mode)
          calls.open[#calls.open + 1] = { res = res, mode = mode }
        end,
      },
      ["gopath.open.help"] = {
        open = function(res, opts)
          calls.help[#calls.help + 1] = { res = res, opts = opts }
        end,
      },
    }, function()
      fn(require("gopath.commands"), calls)
    end, { unload = { "gopath.commands" } })
    H.fresh("gopath.commands")
  end

  ---A tailsearch stand-in that answers `found` and records what it was asked.
  ---@param found any
  ---@param record table
  ---@return table
  local function fake_tailsearch(found, record, reason)
    local TS = require("gopath.resolvers.common.tailsearch")
    return {
      sanitize = TS.sanitize,
      resolve_async = function(tail, opts, on_done, on_live_start)
        record.tail = tail
        record.opts = opts
        if on_live_start then on_live_start() end
        on_done(found)
      end,
      probe = function(raw, opts, on_done)
        record.probe = { raw = raw, opts = opts }
        on_done(found, reason)
      end,
    }
  end

  -- ── goto_at_cursor ───────────────────────────────────────────────────────

  H.check("goto_at_cursor: an existing result goes straight to the opener", function()
    H.config_sandbox(function(c)
      c.setup({ alternate = { enable = false } })
      local res = { kind = "file", path = "/a.lua", exists = true }
      with_commands(res, nil, function(commands, calls)
        commands.goto_at_cursor("vsplit")
        H.eq(#calls.open, 1)
        H.eq(calls.open[1].res, res)
        H.eq(calls.open[1].mode, "vsplit", "the window mode is forwarded")
      end)
    end)
  end)

  H.check("goto_at_cursor: a help result is routed to the help opener, per mode", function()
    H.config_sandbox(function(c)
      c.setup({ alternate = { enable = false } })
      local res = { kind = "help", subject = "vim.api" }
      with_commands(res, nil, function(commands, calls)
        commands.goto_at_cursor("tab")
        commands.goto_at_cursor("window")
        commands.goto_at_cursor("vsplit")
        commands.goto_at_cursor("edit")
        H.eq(#calls.open, 0, "never the file opener")
        H.eq(#calls.help, 4)
        H.eq(calls.help[1].opts.target, "tab")
        H.eq(calls.help[2].opts.target, "window", "a split becomes a help window")
        H.eq(calls.help[3].opts.target, "window", "and so does a vsplit")
        H.eq(calls.help[4].opts.target, "edit")
      end)
    end)
  end)

  H.check(
    "goto_at_cursor: a missing result with alternates disabled falls through to open",
    function()
      H.config_sandbox(function(c)
        c.setup({ alternate = { enable = false }, tailsearch = { enable = false } })
        local res = { kind = "file", path = "/gone.lua", exists = false }
        with_commands(res, nil, function(commands, calls)
          commands.goto_at_cursor("edit")
          H.eq(#calls.open, 1, "gopath.open decides whether to offer creating it")
          H.eq(calls.open[1].res, res)
        end)
      end)
    end
  )

  H.check("goto_at_cursor: the fuzzy-alternate dialog gets its chance first", function()
    H.config_sandbox(function(c)
      c.setup({
        alternate = { enable = true, similarity_threshold = 80 },
        tailsearch = { enable = false },
      })
      local res =
        { kind = "file", path = "/gone.lua", exists = false, range = { line = 3, col = 1 } }
      local asked
      H.with_modules({
        ["gopath.alternate"] = {
          try_resolve = function(path, opts, on_done)
            asked = { path = path, opts = opts }
            on_done(true) -- handled: the user picked something
          end,
        },
      }, function()
        with_commands(res, nil, function(commands, calls)
          commands.goto_at_cursor("tab")
          H.eq(asked.path, "/gone.lua")
          H.eq(asked.opts.similarity_threshold, 80, "the configured threshold is forwarded")
          H.eq(asked.opts.mode, "tab")
          H.same(asked.opts.range, { line = 3, col = 1 })
          H.eq(#calls.open, 0, "handled means the caller must not open on top of it")
        end)
      end)
    end)
  end)

  H.check("goto_at_cursor: an unhandled alternate dialog falls through to the opener", function()
    H.config_sandbox(function(c)
      c.setup({ alternate = { enable = true }, tailsearch = { enable = false } })
      local res = { kind = "file", path = "/gone.lua", exists = false }
      H.with_modules({
        ["gopath.alternate"] = {
          try_resolve = function(_, _, on_done)
            on_done(false)
          end,
        },
      }, function()
        with_commands(res, nil, function(commands, calls)
          commands.goto_at_cursor("edit")
          H.eq(#calls.open, 1)
        end)
      end)
    end)
  end)

  H.check(
    "goto_at_cursor: a miss triggers the async search, announced only when it starts",
    function()
      H.config_sandbox(function(c)
        c.setup({
          alternate = { enable = false },
          tailsearch = { enable = true, limit = 42, max_components = 3, roots = { "/r" } },
        })
        local record = {}
        local found = { kind = "file", path = "/found/b.lua", exists = true }
        local res =
          { kind = "file", path = "a/b.lua", exists = false, range = { line = 7, col = 2 } }
        H.with_modules({
          ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(found, record),
        }, function()
          with_commands(res, nil, function(commands, calls)
            local notes = H.capture_notify(function()
              commands.goto_at_cursor("edit")
              H.truthy(
                H.wait(function()
                  return #calls.open > 0
                end),
                "the scheduled open ran"
              )
            end)
            H.eq(record.tail, "a/b.lua", "the speculative path was sanitised into a tail")
            H.same(record.opts.roots, { "/r" })
            H.eq(record.opts.limit, 42)
            H.eq(record.opts.max_components, 3)
            H.eq(record.opts.line, 7, "the speculative range came along")
            H.eq(record.opts.col, 2)
            H.eq(calls.open[1].res, found, "the live hit is what gets opened")
            H.match(H.notify_text(notes), "Dateisuche", "the slow walk announces itself")
          end)
        end)
      end)
    end
  )

  H.check("goto_at_cursor: when the live search misses, the speculative result is used", function()
    H.config_sandbox(function(c)
      c.setup({ alternate = { enable = false }, tailsearch = { enable = true } })
      local res = { kind = "file", path = "a/b.lua", exists = false }
      H.with_modules({
        ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(nil, {}),
      }, function()
        with_commands(res, nil, function(commands, calls)
          commands.goto_at_cursor("edit")
          H.truthy(
            H.wait(function()
              return #calls.open > 0
            end),
            "the fallback open ran"
          )
          H.eq(calls.open[1].res, res)
        end)
      end)
    end)
  end)

  H.check("goto_at_cursor: nothing resolved and nothing found is reported", function()
    H.config_sandbox(function(c)
      c.setup({ alternate = { enable = false }, tailsearch = { enable = true } })
      H.line_at("", "", { filetype = "lua" })
      H.with_modules({
        ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(nil, {}),
      }, function()
        with_commands(nil, "no-match", function(commands, calls)
          local notes = H.capture_notify(function()
            commands.goto_at_cursor("edit")
          end)
          H.eq(#calls.open, 0)
          H.match(H.notify_text(notes), "no match", "and the reason is named")
        end)
      end)
    end)
  end)

  H.check("goto_at_cursor: tailsearch.enable = false skips the async pass entirely", function()
    H.config_sandbox(function(c)
      c.setup({ alternate = { enable = false }, tailsearch = { enable = false } })
      H.with_modules({
        ["gopath.resolvers.common.tailsearch"] = {
          resolve_async = function()
            error("tailsearch is off; it must not be consulted")
          end,
          sanitize = function()
            error("nor sanitised")
          end,
        },
      }, function()
        with_commands(nil, "no-match", function(commands, calls)
          local notes = H.capture_notify(function()
            commands.goto_at_cursor("edit")
          end)
          H.eq(#calls.open, 0)
          H.match(H.notify_text(notes), "no match")
        end)
      end)
    end)
  end)

  -- ── copy_location ───────────────────────────────────────────────────────
  -- commands.lua writes through lib.nvim's verified clipboard helper, which
  -- needs a real provider (or has("clipboard") == 1, which not every CI
  -- Neovim build reports) -- neither of which a bare runner necessarily
  -- has. Probed with its own marker so the assertions below know which
  -- outcome to expect, the same pattern TESTS/copy_to_clipboard_spec.lua
  -- and every other clipboard-touching spec in this fleet now uses.
  local clipboard_works
  do
    vim.fn.setreg("+", "")
    clipboard_works = require("lib.nvim.cross.copy_to_clipboard")("commands_spec_probe")
    vim.fn.setreg("+", "")
  end

  H.check("copy_location: 'path:line:col' for a file", function()
    vim.fn.setreg("+", "")
    with_commands(
      { kind = "file", path = "/a/b.lua", range = { line = 12, col = 4 } },
      nil,
      function(commands)
        H.capture_notify(function()
          commands.copy_location()
        end)
      end
    )
    H.eq(vim.fn.getreg("+"), clipboard_works and "/a/b.lua:12:4" or "")
  end)

  H.check("copy_location: a result with no range defaults to 1:1", function()
    vim.fn.setreg("+", "")
    with_commands({ kind = "file", path = "/a/b.lua" }, nil, function(commands)
      H.capture_notify(function()
        commands.copy_location()
      end)
    end)
    H.eq(vim.fn.getreg("+"), clipboard_works and "/a/b.lua:1:1" or "")
  end)

  H.check("copy_location: a URL is copied verbatim, so it stays pasteable", function()
    vim.fn.setreg("+", "")
    with_commands({ kind = "url", path = "https://x.com/a?b=1" }, nil, function(commands)
      H.capture_notify(function()
        commands.copy_location()
      end)
    end)
    H.eq(vim.fn.getreg("+"), clipboard_works and "https://x.com/a?b=1" or "", "no ':1:1' appended")
  end)

  H.check("copy_location: a help subject is copied in its own notation", function()
    vim.fn.setreg("+", "")
    with_commands({ kind = "help", subject = "nvim_buf_set_lines()" }, nil, function(commands)
      H.capture_notify(function()
        commands.copy_location()
      end)
    end)
    H.eq(vim.fn.getreg("+"), clipboard_works and "<help:nvim_buf_set_lines()>:1:1" or "")
  end)

  -- gY must not wait for the system clipboard tool: it hands lib.nvim an
  -- `on_done` callback and returns, and the verdict is reported from it.
  -- The stand-in blocks (errors) when called without a callback, so the old
  -- waiting form `copy(text)` fails here.
  H.check("copy_location: does not wait for the clipboard, reports from the callback", function()
    local pending, seen
    H.with_modules({
      ["lib.nvim.cross.copy_to_clipboard"] = function(text, on_done)
        if type(on_done) ~= "function" then
          error("copy_location called the waiting form copy(text)")
        end
        seen = text
        pending = on_done
      end,
    }, function()
      with_commands(
        { kind = "file", path = "/a/b.lua", range = { line = 2, col = 3 } },
        nil,
        function(commands)
          local notes = H.capture_notify(function()
            commands.copy_location()
          end)
          H.eq(seen, "/a/b.lua:2:3")
          H.eq(H.notify_text(notes), "", "nothing is claimed before the tool has answered")
          notes = H.capture_notify(function()
            pending(true)
          end)
          H.match(H.notify_text(notes), "copied to clipboard")
          notes = H.capture_notify(function()
            pending(false)
          end)
          H.match(H.notify_text(notes), "could not copy to clipboard")
        end
      )
    end)
  end)

  H.check("copy_location: nothing resolved leaves the clipboard alone", function()
    -- Without a provider, even this setup write is a no-op -- the register
    -- reads back "" either way, not "untouched". What this test actually
    -- guards (copy_location never calls the clipboard writer on the
    -- no-match path) holds regardless; only the literal value to expect
    -- depends on clipboard_works.
    vim.fn.setreg("+", "untouched")
    with_commands(nil, "no-match", function(commands)
      local notes = H.capture_notify(function()
        commands.copy_location()
      end)
      H.match(H.notify_text(notes), "no match to copy")
    end)
    H.eq(vim.fn.getreg("+"), clipboard_works and "untouched" or "")
  end)

  -- ── check_under_cursor ─────────────────────────────────────────────────────

  H.check("check_under_cursor: reports an existing path without opening it", function()
    with_commands(
      { kind = "file", path = "/a/b.lua", exists = true },
      nil,
      function(commands, calls)
        local notes = H.capture_notify(function()
          commands.check_under_cursor()
        end)
        H.match(H.notify_text(notes), "exists: /a/b%.lua")
        H.eq(#calls.open, 0, "checking is not opening")
      end
    )
  end)

  H.check("BUG: check_under_cursor's help branch is unreachable", function()
    -- The function opens with `if not res or not res.path then … end`, but a
    -- help result never has a `path` — `common/help.lua` returns
    -- `{ language, kind, subject, subjects, source, confidence }`. So `gC` on
    -- `vim.api` reports "no match to check: unknown" and the dedicated
    -- "help target — nothing to check" message four lines below can never be
    -- reached.
    with_commands({ kind = "help", subject = "vim.api" }, nil, function(commands)
      local notes = H.capture_notify(function()
        commands.check_under_cursor()
      end)
      H.match(H.notify_text(notes), "no match to check", "BUG: the generic message wins")
      H.no_match(H.notify_text(notes), "help target", "BUG: the specific one is dead code")
    end)
  end)

  H.check("check_under_cursor: a URL has nothing to check on disk", function()
    with_commands({ kind = "url", path = "https://x.com" }, nil, function(commands)
      local notes = H.capture_notify(function()
        commands.check_under_cursor()
      end)
      H.match(H.notify_text(notes), "URL — nothing to check")
    end)
  end)

  H.check("check_under_cursor: a missing path offers creation even with the feature off", function()
    H.config_sandbox(function(c)
      c.setup({ create_on_missing = { enable = false } })
      local offered
      local res = { kind = "file", path = "/gone.lua", exists = false }
      H.with_modules({
        ["gopath.create"] = {
          offer = function(r, on_created, opts)
            offered = { res = r, opts = opts }
            on_created(r)
          end,
        },
      }, function()
        with_commands(res, nil, function(commands, calls)
          commands.check_under_cursor()
          H.truthy(offered, "the offer was made")
          H.eq(offered.opts.force, true, "explicitly, because the user asked for it")
          H.eq(#calls.open, 1, "and the freshly created file is opened")
          H.eq(calls.open[1].mode, "edit")
        end)
      end)
    end)
  end)

  H.check("check_under_cursor: nothing resolved is reported", function()
    with_commands(nil, "no-match", function(commands)
      local notes = H.capture_notify(function()
        commands.check_under_cursor()
      end)
      H.match(H.notify_text(notes), "no match to check")
    end)
  end)

  -- ── probe_selection ────────────────────────────────────────────────────────

  H.check("probe_selection: uses the cursor token when no selection is claimed", function()
    H.line_at("see lua/gopath/init.lua now", "gopath", { filetype = "text" })
    local record = {}
    local found = { kind = "file", path = "/found.lua", exists = true }
    H.with_modules({
      ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(found, record),
    }, function()
      with_commands(nil, nil, function(commands, calls)
        commands.probe_selection({ open_cmd = "split" })
        H.eq(record.probe.raw, "lua/gopath/init.lua")
        H.eq(record.probe.opts.ask, true, "asking is the default")
        H.eq(#calls.open, 1)
        H.eq(calls.open[1].mode, "window", "'split' is the Ex word; gopath's mode is 'window'")
      end)
    end)
  end)

  H.check("probe_selection: each open_cmd maps onto a window mode", function()
    H.line_at("see a/b.lua now", "a/b", { filetype = "text" })
    local found = { kind = "file", path = "/found.lua", exists = true }
    for cmd, mode in pairs({
      vsplit = "vsplit",
      split = "window",
      tab = "tab",
      edit = "edit",
      explorer = "explorer",
      filetree = "filetree",
    }) do
      H.with_modules({
        ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(found, {}),
      }, function()
        with_commands(nil, nil, function(commands, calls)
          commands.probe_selection({ open_cmd = cmd })
          H.eq(calls.open[1].mode, mode, cmd .. " → " .. mode)
        end)
      end)
    end
  end)

  H.check("probe_selection: with selection = true it reads the '< '> marks", function()
    H.buf({ "prefix lua/gopath/init.lua suffix" }, { filetype = "text" })
    vim.api.nvim_buf_set_mark(0, "<", 1, 7, {})
    vim.api.nvim_buf_set_mark(0, ">", 1, 25, {})
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local record = {}
    H.with_modules({
      ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(nil, record),
    }, function()
      with_commands(nil, nil, function(commands)
        H.capture_notify(function()
          commands.probe_selection({ selection = true })
        end)
      end)
    end)
    H.eq(record.probe.raw, "lua/gopath/init.lua", "the selected span, trimmed")
  end)

  H.check("probe_selection: a linewise selection falls back to the whole line", function()
    H.buf({ "  lua/gopath/init.lua  ", "second" }, { filetype = "text" })
    vim.api.nvim_buf_set_mark(0, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(0, ">", 2, 0, {})
    local record = {}
    H.with_modules({
      ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(nil, record),
    }, function()
      with_commands(nil, nil, function(commands)
        H.capture_notify(function()
          commands.probe_selection({ selection = true })
        end)
      end)
    end)
    H.eq(record.probe.raw, "  lua/gopath/init.lua  ", "the first line of a multi-line selection")
  end)

  H.check(
    "probe_selection: a partial selection of a URL resolves directly, tailsearch is never consulted",
    function()
      H.buf({ "see github.com/neovim/neovim for the source" }, { filetype = "text" })
      vim.api.nvim_buf_set_mark(0, "<", 1, 4, {})
      vim.api.nvim_buf_set_mark(0, ">", 1, 27, {})
      H.with_modules({
        ["gopath.resolvers.common.tailsearch"] = {
          probe = function()
            error("tailsearch must not run when the direct resolver already matched")
          end,
        },
      }, function()
        with_commands(nil, nil, function(commands, calls)
          commands.probe_selection({ selection = true })
          H.eq(#calls.open, 1)
          H.eq(calls.open[1].res.kind, "url")
          H.eq(calls.open[1].res.path, "https://github.com/neovim/neovim")
        end)
      end)
    end
  )

  H.check("probe_selection: a partial selection of a $VAR reference resolves directly", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "" }, dir .. "/mod.lua")
    vim.env.GOPATH_SPEC_PROBE = dir
    H.buf({ "open $GOPATH_SPEC_PROBE/mod.lua now" }, { filetype = "text" })
    vim.api.nvim_buf_set_mark(0, "<", 1, 5, {})
    vim.api.nvim_buf_set_mark(0, ">", 1, 30, {})
    H.with_modules({
      ["gopath.resolvers.common.tailsearch"] = {
        probe = function()
          error("tailsearch must not run when the direct resolver already matched")
        end,
      },
    }, function()
      with_commands(nil, nil, function(commands, calls)
        commands.probe_selection({ selection = true })
        H.eq(#calls.open, 1)
        H.eq(calls.open[1].res.kind, "file")
        H.eq(calls.open[1].res.exists, true)
      end)
    end)
    vim.env.GOPATH_SPEC_PROBE = nil
  end)

  H.check(
    "probe_selection: a partial $VAR selection can be revealed in filetree.nvim too (open_cmd = filetree)",
    function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({ "" }, dir .. "/mod.lua")
      vim.env.GOPATH_SPEC_PROBE_FT = dir
      H.buf({ "open $GOPATH_SPEC_PROBE_FT/mod.lua now" }, { filetype = "text" })
      vim.api.nvim_buf_set_mark(0, "<", 1, 5, {})
      vim.api.nvim_buf_set_mark(0, ">", 1, 33, {})
      H.with_modules({
        ["gopath.resolvers.common.tailsearch"] = {
          probe = function()
            error("tailsearch must not run when the direct resolver already matched")
          end,
        },
      }, function()
        with_commands(nil, nil, function(commands, calls)
          commands.probe_selection({ open_cmd = "filetree", selection = true })
          H.eq(#calls.open, 1)
          H.eq(calls.open[1].mode, "filetree")
          H.eq(calls.open[1].res.kind, "file")
        end)
      end)
      vim.env.GOPATH_SPEC_PROBE_FT = nil
    end
  )

  H.check(
    "probe_selection: falls back to tailsearch when the direct resolvers find nothing",
    function()
      H.buf({ "prefix lua/gopath/init.lua suffix" }, { filetype = "text" })
      vim.api.nvim_buf_set_mark(0, "<", 1, 7, {})
      vim.api.nvim_buf_set_mark(0, ">", 1, 25, {})
      local found = { kind = "file", path = "/found.lua", exists = true }
      local record = {}
      H.with_modules({
        ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(found, record),
      }, function()
        with_commands(nil, nil, function(commands, calls)
          commands.probe_selection({ selection = true })
          H.eq(record.probe.raw, "lua/gopath/init.lua", "tailsearch DID run this time")
          H.eq(#calls.open, 1)
          H.eq(calls.open[1].res, found)
        end)
      end)
    end
  )

  H.check("probe_selection: no token at all is reported without searching", function()
    H.buf({ "" }, { filetype = "text" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.with_modules({
      ["gopath.resolvers.common.tailsearch"] = {
        probe = function()
          error("nothing to probe; this must not run")
        end,
      },
    }, function()
      with_commands(nil, nil, function(commands)
        local notes = H.capture_notify(function()
          commands.probe_selection({})
        end)
        H.match(H.notify_text(notes), "No path%-like token")
      end)
    end)
  end)

  H.check("probe_selection: a probe that finds nothing names the token it looked for", function()
    H.line_at("see a/b.lua now", "a/b", { filetype = "text" })
    H.with_modules({
      ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(nil, {}),
    }, function()
      with_commands(nil, nil, function(commands, calls)
        local notes = H.capture_notify(function()
          commands.probe_selection({})
        end)
        H.eq(#calls.open, 0)
        H.match(H.notify_text(notes), "probe: no match found for 'a/b%.lua'")
      end)
    end)
  end)

  H.check("probe_selection: a cancelled choice is not reported as 'no match found'", function()
    H.line_at("see a/b.lua now", "a/b", { filetype = "text" })
    H.with_modules({
      ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(nil, {}, "cancelled"),
    }, function()
      with_commands(nil, nil, function(commands, calls)
        local notes = H.capture_notify(function()
          commands.probe_selection({})
        end)
        H.eq(#calls.open, 0)
        H.eq(H.notify_text(notes):find("no match found", 1, true), nil, "a dismissal is silent")
      end)
    end)
  end)

  H.check("probe_selection: ask = false is forwarded to the search", function()
    H.line_at("see a/b.lua now", "a/b", { filetype = "text" })
    local record = {}
    H.with_modules({
      ["gopath.resolvers.common.tailsearch"] = fake_tailsearch(nil, record),
    }, function()
      with_commands(nil, nil, function(commands)
        H.capture_notify(function()
          commands.probe_selection({ ask = false })
        end)
      end)
    end)
    H.eq(record.probe.opts.ask, false)
  end)

  -- ── debug_under_cursor ─────────────────────────────────────────────────────

  H.check("debug_under_cursor: the report names filetype, cfile, result and cache", function()
    H.line_at("local cfg = require('gopath.config')", "gopath", { filetype = "lua" })
    local res = {
      language = "lua",
      kind = "module",
      path = "/a/b.lua",
      source = "builtin",
      confidence = 0.85,
      exists = true,
      range = { line = 4, col = 2 },
    }
    with_commands(res, nil, function(commands)
      local notes = H.capture_notify(function()
        commands.debug_under_cursor()
      end)
      local text = H.notify_text(notes)
      H.match(text, "=== Gopath Debug ===")
      H.match(text, "Filetype:%s+lua")
      H.match(text, "<cfile>:")
      H.match(text, "kind:%s+module")
      H.match(text, "path:%s+/a/b%.lua")
      H.match(text, "confidence:%s+0%.85")
      H.match(text, "exists:%s+true")
      H.match(text, "range:%s+line=4")
      H.match(text, "Cache:", "the cache summary is part of the report")
      H.match(text, "====================")
    end)
  end)

  H.check("debug_under_cursor: a failed resolution prints the error instead of a result", function()
    H.line_at("nothing", "nothing", { filetype = "lua" })
    with_commands(nil, "no-match", function(commands)
      local notes = H.capture_notify(function()
        commands.debug_under_cursor()
      end)
      local text = H.notify_text(notes)
      H.match(text, "Result: nil")
      H.match(text, "Error:%s+no%-match")
    end)
  end)

  H.check("debug_under_cursor: a Lua chain and its bindings are reported", function()
    H.buf({
      'local cfg = require("gopath.config")',
      'local log = require("gopath.util.log")',
      "cfg.options.dev_mode = true",
    }, { filetype = "lua" })
    H.cursor_on(3, "dev_mode")
    with_commands(nil, "no-match", function(commands)
      local notes = H.capture_notify(function()
        commands.debug_under_cursor()
      end)
      local text = H.notify_text(notes)
      H.match(text, "Chain:%s+cfg")
      H.match(text, "Binding map size:%s+2")
      H.match(text, "Bindings %(sample%):")
    end)
  end)

  -- ── shorten_to_env ─────────────────────────────────────────────────────────

  H.check("shorten_to_env: delegates to gopath.env_shorten", function()
    local called = false
    H.with_modules({
      ["gopath.env_shorten"] = {
        shorten_current_line = function()
          called = true
        end,
      },
    }, function()
      with_commands(nil, nil, function(commands)
        commands.shorten_to_env()
      end)
    end)
    H.truthy(called)
  end)
end
