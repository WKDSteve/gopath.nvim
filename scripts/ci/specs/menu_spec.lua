-- scripts/ci/specs/menu_spec.lua
-- gopath.integrations.menu: the "Paths" right-click entry a host (e.g. the
-- user's own RightMouse dispatcher, see config.menu.mappings) composes into
-- its own context menu. Self-gates on ui.nvim being installed and on
-- something actually resolving under the cursor / a live visual selection.

---@param H table
return function(H)
  local MENU = require("gopath.integrations.menu")

  ---A minimal but behaviourally accurate `ui.contextmenu` stand-in: real
  ---entry()/group()/submenu() semantics (gate on `available`, drop nils),
  ---without needing ui.nvim installed.
  ---@return table
  local function fake_contextmenu()
    return {
      entry = function(available, label, fn)
        if not available then return nil end
        return { name = label, cmd = fn }
      end,
      group = function(out, ...)
        local n = select("#", ...)
        for i = 1, n do
          local item = select(i, ...)
          if item ~= nil then out[#out + 1] = item end
        end
        return n > 0
      end,
      submenu = function(label, items)
        return { name = label, items = items }
      end,
    }
  end

  H.check("enabled(): what ui.nvim's ui.menu asks first", function()
    local config = require("gopath.config")
    H.eq(MENU.enabled(), true, "on by default")
    config.setup({ integrations = { ui_menu = false } })
    H.eq(MENU.enabled(), false, "integrations.ui_menu = false")
    config.setup({})
    H.eq(MENU.enabled(), true, "and back on after a plain setup")
  end)

  H.check("items(): empty list without ui.nvim installed (default test env)", function()
    H.same(MENU.items(), {})
  end)

  H.check("submenu(): nil without ui.nvim installed", function()
    H.is_nil(MENU.submenu())
  end)

  H.check("items(): empty list when nothing resolves under the cursor", function()
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          return nil, "nothing here"
        end,
      },
    }, function()
      H.same(MENU.items(), {})
    end)
  end)

  H.check("items(): a resolved file gets Open + both reveal entries", function()
    local res = { kind = "file", path = "/found.lua", exists = true }
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          return res
        end,
      },
    }, function()
      local items = MENU.items()
      H.eq(#items, 3)
      H.eq(items[1].name, "  Open")
      H.eq(items[2].name, "  Reveal in File Manager")
      H.eq(items[3].name, "  Reveal in filetree.nvim")
    end)
  end)

  H.check("items(): a URL result only gets Open, not the reveal entries", function()
    local res = { kind = "url", path = "https://example.com", exists = true }
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          return res
        end,
      },
    }, function()
      local items = MENU.items()
      H.eq(#items, 1)
      H.eq(items[1].name, "  Open")
    end)
  end)

  H.check("items(): a help result only gets Open too", function()
    local res = { kind = "help", subject = "vim.api" }
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          return res
        end,
      },
    }, function()
      H.eq(#MENU.items(), 1)
    end)
  end)

  ---The entry labels `items()` builds for a resolved `res`.
  ---@param res table
  ---@return string[]
  local function labels_for(res)
    local names = {}
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          return res
        end,
      },
    }, function()
      for _, item in ipairs(MENU.items()) do
        names[#names + 1] = item.name
      end
    end)
    return names
  end

  H.check("items(): every result naming an existing local path gets both reveal entries", function()
    for _, kind in ipairs({ "module", "id", "require", "chain", "field", "symbol", "current" }) do
      H.same(
        labels_for({ kind = kind, path = "/repo/lua/x.lua", exists = true }),
        { "  Open", "  Reveal in File Manager", "  Reveal in filetree.nvim" },
        kind .. " result"
      )
    end
  end)

  H.check(
    "items(): no reveal entries for a missing path, a commit or a file at a commit",
    function()
      local open_only = { "  Open" }
      H.same(
        labels_for({ kind = "file", path = "/nope.lua", exists = false }),
        open_only,
        "missing"
      )
      H.same(
        labels_for({ kind = "module", path = "/nope.lua", exists = false }),
        open_only,
        "module"
      )
      H.same(labels_for({ kind = "commit", path = "abc1234", exists = true }), open_only, "commit")
      H.same(
        labels_for({ kind = "commit_file", path = "/repo/a.lua", exists = true }),
        open_only,
        "commit_file"
      )
    end
  )

  H.check("open_result(): several task targets are picked from, the pick is opened", function()
    local OPEN = require("gopath.open")
    local first = { kind = "file", path = "/vault-a/t.md", exists = true }
    local second = { kind = "file", path = "/vault-b/t.md", exists = true }
    local res = vim.tbl_extend("force", first, { alternatives = { first, second } })
    local opened = {}
    local saved = OPEN.open
    OPEN.open = function(r, kind)
      opened[#opened + 1] = { res = r, kind = kind }
    end
    local ok, err = pcall(function()
      H.with_modules({
        ["gopath.resolvers.common.task_id"] = {
          pick = function(r, on_choice)
            H.eq(r, res)
            on_choice(second)
          end,
        },
      }, function()
        require("gopath.commands").open_result(res, "edit")
      end)
      H.with_modules({
        ["gopath.resolvers.common.task_id"] = {
          pick = function(_, on_choice)
            on_choice(nil)
          end,
        },
      }, function()
        require("gopath.commands").open_result(res, "explorer")
      end)
    end)
    OPEN.open = saved
    assert(ok, err)
    H.eq(#opened, 1, "a dismissed picker opens nothing")
    H.eq(opened[1].res, second)
    H.eq(opened[1].kind, "edit")
  end)

  H.check("items(): 'Open' opens exactly the resolved result via commands.open_result", function()
    local res = { kind = "file", path = "/found.lua", exists = true }
    local opened
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          return res
        end,
      },
      ["gopath.commands"] = setmetatable({
        open_result = function(r, kind)
          opened = { res = r, kind = kind }
        end,
      }, { __index = require("gopath.commands") }),
    }, function()
      local items = MENU.items()
      items[1].cmd()
      H.eq(opened.res, res)
      H.eq(opened.kind, "edit")
    end)
  end)

  H.check("submenu(): wraps the items under the 'Paths' label", function()
    local res = { kind = "file", path = "/found.lua", exists = true }
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          return res
        end,
      },
    }, function()
      local sub = MENU.submenu()
      H.truthy(sub)
      H.eq(sub.name, "  Paths")
      H.eq(#sub.items, 3)
    end)
  end)

  H.check("submenu(): nil when items() is empty (nothing resolved)", function()
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          return nil
        end,
      },
    }, function()
      H.is_nil(MENU.submenu())
    end)
  end)

  -- ── live visual selection vs. cursor ───────────────────────────────────────

  H.check(
    "items(): a live visual selection resolves via resolve_selection, not the cursor pipeline",
    function()
      H.buf({ "open github.com/neovim/neovim now" }, { filetype = "text" })
      vim.api.nvim_win_set_cursor(0, { 1, 5 }) -- 0-based col 5 == 'g' of github
      -- "github.com/neovim/neovim" is 24 chars: col 6..29 (1-based, inclusive).
      vim.cmd("normal! v23l")
      H.eq(vim.fn.mode(), "v", "still in Visual mode -- the point of this test")

      local cursor_pipeline_called = false
      H.with_modules({
        ["ui.contextmenu"] = fake_contextmenu(),
        ["gopath.resolve"] = {
          resolve_at_cursor = function()
            cursor_pipeline_called = true
            return nil
          end,
        },
      }, function()
        local items = MENU.items()
        H.falsy(cursor_pipeline_called, "the live selection short-circuited the cursor pipeline")
        H.eq(#items, 1, "a URL only ever gets the Open entry")
        H.eq(items[1].name, "  Open")
      end)
      vim.cmd("normal! \27") -- leave Visual mode (Esc) before the next check runs
    end
  )

  H.check("items(): NOT in Visual mode falls through to the cursor pipeline", function()
    H.buf({ "plain text" }, { filetype = "text" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.eq(vim.fn.mode(), "n")

    local called = false
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          called = true
          return nil
        end,
      },
    }, function()
      MENU.items()
      H.truthy(called, "no live selection, so the cursor pipeline ran")
    end)
  end)

  H.check("items(): a multi-line visual selection falls through to the cursor pipeline", function()
    H.buf({ "first line", "second line" }, { filetype = "text" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! vj")
    H.eq(vim.fn.mode(), "v")

    local called = false
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function()
          called = true
          return nil
        end,
      },
    }, function()
      MENU.items()
      H.truthy(called, "a multi-line span is not handled by the selection path")
    end)
    vim.cmd("normal! \27")
  end)

  H.check(
    "items(): linewise Visual mode ('V') never reaches resolve_selection (no garbled column slice)",
    function()
      -- Regression: getpos("v") and getpos(".") report the SAME column in
      -- linewise mode (the cursor's own), so slicing the line by column would
      -- grab one arbitrary character. A single character never resolves as a
      -- URL/$VAR either way, so asserting on the cursor-pipeline fallback
      -- alone can't tell "correctly excluded" apart from "sliced to one
      -- character that also happened to resolve to nothing" -- this asserts
      -- directly that resolve_selection.resolve_text is never even called
      -- for 'V', which only the mode-level exclusion guarantees.
      H.buf({ "github.com/neovim/neovim" }, { filetype = "text" })
      vim.api.nvim_win_set_cursor(0, { 1, 5 })
      vim.cmd("normal! V")
      H.eq(vim.fn.mode(), "V")

      local resolve_text_called = false
      H.with_modules({
        ["ui.contextmenu"] = fake_contextmenu(),
        ["gopath.resolve_selection"] = {
          resolve_text = function()
            resolve_text_called = true
            return nil
          end,
        },
        ["gopath.resolve"] = {
          resolve_at_cursor = function()
            return nil
          end,
        },
      }, function()
        MENU.items()
        H.falsy(
          resolve_text_called,
          "linewise mode must not feed a column slice to resolve_selection"
        )
      end)
      vim.cmd("normal! \27")
    end
  )

  H.check("items(): the cursor pipeline is asked to skip the lsp provider", function()
    H.buf({ "plain text" }, { filetype = "text" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local seen_opts
    H.with_modules({
      ["ui.contextmenu"] = fake_contextmenu(),
      ["gopath.resolve"] = {
        resolve_at_cursor = function(opts)
          seen_opts = opts
          return nil
        end,
      },
    }, function()
      MENU.items()
    end)
    H.truthy(seen_opts, "resolve_at_cursor was called")
    H.same(seen_opts.order, { "treesitter", "builtin" }, "lsp excluded -- see MENU_RESOLVE_OPTS")
  end)
end
