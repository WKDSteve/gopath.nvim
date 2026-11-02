-- scripts/ci/specs/create_open_spec.lua
-- gopath.create (the create-on-missing offer) and gopath.open (the unified
-- opener that routes a resolved result to a buffer, the OS, or the create
-- offer).
--
-- Both are tested against real files under vim.fn.tempname(); the collaborators
-- that would leave the editor (`gopath.external`, `gopath.external.pdf`,
-- filetree.nvim, ui.nvim) are substituted, since each is required lazily
-- *inside* the function under test.

---@param H table
return function(H)
  -- ── gopath.create ──────────────────────────────────────────────────────────

  local create = require("gopath.create")

  ---Answer lib.nvim's modal dialogs (`kit.confirm`, which backs
  ---`ui.kit.create_on_missing`) without a window: `answer` is a button label or
  ---nil (dismissed). Runs `fn`, then lets the scheduled answer be delivered.
  ---@param answer string|nil
  ---@param fn fun()
  ---@return { question: string, choices: string[], title: string }[] asked
  local function with_dialog(answer, fn)
    local kit = require("lib.nvim.ui.kit")
    local asked = {}
    kit.set_dialog_hook(function(kind, opts)
      if kind ~= "confirm" then return false end
      asked[#asked + 1] = { question = opts.question, choices = opts.choices, title = opts.title }
      return true, answer
    end)
    local ok, err = pcall(fn)
    local flushed = false
    vim.schedule(function()
      flushed = true
    end)
    vim.wait(1000, function()
      return flushed
    end, 5)
    kit.set_dialog_hook(nil)
    if not ok then error(err, 0) end
    return asked
  end

  H.check("offer: create_on_missing.enable = false reports instead of asking", function()
    H.config_sandbox(function(c)
      c.setup({ create_on_missing = { enable = false } })
      local called = false
      local notes = H.capture_notify(function()
        create.offer({ path = "/tmp/never/made.lua", exists = false }, function()
          called = true
        end)
      end)
      H.falsy(called, "on_created is not reached")
      H.match(H.notify_text(notes), "File not found: /tmp/never/made%.lua")
    end)
  end)

  H.check("offer: force = true bypasses the enable flag (the explicit `check` action)", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({ create_on_missing = { enable = false, confirm = false } })
      local got
      H.capture_notify(function()
        create.offer({ path = dir .. "/forced.lua", exists = false }, function(res)
          got = res
        end, { force = true })
      end)
      H.truthy(got, "on_created ran")
      H.eq(vim.fn.filereadable(dir .. "/forced.lua"), 1, "the file is on disk")
    end)
  end)

  H.check("offer: confirm = false creates silently, marks the result, and hands it back", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({ create_on_missing = { enable = true, confirm = false } })
      local res = { path = dir .. "/deep/nested/new.lua", exists = false }
      local got
      local notes = H.capture_notify(function()
        create.offer(res, function(r)
          got = r
        end)
      end)
      H.eq(got, res, "the same result object is handed back")
      H.eq(res.exists, true, "and is now marked as existing")
      H.eq(vim.fn.filereadable(dir .. "/deep/nested/new.lua"), 1, "parent directories were created")
      H.match(H.notify_text(notes), "Created: ")
    end)
  end)

  H.check("offer: a file that cannot be created is reported, not raised", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      -- A regular file where a directory would have to go: mkdir must fail.
      H.write(dir .. "/blocker", { "not a directory" })
      c.setup({ create_on_missing = { enable = true, confirm = false } })

      local called = false
      local notes = H.capture_notify(function()
        create.offer({ path = dir .. "/blocker/child.lua", exists = false }, function()
          called = true
        end)
      end)
      H.falsy(called, "on_created is not reached")
      H.match(H.notify_text(notes), "Could not create file", "gopath's own wording, not a raw E739")
    end)
  end)

  H.check("offer: the confirm dialog offers Create and Cancel, and cancelling warns", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({ create_on_missing = { enable = true, confirm = true } })

      local asked, called
      local notes = H.capture_notify(function()
        asked = with_dialog("Cancel", function()
          create.offer({ path = dir .. "/declined.lua", exists = false }, function()
            called = true
          end)
        end)
      end)

      H.eq(#asked, 1, "the user was asked once")
      H.same(asked[1].choices, { "Create", "Cancel" }, "no filetree entry without filetree.nvim")
      H.match(asked[1].question, "does not exist", "the question names the problem")
      H.falsy(called, "nothing was opened")
      H.eq(vim.fn.filereadable(dir .. "/declined.lua"), 0, "and nothing was written")
      H.match(H.notify_text(notes), "File not created")
    end)
  end)

  H.check("offer: dismissing the dialog outright counts as declining", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({ create_on_missing = { enable = true, confirm = true } })
      local called
      H.capture_notify(function()
        with_dialog(nil, function()
          create.offer({ path = dir .. "/dismissed.lua", exists = false }, function()
            called = true
          end)
        end)
      end)
      H.falsy(called)
      H.eq(vim.fn.filereadable(dir .. "/dismissed.lua"), 0)
    end)
  end)

  H.check("offer: choosing Create writes the file (parents included) and opens it", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({ create_on_missing = { enable = true, confirm = true } })
      local got
      H.capture_notify(function()
        with_dialog("Create", function()
          create.offer({ path = dir .. "/deep/accepted.lua", exists = false }, function(r)
            got = r
          end)
        end)
      end)
      H.truthy(got, "on_created ran")
      H.eq(got.exists, true)
      H.eq(vim.fn.filereadable(dir .. "/deep/accepted.lua"), 1)
    end)
  end)

  H.check("offer: a failing Create is reported and on_created stays unreached", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      H.write(dir .. "/blocker", { "not a directory" })
      c.setup({ create_on_missing = { enable = true, confirm = true } })
      local called
      local notes = H.capture_notify(function()
        with_dialog("Create", function()
          create.offer({ path = dir .. "/blocker/child.lua", exists = false }, function()
            called = true
          end)
        end)
      end)
      H.falsy(called)
      H.match(H.notify_text(notes), "could not create")
    end)
  end)

  H.check("offer: 'Open in filetree' appears only with filetree.nvim set up", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({ create_on_missing = { enable = true, confirm = true } })

      -- Installed but not set up: the choice must stay hidden.
      H.with_modules({
        filetree = {
          is_initialized = function()
            return false
          end,
          adapter = function()
            return {}
          end,
        },
      }, function()
        local asked
        H.capture_notify(function()
          asked = with_dialog("Cancel", function()
            create.offer({ path = dir .. "/x/y.lua", exists = false }, function() end)
          end)
        end)
        H.same(asked[1].choices, { "Create", "Cancel" }, "setup() not called yet")
      end)

      -- Installed and set up: three choices.
      local rooted = {}
      H.with_modules({
        filetree = {
          is_initialized = function()
            return true
          end,
          adapter = function()
            return {
              set_root = function(d)
                rooted[#rooted + 1] = d
                return true
              end,
            }
          end,
        },
      }, function()
        local asked
        H.capture_notify(function()
          asked = with_dialog("Open in filetree", function()
            create.offer({ path = dir .. "/x/y.lua", exists = false }, function()
              error("on_created must not run for the filetree choice")
            end)
          end)
        end)
        H.same(asked[1].choices, { "Create", "Open in filetree", "Cancel" })
        H.eq(#rooted, 1, "the directory was handed to filetree")
        H.match(
          rooted[1],
          vim.pesc(dir) .. "$",
          "the nearest EXISTING ancestor, not the missing one"
        )
        H.eq(vim.fn.filereadable(dir .. "/x/y.lua"), 0, "and nothing was created")
      end)
    end)
  end)

  H.check("offer: filetree's toggle_at is preferred over set_root", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({ create_on_missing = { enable = true, confirm = true } })
      local toggled, rooted = {}, 0
      H.with_modules({
        filetree = {
          is_initialized = function()
            return true
          end,
          adapter = function()
            return {
              toggle_at = function(side, opts)
                toggled[#toggled + 1] = { side, opts.dir }
                return true
              end,
              set_root = function()
                rooted = rooted + 1
                return true
              end,
            }
          end,
        },
      }, function()
        H.capture_notify(function()
          with_dialog("Open in filetree", function()
            create.offer({ path = dir .. "/gone/y.lua", exists = false }, function() end)
          end)
        end)
      end)
      H.eq(#toggled, 1, "toggle_at was used")
      H.eq(toggled[1][1], "left")
      H.eq(rooted, 0, "set_root is only the fallback")
    end)
  end)

  H.check(
    "offer: the directory prompt prefers ui.kit.confirm over vim.ui.select when ui.nvim is installed",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        c.setup({})
        local asked
        H.with_modules({
          ["ui.kit"] = {
            confirm = function(spec)
              asked = spec
              spec.on_answer("Cancel")
            end,
          },
        }, function()
          local fresh = require("gopath.create")
          H.capture_notify(function()
            H.with_ui_select(nil, function()
              fresh.offer({ path = dir, exists = false }, function() end)
            end)
          end)
          H.truthy(asked, "ui.kit.confirm was used")
          H.same(asked.choices, { "Create file in this folder", "Cancel" })
          H.match(asked.question, "is a directory")
        end, { unload = { "gopath.create" } })
        H.fresh("gopath.create")
      end)
    end
  )

  -- ── gopath.create: res.path is itself an existing directory ───────────────

  H.check(
    "offer: an existing directory offers 'create file here', ignoring create_on_missing.enable",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        c.setup({ create_on_missing = { enable = false } }) -- must not suppress this dialog
        local calls
        local notes = H.capture_notify(function()
          calls = H.with_ui_select("Cancel", function()
            create.offer({ path = dir, exists = false }, function()
              error("on_created must not run for Cancel")
            end)
          end)
        end)
        H.same(calls[1].items, { "Create file in this folder", "Cancel" }, "no filetree entry")
        H.match(calls[1].opts.prompt, "is a directory")
        H.match(H.notify_text(notes), "File not created")
      end)
    end
  )

  H.check("offer: 'Create file in this folder' asks for a name and creates it there", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({})
      local got
      H.with_field(vim.ui, "input", function(_, on_confirm)
        on_confirm("newfile.lua")
      end, function()
        H.capture_notify(function()
          H.with_ui_select("Create file in this folder", function()
            create.offer(
              { path = dir, exists = false, kind = "file", language = "lua" },
              function(r)
                got = r
              end
            )
          end)
        end)
      end)
      H.truthy(got, "on_created ran")
      H.eq(got.path, dir .. "/newfile.lua")
      H.eq(got.exists, true)
      H.eq(got.kind, "file")
      H.eq(got.language, "lua", "unrelated GopathResult fields are preserved")
      H.eq(vim.fn.filereadable(dir .. "/newfile.lua"), 1)
    end)
  end)

  H.check("offer: declining the name prompt creates nothing", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({})
      local called = false
      H.with_field(vim.ui, "input", function(_, on_confirm)
        on_confirm(nil) -- <Esc> in the real prompt
      end, function()
        H.capture_notify(function()
          H.with_ui_select("Create file in this folder", function()
            create.offer({ path = dir, exists = false }, function()
              called = true
            end)
          end)
        end)
      end)
      H.falsy(called)
    end)
  end)

  H.check(
    "offer: a name containing '..' is refused, never escapes the folder (path traversal)",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        c.setup({})
        local called = false
        for _, name in ipairs({ "../escaped.lua", "..\\escaped.lua", "sub/../../escaped.lua" }) do
          H.with_field(vim.ui, "input", function(_, on_confirm)
            on_confirm(name)
          end, function()
            local notes = H.capture_notify(function()
              H.with_ui_select("Create file in this folder", function()
                create.offer({ path = dir, exists = false }, function()
                  called = true
                end)
              end)
            end)
            H.match(H.notify_text(notes), "contains '%.%.'", name)
          end)
        end
        H.falsy(called, "on_created never ran for any of them")
        H.eq(vim.fn.filereadable(dir .. "/../escaped.lua"), 0)
      end)
    end
  )

  H.check("offer: a name with a subdirectory is still honoured (not a traversal)", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      c.setup({})
      local got
      H.with_field(vim.ui, "input", function(_, on_confirm)
        on_confirm("sub/newfile.lua")
      end, function()
        H.capture_notify(function()
          H.with_ui_select("Create file in this folder", function()
            create.offer({ path = dir, exists = false }, function(r)
              got = r
            end)
          end)
        end)
      end)
      H.truthy(got, "on_created ran")
      H.eq(got.path, dir .. "/sub/newfile.lua")
      H.eq(vim.fn.filereadable(dir .. "/sub/newfile.lua"), 1)
    end)
  end)

  H.check(
    "offer: 'Open in filetree' for an existing directory hands it directly to filetree.nvim",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        c.setup({})
        local rooted = {}
        H.with_modules({
          filetree = {
            is_initialized = function()
              return true
            end,
            adapter = function()
              return {
                set_root = function(d)
                  rooted[#rooted + 1] = d
                  return true
                end,
              }
            end,
          },
        }, function()
          local calls
          H.capture_notify(function()
            calls = H.with_ui_select("Open in filetree", function()
              create.offer({ path = dir, exists = false }, function()
                error("on_created must not run for the filetree choice")
              end)
            end)
          end)
          H.same(calls[1].items, { "Create file in this folder", "Open in filetree", "Cancel" })
          H.eq(#rooted, 1)
          H.eq(rooted[1], dir, "the directory itself, not some ancestor of it")
        end)
      end)
    end
  )

  -- ── gopath.open ────────────────────────────────────────────────────────────

  local open = require("gopath.open")

  ---Collaborator doubles for the modules `gopath.open` requires lazily.
  ---`filetree_adapter` (default nil) lets a case opt into a fake adapter
  ---whose `open_reveal` calls are recorded in `calls.filetree`.
  ---@param filetree_adapter table|nil
  ---@return table externals, table calls
  local function open_doubles(filetree_adapter)
    local calls = { open = {}, reveal = {}, pdf = {}, create = {}, filetree = {} }
    return {
      ["gopath.external"] = {
        should_open_externally = function(p)
          return require("gopath.external.helpers.detector").is_external_file(p)
        end,
        open = function(p)
          calls.open[#calls.open + 1] = p
        end,
        reveal = function(p)
          calls.reveal[#calls.reveal + 1] = p
        end,
      },
      ["gopath.external.pdf"] = {
        try_open = function(p)
          calls.pdf[#calls.pdf + 1] = p
          return false
        end,
      },
      ["gopath.create"] = {
        offer = function(res, on_created)
          calls.create[#calls.create + 1] = res.path
          -- Mirrors the real module: the result is marked before it is handed
          -- back, which is what stops `gopath.open`'s recursion.
          res.exists = true
          on_created(res)
        end,
      },
      ["gopath.util.filetree"] = {
        adapter = function()
          if not filetree_adapter then return nil end
          return {
            open_reveal = function(p)
              calls.filetree[#calls.filetree + 1] = p
              return true
            end,
          }
        end,
      },
    },
      calls
  end

  H.check("open: a nil result, or one without a path, does nothing", function()
    local doubles, calls = open_doubles()
    H.with_modules(doubles, function()
      ---@diagnostic disable-next-line: param-type-mismatch
      open.open(nil, "edit")
      ---@diagnostic disable-next-line: missing-fields
      open.open({}, "edit")
      H.eq(#calls.open + #calls.reveal + #calls.create, 0, "no route was taken")
    end)
  end)

  H.check("open: a URL goes to the external opener regardless of its extension", function()
    local doubles, calls = open_doubles()
    H.with_modules(doubles, function()
      open.open({ kind = "url", path = "https://example.com/report.md", exists = true }, "edit")
      open.open({ kind = "url", path = "https://example.com/noext", exists = true }, "tab")
      H.same(calls.open, { "https://example.com/report.md", "https://example.com/noext" })
      H.eq(#calls.create, 0, "a URL is never a create candidate")
    end)
  end)

  H.check("open: explorer mode reveals instead of opening, and refuses a missing path", function()
    local doubles, calls = open_doubles()
    H.with_modules(doubles, function()
      local dir = H.tmpdir()
      local img = H.write(dir .. "/pic.png", { "" })
      open.open({ kind = "file", path = img, exists = true }, "explorer")
      H.same(
        calls.reveal,
        { img },
        "revealed, not launched — even though .png is an external type"
      )
      H.eq(#calls.open, 0)

      local notes = H.capture_notify(function()
        open.open({ kind = "file", path = dir .. "/gone.txt", exists = false }, "explorer")
      end)
      H.eq(#calls.reveal, 1, "nothing more was revealed")
      H.match(H.notify_text(notes), "cannot reveal")
    end)
  end)

  H.check(
    "open: filetree mode reveals in filetree.nvim instead of opening, and refuses a missing path",
    function()
      local doubles, calls = open_doubles({})
      H.with_modules(doubles, function()
        local dir = H.tmpdir()
        local img = H.write(dir .. "/pic.png", { "" })
        open.open({ kind = "file", path = img, exists = true }, "filetree")
        H.same(
          calls.filetree,
          { img },
          "revealed in the tree, not launched -- even though .png is an external type"
        )
        H.eq(#calls.open, 0)

        local notes = H.capture_notify(function()
          open.open({ kind = "file", path = dir .. "/gone.txt", exists = false }, "filetree")
        end)
        H.eq(#calls.filetree, 1, "nothing more was revealed")
        H.match(H.notify_text(notes), "cannot reveal")
      end)
    end
  )

  H.check(
    "open: filetree mode warns instead of erroring when filetree.nvim isn't available",
    function()
      local doubles, calls = open_doubles(nil)
      H.with_modules(doubles, function()
        local dir = H.tmpdir()
        local img = H.write(dir .. "/pic.png", { "" })
        local notes = H.capture_notify(function()
          open.open({ kind = "file", path = img, exists = true }, "filetree")
        end)
        H.eq(#calls.filetree, 0, "nothing to call open_reveal on")
        H.match(H.notify_text(notes), "filetree%.nvim not available")
      end)
    end
  )

  H.check("open: a missing external file is reported, never conjured up", function()
    local doubles, calls = open_doubles()
    H.with_modules(doubles, function()
      local notes = H.capture_notify(function()
        open.open({ kind = "file", path = "/tmp/nope/a.pdf", exists = false }, "edit")
      end)
      H.match(H.notify_text(notes), "File not found: /tmp/nope/a%.pdf")
      H.eq(#calls.create, 0, "an empty .pdf is not a useful thing to create")
      H.eq(#calls.open, 0, "and the OS is not handed a path that is not there")
    end)
  end)

  H.check("open: an existing PDF is offered to the chooser before the system opener", function()
    local doubles, calls = open_doubles()
    H.with_modules(doubles, function()
      local dir = H.tmpdir()
      local pdf = H.write(dir .. "/a.pdf", { "%PDF" })
      open.open({ kind = "file", path = pdf, exists = true }, "edit")
      H.same(calls.pdf, { pdf }, "the chooser was asked first")
      H.same(calls.open, { pdf }, "and declining it falls through to the system opener")
    end)
  end)

  H.check("open: a handled PDF stops there", function()
    local doubles, calls = open_doubles()
    doubles["gopath.external.pdf"].try_open = function(p)
      calls.pdf[#calls.pdf + 1] = p
      return true
    end
    H.with_modules(doubles, function()
      local dir = H.tmpdir()
      local pdf = H.write(dir .. "/b.pdf", { "%PDF" })
      open.open({ kind = "file", path = pdf, exists = true }, "edit")
      H.eq(#calls.pdf, 1)
      H.eq(#calls.open, 0, "the system opener is not also invoked")
    end)
  end)

  H.check(
    "open: a missing ordinary file goes through the create offer and is opened after",
    function()
      local doubles, calls = open_doubles()
      H.with_modules(doubles, function()
        local dir = H.tmpdir()
        local target = dir .. "/made.lua"
        H.write(target, { "-- already there, so the recursive open finds it" })
        open.open({ kind = "file", path = target, exists = false }, "edit")
        H.same(calls.create, { target }, "the offer ran once")
        H.eq(
          vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
          "made.lua",
          "and the file is open"
        )
      end)
    end
  )

  H.check("open: an existing file is edited and the cursor lands on the range", function()
    local doubles = open_doubles()
    H.with_modules(doubles, function()
      local dir = H.tmpdir()
      local file = H.write(dir .. "/jump.lua", { "one", "two", "three", "four" })
      open.open(
        { kind = "file", path = file, exists = true, range = { line = 3, col = 2 } },
        "edit"
      )
      H.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "jump.lua")
      local pos = vim.api.nvim_win_get_cursor(0)
      H.eq(pos[1], 3, "1-based line")
      H.eq(pos[2], 1, "col converted to 0-based")
    end)
  end)

  H.check("open: an out-of-range jump does not break the open", function()
    local doubles = open_doubles()
    H.with_modules(doubles, function()
      local dir = H.tmpdir()
      local file = H.write(dir .. "/short.lua", { "only one line" })
      open.open(
        { kind = "file", path = file, exists = true, range = { line = 999, col = 1 } },
        "edit"
      )
      H.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "short.lua", "still opened")
      H.eq(vim.api.nvim_win_get_cursor(0)[1], 1, "cursor left where it was")
    end)
  end)

  H.check("open: window/vsplit/tab placement each add exactly one container", function()
    local doubles = open_doubles()
    H.with_modules(doubles, function()
      local dir = H.tmpdir()
      local file = H.write(dir .. "/split.lua", { "x" })

      vim.cmd("silent! only")
      local before_wins = #vim.api.nvim_tabpage_list_wins(0)
      open.open({ kind = "file", path = file, exists = true }, "window")
      H.eq(#vim.api.nvim_tabpage_list_wins(0), before_wins + 1, "split added a window")

      vim.cmd("silent! only")
      open.open({ kind = "file", path = file, exists = true }, "vsplit")
      H.eq(#vim.api.nvim_tabpage_list_wins(0), 2, "vsplit added a window")

      vim.cmd("silent! only")
      local tabs = #vim.api.nvim_list_tabpages()
      open.open({ kind = "file", path = file, exists = true }, "tab")
      H.eq(#vim.api.nvim_list_tabpages(), tabs + 1, "tab added a tabpage")
      vim.cmd("silent! tabclose")
      vim.cmd("silent! only")
    end)
  end)

  H.check("open: an unknown mode falls back to plain edit", function()
    local doubles = open_doubles()
    H.with_modules(doubles, function()
      local dir = H.tmpdir()
      local file = H.write(dir .. "/plain.lua", { "x" })
      vim.cmd("silent! only")
      local wins = #vim.api.nvim_tabpage_list_wins(0)
      open.open({ kind = "file", path = file, exists = true }, "nonsense")
      H.eq(#vim.api.nvim_tabpage_list_wins(0), wins, "no window was added")
      H.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "plain.lua")
    end)
  end)

  H.check("open: a path with shell-special characters is escaped, not interpreted", function()
    local doubles = open_doubles()
    H.with_modules(doubles, function()
      local dir = H.tmpdir()
      local file = H.write(dir .. "/a b#c.lua", { "x" })
      open.open({ kind = "file", path = file, exists = true }, "edit")
      H.eq(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        "a b#c.lua",
        "'#' is the alternate-file token in an unescaped :edit"
      )
    end)
  end)

  H.check("open: an unopenable path is reported, not raised", function()
    local doubles = open_doubles()
    H.with_modules(doubles, function()
      local dir = H.tmpdir()
      -- A directory passes `exists ~= false` but cannot be `:edit`ed into a
      -- file buffer; the failure must arrive as a message.
      local notes = H.capture_notify(function()
        H.with_field(vim.cmd, "edit", function()
          error("E325: simulated swap/permission failure")
        end, function()
          open.open({ kind = "file", path = dir .. "/whatever.lua", exists = true }, "edit")
        end)
      end)
      H.match(H.notify_text(notes), "Could not open file")
    end)
  end)
end
