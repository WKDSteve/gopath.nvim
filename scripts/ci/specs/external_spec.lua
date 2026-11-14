-- scripts/ci/specs/external_spec.lua
-- The external-application layer: which paths are handed to the OS
-- (`external.helpers.detector`), how they are handed over
-- (`external.helpers.opener`, `external.helpers.revealer`), and the PDF mode
-- chooser (`external.pdf`).
--
-- NOTHING IS SPAWNED HERE. The opener's `vim.system` and the revealer's
-- `vim.fn.jobstart` are replaced for the duration of each check and the argv
-- they *would* have used is asserted instead — including the Windows-only
-- detail that `explorer.exe` gets backslashes and that `/select,` and the path
-- must stay one argument.

---@param H table
return function(H)
  local detector = require("gopath.external.helpers.detector")
  local external = require("gopath.external")

  -- ── detector ───────────────────────────────────────────────────────────────

  H.check("detector.extensions: the built-in list, plus the user's, lowercased", function()
    local base = detector.extensions()
    H.contains(base, "pdf")
    H.contains(base, "png")
    H.contains(base, "zip")
    H.contains(base, "mp4")
    H.falsy(vim.tbl_contains(base, "lua"), "source files are not externally opened")

    local extended = detector.extensions({ "EPUB", "", 42 })
    H.contains(extended, "epub", "user extension, lowercased")
    H.eq(#extended, #base + 1, "empty strings and non-strings are skipped")
  end)

  H.check("detector.is_external_file: extension match", function()
    H.eq(detector.is_external_file("a/b/report.pdf"), true)
    H.eq(detector.is_external_file("IMAGE.PNG"), true, "case-insensitive")
    H.eq(detector.is_external_file("src/main.lua"), false)
    H.eq(detector.is_external_file("README"), false, "no extension at all")
    H.eq(detector.is_external_file(""), false)
  end)

  H.check("detector.is_external_file: strict URLs count, bare hosts do not", function()
    H.eq(detector.is_external_file("https://example.com"), true)
    H.eq(detector.is_external_file("mailto:a@b.com"), true)
    H.eq(detector.is_external_file("www.example.com"), true)
    H.eq(
      detector.is_external_file("github.com/neovim/neovim"),
      false,
      "a bare host is a URL by intent; the resolver decides that, not this check"
    )
  end)

  H.check("detector.is_external_file: a Windows path is never a URL", function()
    H.eq(detector.is_external_file("C:/src/main.lua"), false, "drive letter is not a scheme")
    H.eq(detector.is_external_file([[C:\docs\report.pdf]]), true, "but the extension still counts")
  end)

  H.check("detector: extra extensions extend rather than replace", function()
    H.eq(detector.is_external_file("book.epub"), false, "not built in")
    H.eq(detector.is_external_file("book.epub", { "epub" }), true, "opted in")
    H.eq(detector.is_external_file("x.pdf", { "epub" }), true, "built-ins still apply")
  end)

  H.check("detector: mail files go to the mail client, never into a buffer", function()
    for _, name in ipairs({ "inbox/case.msg", "case.EML", [[C:\mail\template.oft]] }) do
      H.eq(detector.is_external_file(name), true, name)
    end
    H.contains(detector.extensions(), "msg")
    H.eq(detector.is_external_file("src/msg.lua"), false, "'msg' in the name is not the extension")
    H.eq(
      detector.is_external_file("opts.msgpack"),
      false,
      "nor is an extension that starts with it"
    )
    H.eq(detector.is_external_file("opts.msg_handler"), false, "nor a field name that does")
  end)

  -- ── external.should_open_externally ────────────────────────────────────────

  H.check("should_open_externally reads the live config", function()
    H.config_sandbox(function(c)
      H.eq(external.should_open_externally("x.pdf"), true)
      H.eq(external.should_open_externally(""), false)
      ---@diagnostic disable-next-line: param-type-mismatch
      H.eq(external.should_open_externally(nil), false)

      c.setup({ external = { enable = false } })
      H.eq(external.should_open_externally("x.pdf"), false, "the whole feature is off")

      c.setup({ external = { enable = true, extensions = { "epub" } } })
      H.eq(external.should_open_externally("book.epub"), true, "user extension honoured")
    end)
  end)

  H.check("external.open / external.reveal reject empty targets without spawning", function()
    local spawned = false
    H.with_field(vim, "system", function()
      spawned = true
      error("must not be called")
    end, function()
      H.eq(external.open(""), false)
      ---@diagnostic disable-next-line: param-type-mismatch
      H.eq(external.open(nil), false)
      H.eq(external.reveal(""), false)
      ---@diagnostic disable-next-line: param-type-mismatch
      H.eq(external.reveal(nil), false)
    end)
    H.falsy(spawned, "nothing was started")
  end)

  -- ── opener ─────────────────────────────────────────────────────────────────

  ---What the minimal built-in opener would run on THIS platform.
  ---@param path string
  ---@return string[]
  local function expected_open_argv(path)
    if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
      return { "open", path }
    elseif vim.fn.has("unix") == 1 then
      return { "xdg-open", path }
    end
    return { "explorer.exe", (path:gsub("/", "\\")) }
  end

  H.check("opener: open.nvim takes precedence and gets a 'path=' argument", function()
    local calls = {}
    H.with_modules({
      open = { -- open.nvim's module is `open`
        open = function(handler, arg)
          calls[#calls + 1] = { handler, arg }
        end,
      },
    }, function()
      local opener = require("gopath.external.helpers.opener")
      H.with_field(vim, "system", function()
        error("open.nvim was installed; nothing may be spawned here")
      end, function()
        H.eq(opener.open_with_system("/tmp/a.pdf"), true, "reported as handled")
      end)
      H.eq(#calls, 1, "exactly one delegation")
      H.eq(calls[1][1], "default", "the 'default' handler")
      H.eq(calls[1][2], "path=/tmp/a.pdf", "and the documented argument shape")
    end, { unload = { "gopath.external.helpers.opener" } })
    H.fresh("gopath.external.helpers.opener")
  end)

  H.check("opener: a throwing open.nvim falls through to the built-in chain", function()
    local lib_calls = {}
    H.with_modules({
      open = { -- open.nvim's module is `open`
        open = function()
          error("open.nvim exploded")
        end,
      },
      ["lib.nvim.cross.open_default"] = function(target)
        lib_calls[#lib_calls + 1] = target
        return true
      end,
    }, function()
      local opener = require("gopath.external.helpers.opener")
      local notes = H.capture_notify(function()
        H.eq(opener.open_with_system("/tmp/a.pdf"), true)
      end)
      H.same(lib_calls, { "/tmp/a.pdf" }, "lib.nvim's opener got the target")
      H.match(H.notify_text(notes), "open%.nvim's open%(%) failed", "and the user was told why")
    end, { unload = { "gopath.external.helpers.opener" } })
    H.fresh("gopath.external.helpers.opener")
  end)

  H.check("opener: lib.nvim's opener is tried before the minimal per-OS one", function()
    H.with_modules({
      open = false,
      ["lib.nvim.cross.open_default"] = function()
        return true
      end,
    }, function()
      local opener = require("gopath.external.helpers.opener")
      H.with_field(vim, "system", function()
        error("the minimal fallback must not run when lib.nvim dispatched")
      end, function()
        local notes = H.capture_notify(function()
          H.eq(opener.open_with_system("/tmp/a.png"), true)
        end)
        H.match(H.notify_text(notes), "Opening externally: a%.png", "reports the basename")
      end)
    end, { unload = { "gopath.external.helpers.opener" } })
    H.fresh("gopath.external.helpers.opener")
  end)

  H.check(
    "opener: a lib.nvim opener that cannot dispatch falls back to the minimal argv",
    function()
      local argv
      H.with_modules({
        open = false,
        ["lib.nvim.cross.open_default"] = function()
          return false
        end,
      }, function()
        local opener = require("gopath.external.helpers.opener")
        H.with_field(vim, "system", function(cmd)
          argv = cmd
          return { pid = 1 }
        end, function()
          local notes = H.capture_notify(function()
            H.eq(opener.open_with_system("/tmp/dir/a.pdf"), true)
          end)
          H.match(H.notify_text(notes), "failed to dispatch", "the user is told it degraded")
        end)
        local want = expected_open_argv("/tmp/dir/a.pdf")
        H.eq(argv[1], want[1], "the binary the OS would have been asked for")
        H.eq(argv[2], want[2], "and the target, in native separators")
      end, { unload = { "gopath.external.helpers.opener" } })
      H.fresh("gopath.external.helpers.opener")
    end
  )

  H.check("opener: without lib.nvim at all, the minimal per-OS argv is used directly", function()
    local argv, opts
    H.with_modules({
      open = false,
      ["lib.nvim.cross.open_default"] = false,
    }, function()
      local opener = require("gopath.external.helpers.opener")
      H.with_field(vim, "system", function(cmd, o)
        argv, opts = cmd, o
        return { pid = 1 }
      end, function()
        H.eq(opener.open_with_system("/tmp/x/report.pdf"), true)
      end)
      local want = expected_open_argv("/tmp/x/report.pdf")
      H.eq(argv[1], want[1], "binary")
      H.eq(argv[2], want[2], "target")
      H.eq(opts.text, true, "text mode, so stderr is readable in the on_exit callback")
      H.is_nil(opts.detach, "never detached: on Windows that stops a console child from running")
    end, { unload = { "gopath.external.helpers.opener" } })
    H.fresh("gopath.external.helpers.opener")
  end)

  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    H.check("opener (Windows): explorer.exe receives a backslash path, not a mixed one", function()
      local argv
      H.with_modules({ open = false, ["lib.nvim.cross.open_default"] = false }, function()
        local opener = require("gopath.external.helpers.opener")
        H.with_field(vim, "system", function(cmd)
          argv = cmd
          return { pid = 1 }
        end, function()
          opener.open_with_system("C:/Users/me/My Docs/a & b.pdf")
        end)
        H.eq(argv[1], "explorer.exe", "not 'cmd /c start', which would split on the '&'")
        H.eq(argv[2], [[C:\Users\me\My Docs\a & b.pdf]], "one argument, native separators")
      end, { unload = { "gopath.external.helpers.opener" } })
      H.fresh("gopath.external.helpers.opener")
    end)

    H.check(
      "BUG (Windows): the minimal opener appends gsub's replacement count as an argument",
      function()
        -- `cmd = { "explorer.exe", path:gsub("/", "\\") }` — an unparenthesised
        -- gsub is a multi-value expression, and in the LAST slot of a table
        -- constructor both of its return values land in the table. explorer.exe
        -- is therefore invoked as `explorer.exe <path> <number-of-separators>`.
        --
        -- Windows-only (the mac/linux branches pass `path` through unchanged)
        -- and fallback-only (it is reached only when neither open.nvim nor
        -- lib.nvim is installed). The sibling revealer.lua writes the same gsub
        -- inside a concatenation, which truncates it to one value, and is fine.
        local argv
        H.with_modules({ open = false, ["lib.nvim.cross.open_default"] = false }, function()
          local opener = require("gopath.external.helpers.opener")
          H.with_field(vim, "system", function(cmd)
            argv = cmd
            return { pid = 1 }
          end, function()
            opener.open_with_system("C:/a/b/c.pdf")
          end)
        end, { unload = { "gopath.external.helpers.opener" } })
        H.fresh("gopath.external.helpers.opener")

        H.eq(#argv, 3, "BUG: three arguments where two were meant")
        H.eq(argv[3], 3, "BUG: the count of replaced separators, passed to explorer.exe")
      end
    )
  end

  H.check("opener: a vim.system that throws is reported, not propagated", function()
    H.with_modules({ open = false, ["lib.nvim.cross.open_default"] = false }, function()
      local opener = require("gopath.external.helpers.opener")
      H.with_field(vim, "system", function()
        error("spawn refused")
      end, function()
        local notes = H.capture_notify(function()
          H.eq(opener.open_with_system("/tmp/a.pdf"), false, "reported as not handled")
        end)
        H.match(
          H.notify_text(notes),
          "Failed to start external opener",
          "with gopath's own wording"
        )
      end)
    end, { unload = { "gopath.external.helpers.opener" } })
    H.fresh("gopath.external.helpers.opener")
  end)

  -- ── revealer ───────────────────────────────────────────────────────────────

  ---What the minimal built-in revealer would run on THIS platform.
  ---@param path string
  ---@return string[]
  local function expected_reveal_argv(path)
    if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
      return { "open", "-R", path }
    elseif vim.fn.has("unix") == 1 then
      return { "xdg-open", vim.fn.fnamemodify(path, ":h") }
    end
    return { "explorer.exe", "/select," .. path:gsub("/", "\\") }
  end

  ---Replace `vim.fn.jobstart` while `fn` runs; returns the argv it saw.
  ---@param job_id integer
  ---@param fn fun()
  ---@return string[]|nil argv, table|nil opts
  local function with_jobstart(job_id, fn)
    local argv, opts
    local saved = rawget(vim.fn, "jobstart")
    vim.fn.jobstart = function(cmd, o)
      argv, opts = cmd, o
      return job_id
    end
    local ok, err = pcall(fn)
    vim.fn.jobstart = saved
    if not ok then error(err, 0) end
    return argv, opts
  end

  H.check("revealer: lib.nvim's reveal_in_fm is preferred and nothing is spawned", function()
    local targets = {}
    H.with_modules({
      ["lib.nvim.cross.reveal_in_fm"] = function(target)
        targets[#targets + 1] = target
        return true
      end,
    }, function()
      local revealer = require("gopath.external.helpers.revealer")
      local argv = with_jobstart(1, function()
        local notes = H.capture_notify(function()
          H.eq(revealer.reveal("/tmp/dir/a.txt"), true)
        end)
        H.match(H.notify_text(notes), "Revealing in file manager: a%.txt")
      end)
      H.is_nil(argv, "no process was started")
      H.same(targets, { "/tmp/dir/a.txt" })
    end, { unload = { "gopath.external.helpers.revealer" } })
    H.fresh("gopath.external.helpers.revealer")
  end)

  H.check("revealer: a failing reveal_in_fm degrades to the minimal per-OS argv", function()
    H.with_modules({
      ["lib.nvim.cross.reveal_in_fm"] = function()
        return false, "no file manager"
      end,
    }, function()
      local revealer = require("gopath.external.helpers.revealer")
      local argv
      local notes = H.capture_notify(function()
        argv = with_jobstart(7, function()
          H.eq(revealer.reveal("/tmp/dir/a.txt"), true)
        end)
      end)
      H.same(argv, expected_reveal_argv("/tmp/dir/a.txt"), "the argv the OS would have received")
      H.match(H.notify_text(notes), "reveal_in_fm failed", "the degradation is reported")
    end, { unload = { "gopath.external.helpers.revealer" } })
    H.fresh("gopath.external.helpers.revealer")
  end)

  H.check("revealer: without lib.nvim, and a refused job, failure is reported", function()
    H.with_modules({ ["lib.nvim.cross.reveal_in_fm"] = false }, function()
      local revealer = require("gopath.external.helpers.revealer")
      local notes = H.capture_notify(function()
        with_jobstart(-1, function()
          H.eq(revealer.reveal("/tmp/dir/a.txt"), false, "a non-positive job id is a failure")
        end)
      end)
      H.match(H.notify_text(notes), "Failed to start file manager")
    end, { unload = { "gopath.external.helpers.revealer" } })
    H.fresh("gopath.external.helpers.revealer")
  end)

  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    H.check("revealer (Windows): '/select,' and the path stay one argument", function()
      H.with_modules({ ["lib.nvim.cross.reveal_in_fm"] = false }, function()
        local revealer = require("gopath.external.helpers.revealer")
        local argv = with_jobstart(3, function()
          H.capture_notify(function()
            revealer.reveal("C:/Users/me/a.txt")
          end)
        end)
        H.eq(#argv, 2, "two arguments, not three")
        H.eq(argv[2], [[/select,C:\Users\me\a.txt]], "no space after the comma")
      end, { unload = { "gopath.external.helpers.revealer" } })
      H.fresh("gopath.external.helpers.revealer")
    end)
  end

  -- ── pdf chooser ────────────────────────────────────────────────────────────

  local pdf = require("gopath.external.pdf")

  H.check("pdf.is_pdf", function()
    H.eq(pdf.is_pdf("a/b.pdf"), true)
    H.eq(pdf.is_pdf("A/B.PDF"), true, "case-insensitive")
    H.eq(pdf.is_pdf([[C:\docs\x.pdf]]), true)
    H.eq(pdf.is_pdf("a/b.png"), false)
    H.eq(pdf.is_pdf(""), false)
    ---@diagnostic disable-next-line: param-type-mismatch
    H.eq(pdf.is_pdf(nil), false)
  end)

  H.check(
    "pdf.try_open: without pdfport.nvim nothing is offered and the caller falls back",
    function()
      H.with_modules({ pdfport = false }, function()
        H.eq(pdf.available(), false)
        H.eq(pdf.try_open("/tmp/a.pdf"), false, "unhandled → caller uses the system opener")
        H.eq(pdf.try_open("/tmp/a.png"), false, "not a PDF at all")
      end)
    end
  )

  H.check("pdf.try_open: picker = false dispatches the configured default", function()
    local opened = {}
    H.config_sandbox(function(c)
      c.setup({ external = { pdf = { picker = false, default = "float" } } })
      H.with_modules({
        pdfport = {
          open = function(o)
            opened[#opened + 1] = o
          end,
        },
      }, function()
        H.eq(pdf.available(), true)
        H.eq(pdf.try_open("/tmp/a.pdf"), true, "handled")
      end)
      H.eq(#opened, 1)
      H.eq(opened[1].mode, "float")
      H.eq(opened[1].path, "/tmp/a.pdf")
    end)
  end)

  H.check(
    "pdf.try_open: default = 'system' goes through gopath's own opener, not pdfport's",
    function()
      local pdfport_calls, opener_calls = 0, {}
      H.config_sandbox(function(c)
        c.setup({ external = { pdf = { picker = false, default = "system" } } })
        H.with_modules({
          pdfport = {
            open = function()
              pdfport_calls = pdfport_calls + 1
            end,
          },
          ["gopath.external"] = {
            open = function(p)
              opener_calls[#opener_calls + 1] = p
            end,
          },
        }, function()
          H.eq(pdf.try_open("/tmp/a.pdf"), true)
        end)
        H.eq(pdfport_calls, 0, "pdfport's own 'system' renderer is deliberately not used")
        H.same(opener_calls, { "/tmp/a.pdf" })
      end)
    end
  )

  H.check("pdf.try_open: a throwing pdfport falls back to the system app and says so", function()
    local opener_calls = {}
    H.config_sandbox(function(c)
      c.setup({ external = { pdf = { picker = false, default = "buffer" } } })
      H.with_modules({
        pdfport = {
          open = function()
            error("renderer unavailable")
          end,
        },
        ["gopath.external"] = {
          open = function(p)
            opener_calls[#opener_calls + 1] = p
          end,
        },
      }, function()
        local notes = H.capture_notify(function()
          H.eq(pdf.try_open("/tmp/a.pdf"), true)
        end)
        H.match(H.notify_text(notes), "pdfport failed", "reported")
        H.match(H.notify_text(notes), "falling back to system app")
      end)
      H.same(opener_calls, { "/tmp/a.pdf" })
    end)
  end)

  -- ── image chooser ──────────────────────────────────────────────────────────

  local images = require("gopath.external.images")

  H.check("images.is_image: the formats images.nvim draws", function()
    H.eq(images.is_image("a/b.png"), true)
    H.eq(images.is_image("A/B.JPG"), true, "case-insensitive")
    H.eq(images.is_image("x.svg"), true)
    H.eq(images.is_image("x.tiff"), false, "not drawn by images.nvim: the system viewer keeps it")
    H.eq(images.is_image("x.pdf"), false)
    H.eq(images.is_image(""), false)
    H.eq(images.is_image(nil), false)
  end)

  H.check("images.try_open: without images.nvim nothing is offered", function()
    H.with_modules({ images = false }, function()
      H.eq(images.available(), false)
      H.eq(images.try_open("/tmp/a.png"), false, "unhandled -> caller uses the system opener")
      H.eq(images.try_open("/tmp/a.pdf"), false, "not an image at all")
    end)
  end)

  H.check("images.try_open: picker = false dispatches the configured default", function()
    local shown = {}
    H.config_sandbox(function(c)
      c.setup({ external = { images = { picker = false, default = "zen" } } })
      H.with_modules({
        images = {
          show = function() end,
          zen = function(p)
            shown[#shown + 1] = p
          end,
        },
      }, function()
        H.eq(images.available(), true)
        H.eq(images.try_open("/tmp/a.png"), true, "handled")
      end)
      H.same(shown, { "/tmp/a.png" })
    end)
  end)

  H.check("images.try_open: optout = true never offers images.nvim", function()
    H.config_sandbox(function(c)
      c.setup({ external = { images = { optout = true } } })
      H.with_modules({ images = { show = function() end } }, function()
        H.eq(images.try_open("/tmp/a.png"), false, "falls through to the system opener")
      end)
    end)
  end)

  H.check("images.try_open: default = 'system' goes through gopath's own opener", function()
    local images_calls, opener_calls = 0, {}
    H.config_sandbox(function(c)
      c.setup({ external = { images = { picker = false, default = "system" } } })
      H.with_modules({
        images = {
          show = function()
            images_calls = images_calls + 1
          end,
        },
        ["gopath.external"] = {
          open = function(p)
            opener_calls[#opener_calls + 1] = p
          end,
        },
      }, function()
        H.eq(images.try_open("/tmp/a.png"), true)
      end)
      H.eq(images_calls, 0)
      H.same(opener_calls, { "/tmp/a.png" })
    end)
  end)

  H.check(
    "images.try_open: a throwing images.nvim falls back to the system app and says so",
    function()
      local opener_calls = {}
      H.config_sandbox(function(c)
        c.setup({ external = { images = { picker = false, default = "show" } } })
        H.with_modules({
          images = {
            show = function()
              error("no terminal")
            end,
          },
          ["gopath.external"] = {
            open = function(p)
              opener_calls[#opener_calls + 1] = p
            end,
          },
        }, function()
          local notes = H.capture_notify(function()
            H.eq(images.try_open("/tmp/a.png"), true)
          end)
          H.match(H.notify_text(notes), "images.nvim failed", "reported")
        end)
        H.same(opener_calls, { "/tmp/a.png" })
      end)
    end
  )

  H.check(
    "images.try_open: with the picker on, ui.kit is offered system first, then the terminal views",
    function()
      local shown
      local dispatched = {}
      H.config_sandbox(function(c)
        c.setup({ external = { images = { picker = true } } })
        H.with_modules({
          images = {
            show = function(p)
              dispatched[#dispatched + 1] = "show:" .. p
            end,
            zen = function() end,
          },
          ["ui.kit"] = {
            select = function(spec)
              shown = spec
            end,
          },
        }, function()
          H.eq(images.try_open("/tmp/docs/a.png"), true, "handled: the chooser is up")
          H.truthy(shown, "ui.kit.select was called")
          H.eq(#shown.items, 3)
          H.eq(shown.items[1].mode, "system", "the exception stays one keystroke away")
          H.match(shown.title, "a.png")
          shown.on_select(shown.items[2])
        end)
        H.same(dispatched, { "show:/tmp/docs/a.png" }, "picking 'inline' draws through images.show")
      end)
    end
  )

  H.check(
    "pdf.try_open: with the picker on, ui.kit is offered the four modes, system first",
    function()
      local shown
      H.config_sandbox(function(c)
        c.setup({ external = { pdf = { picker = true } } })
        H.with_modules({
          pdfport = { open = function() end },
          ["ui.kit"] = {
            select = function(spec)
              shown = spec
            end,
          },
        }, function()
          H.eq(pdf.try_open("/tmp/docs/report.pdf"), true, "handled: the chooser is up")
        end)
        H.truthy(shown, "ui.kit.select was called")
        H.eq(#shown.items, 4)
        H.eq(shown.items[1].mode, "system", "the exception stays one keystroke away")
        H.eq(shown.format_item(shown.items[1]), "System app")
        H.same(
          vim.tbl_map(function(i)
            return i.mode
          end, shown.items),
          { "system", "buffer", "float", "terminal" }
        )
        H.match(shown.title, "report%.pdf", "the title names the file")
        H.eq(type(shown.on_cancel), "function", "cancelling means never mind, not open anyway")
      end)
    end
  )

  H.check("pdf.try_open: picking a mode from the chooser dispatches it", function()
    local opened = {}
    H.config_sandbox(function(c)
      c.setup({ external = { pdf = { picker = true } } })
      H.with_modules({
        pdfport = {
          open = function(o)
            opened[#opened + 1] = o
          end,
        },
        ["ui.kit"] = {
          select = function(spec)
            spec.on_select(spec.items[3]) -- "float"
          end,
        },
      }, function()
        pdf.try_open("/tmp/a.pdf")
      end)
      H.eq(#opened, 1)
      H.eq(opened[1].mode, "float")
    end)
  end)

  H.check("pdf.try_open: without ui.nvim the picker is skipped rather than guessed", function()
    H.config_sandbox(function(c)
      c.setup({ external = { pdf = { picker = true } } })
      H.with_modules({ pdfport = { open = function() end }, ["ui.kit"] = false }, function()
        H.eq(pdf.try_open("/tmp/a.pdf"), false, "unhandled → the pre-pdfport behaviour")
      end)
    end)
  end)
end
