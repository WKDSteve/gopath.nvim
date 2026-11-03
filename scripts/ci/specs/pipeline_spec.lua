-- scripts/ci/specs/pipeline_spec.lua
-- gopath.registry (per-language dispatch) and gopath.resolve (the ordered
-- pipeline every keymap and command funnels through).
--
-- `gopath.resolve` requires each resolver lazily inside `resolve_at_cursor`,
-- so the order of the phases can be observed by substituting them one at a
-- time and recording which ones were consulted.

---@param H table
return function(H)
  -- ── registry ───────────────────────────────────────────────────────────────

  local registry = require("gopath.registry")

  H.check("available_resolvers: sorted names per filetype, empty for unknown ones", function()
    local lua_names = registry.available_resolvers("lua")
    H.contains(lua_names, "require_path")
    H.contains(lua_names, "symbol_locator")
    H.contains(lua_names, "value_origin")
    local sorted = vim.deepcopy(lua_names)
    table.sort(sorted)
    H.same(lua_names, sorted, "sorted, so the debug output is stable")

    H.same(registry.available_resolvers("python"), { "import_path" })
    H.same(registry.available_resolvers("cpp"), { "include_path" })
    H.same(registry.available_resolvers("markdown"), {}, "a filetype with no language resolvers")
  end)

  H.check("run_language_pipeline: gated on the language config and on a known filetype", function()
    H.config_sandbox(function(c)
      H.is_nil(registry.run_language_pipeline("markdown", "builtin"), "no RES entry")

      c.setup({ languages = { python = { enable = false } } })
      H.is_nil(registry.run_language_pipeline("python", "builtin"), "explicitly disabled")

      c.setup({ languages = { python = { enable = true } } })
      H.buf({ "x = 1" }, { filetype = "python" })
      H.is_nil(registry.run_language_pipeline("python", "no-such-provider"), "unknown provider")
    end)
  end)

  H.check("run_language_pipeline: a custom resolver runs before the built-ins", function()
    H.config_sandbox(function(c)
      local sentinel = { kind = "file", path = "/from/custom", exists = true }
      c.setup({
        languages = {
          python = {
            enable = true,
            custom_resolvers = {
              {
                resolve = function()
                  return sentinel
                end,
              },
            },
          },
        },
      })
      H.buf({ "import os" }, { filetype = "python" })
      H.eq(registry.run_language_pipeline("python", "builtin"), sentinel)
    end)
  end)

  H.check("run_language_pipeline: a custom resolver may be named as a module string", function()
    H.config_sandbox(function(c)
      local sentinel = { kind = "file", path = "/from/named", exists = true }
      H.with_modules({
        ["spec.custom.resolver"] = {
          resolve = function()
            return sentinel
          end,
        },
      }, function()
        c.setup({
          languages = { python = { enable = true, custom_resolvers = { "spec.custom.resolver" } } },
        })
        H.buf({ "import os" }, { filetype = "python" })
        H.eq(registry.run_language_pipeline("python", "builtin"), sentinel)
      end)
    end)
  end)

  H.check("run_language_pipeline: custom resolvers are tried in order and may decline", function()
    H.config_sandbox(function(c)
      local order = {}
      local sentinel = { kind = "file", path = "/second", exists = true }
      c.setup({
        languages = {
          python = {
            enable = true,
            custom_resolvers = {
              {
                resolve = function()
                  order[#order + 1] = "first"
                  return nil
                end,
              },
              {
                resolve = function()
                  order[#order + 1] = "second"
                  return sentinel
                end,
              },
              {
                resolve = function()
                  order[#order + 1] = "third"
                  return { path = "/never" }
                end,
              },
            },
          },
        },
      })
      H.buf({ "import os" }, { filetype = "python" })
      H.eq(registry.run_language_pipeline("python", "builtin"), sentinel)
      H.same(order, { "first", "second" }, "stops at the first one that answers")
    end)
  end)

  H.check("run_language_pipeline: a throwing or malformed custom resolver is skipped", function()
    H.config_sandbox(function(c)
      local sentinel = { kind = "file", path = "/survivor", exists = true }
      c.setup({
        languages = {
          python = {
            enable = true,
            custom_resolvers = {
              "no.such.module.at.all",
              { not_a_resolver = true },
              42,
              {
                resolve = function()
                  error("custom resolver exploded")
                end,
              },
              {
                resolve = function()
                  return sentinel
                end,
              },
            },
          },
        },
      })
      H.buf({ "import os" }, { filetype = "python" })
      H.eq(registry.run_language_pipeline("python", "builtin"), sentinel, "the survivor answered")
    end)
  end)

  H.check("run_language_pipeline: `resolvers` restricts which built-ins run", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir()
      H.write(dir .. "/pkg/mod.py", { "" })
      local main = H.write(dir .. "/main.py", { "import pkg.mod" })
      vim.cmd.edit(vim.fn.fnameescape(main))
      vim.bo.filetype = "python"
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      c.setup({ languages = { python = { enable = true, resolvers = nil } } })
      H.truthy(registry.run_language_pipeline("python", "builtin"), "nil means all of them")

      c.setup({ languages = { python = { enable = true, resolvers = { "something_else" } } } })
      H.is_nil(
        registry.run_language_pipeline("python", "builtin"),
        "import_path was not in the allow-list"
      )
    end)
  end)

  H.check("run_language_pipeline: the treesitter pass answers a help token first", function()
    H.config_sandbox(function(c)
      c.setup({ languages = { lua = { enable = true } } })
      H.line_at("vim.api.nvim_buf_set_lines(0)", "nvim_buf", { filetype = "lua" })
      local r = registry.run_language_pipeline("lua", "treesitter")
      H.truthy(r, "expected a result")
      H.eq(r.kind, "help", "the help resolver pre-empts the Lua resolvers")
    end)
  end)

  -- ── resolve: the ordered pipeline ──────────────────────────────────────────

  ---Build a set of stand-in resolver modules that record when they were asked.
  ---@param answers table<string, any>  module short name -> result or nil
  ---@return table replacements, string[] asked
  local function phases(answers)
    local asked = {}
    ---@param name string
    ---@return fun(): any
    local function probe(name)
      return function()
        asked[#asked + 1] = name
        return answers[name]
      end
    end
    return {
      ["gopath.resolvers.common.help"] = { resolve = probe("help") },
      ["gopath.resolvers.common.url"] = {
        resolve_strict = probe("url-strict"),
        resolve_loose = probe("url-loose"),
      },
      ["gopath.resolvers.common.env_path"] = { resolve = probe("env") },
      ["gopath.resolvers.common.filetoken"] = { resolve = probe("filetoken") },
      ["gopath.resolvers.common.linepath"] = { resolve = probe("linepath") },
      ["gopath.registry"] = {
        run_language_pipeline = function(_, provider)
          asked[#asked + 1] = "lang:" .. provider
          return answers["lang:" .. provider]
        end,
        available_resolvers = function()
          return {}
        end,
      },
    },
      asked
  end

  ---Run the pipeline against substituted phases.
  ---@param answers table<string, any>
  ---@param opts table|nil
  ---@return any result, any err, string[] asked
  local function run(answers, opts)
    local replacements, asked = phases(answers)
    local result, err
    H.with_modules(replacements, function()
      local resolve = require("gopath.resolve")
      result, err = resolve.resolve_at_cursor(opts)
    end, { unload = { "gopath.resolve" } })
    H.fresh("gopath.resolve")
    return result, err, asked
  end

  H.check("resolve: help is asked first and short-circuits everything", function()
    H.line_at("nothing special", "nothing", { filetype = "lua" })
    local hit = { kind = "help", subject = "vim" }
    local r, err, asked = run({ help = hit })
    H.eq(r, hit)
    H.is_nil(err)
    H.same(asked, { "help" }, "nothing else was consulted")
  end)

  H.check("resolve: a strict URL pre-empts every file resolver", function()
    H.line_at("see https://x.com", "https", { filetype = "markdown" })
    local hit = { kind = "url", path = "https://x.com", exists = true }
    local r, _, asked = run({ ["url-strict"] = hit })
    H.eq(r, hit)
    H.same(asked, { "help", "url-strict" }, "before env, filetoken and linepath")
  end)

  H.check("resolve: env_path runs before filetoken so a $VAR is never cwd-joined", function()
    H.line_at("see $VAR/x.md", "VAR", { filetype = "text" })
    local hit = { kind = "file", path = "/expanded/x.md", exists = true }
    local r, _, asked = run({ env = hit })
    H.eq(r, hit)
    H.same(asked, { "help", "url-strict", "env" })
  end)

  H.check("resolve: a confident, existing filetoken hit is returned immediately", function()
    H.line_at("see a/b.lua", "a/b", { filetype = "lua" })
    local hit = { kind = "module", path = "/a/b.lua", exists = true, confidence = 0.75 }
    local r, _, asked = run({ filetoken = hit })
    H.eq(r, hit)
    H.same(asked, { "help", "url-strict", "env", "filetoken" }, "linepath was not needed")
  end)

  H.check("resolve: a weak filetoken hit is held back as a fallback, not returned", function()
    H.line_at("see a/b.lua", "a/b", { filetype = "lua" })
    local weak = { kind = "file", path = "/a/b.lua", exists = false, confidence = 0.3 }
    local r, _, asked = run({ filetoken = weak })
    H.eq(r, weak, "it does come back, but only after everything else declined")
    H.contains(asked, "linepath", "linepath still ran")
    H.contains(asked, "lang:lsp", "and so did the language pipeline")
    H.contains(asked, "url-loose", "and the loose URL pass")
    H.eq(asked[#asked], "url-loose", "the fallback is used after the last phase, not instead of it")
  end)

  H.check("resolve: an existing-but-unconfident filetoken hit is also held back", function()
    H.line_at("see a/b.lua", "a/b", { filetype = "lua" })
    local weak = { kind = "file", path = "/a/b.lua", exists = true, confidence = 0.4 }
    local r, _, asked = run({ filetoken = weak })
    H.eq(r, weak)
    H.contains(asked, "linepath", "confidence below 0.6 is not enough to short-circuit")
  end)

  H.check("resolve: linepath sits between filetoken and the language pipeline", function()
    H.line_at("Error in a/b.lua:3", "Error", { filetype = "lua" })
    local hit = { kind = "file", path = "/a/b.lua", exists = true }
    local r, _, asked = run({ linepath = hit })
    H.eq(r, hit)
    H.same(asked, { "help", "url-strict", "env", "filetoken", "linepath" })
  end)

  H.check("resolve: linepath.cascade = false skips the whole-line pass", function()
    H.config_sandbox(function(c)
      c.setup({ linepath = { cascade = false } })
      H.line_at("Error in a/b.lua:3", "Error", { filetype = "lua" })
      local _, _, asked = run({})
      H.falsy(vim.tbl_contains(asked, "linepath"), "not consulted")
    end)
  end)

  H.check("resolve: the provider order is lsp → treesitter → builtin by default", function()
    H.line_at("x", "x", { filetype = "lua" })
    local hit = { kind = "module", path = "/x.lua", exists = true }
    local r, _, asked = run({ ["lang:builtin"] = hit })
    H.eq(r, hit)
    H.contains(asked, "lang:lsp")
    H.contains(asked, "lang:treesitter")
    H.contains(asked, "lang:builtin")
    H.eq(asked[#asked - 2], "lang:lsp", "in that order")
    H.eq(asked[#asked - 1], "lang:treesitter")
    H.eq(asked[#asked], "lang:builtin")
  end)

  H.check("resolve: mode pins the pipeline to a single provider", function()
    H.config_sandbox(function(c)
      for _, mode in ipairs({ "lsp", "treesitter", "builtin" }) do
        c.setup({ mode = mode })
        H.line_at("x", "x", { filetype = "lua" })
        local _, _, asked = run({})
        local providers = vim.tbl_filter(function(name)
          return name:match("^lang:")
        end, asked)
        H.same(providers, { "lang:" .. mode }, "mode = " .. mode)
      end
    end)
  end)

  H.check("resolve: opts.order overrides the configured order in hybrid mode", function()
    H.line_at("x", "x", { filetype = "lua" })
    local _, _, asked = run({}, { order = { "builtin" } })
    local providers = vim.tbl_filter(function(name)
      return name:match("^lang:")
    end, asked)
    H.same(providers, { "lang:builtin" })
  end)

  H.check("resolve: a disabled language stops before the pipeline and says why", function()
    H.config_sandbox(function(c)
      c.setup({ languages = { lua = { enable = false } } })
      H.line_at("x", "x", { filetype = "lua" })
      local r, err, asked = run({})
      H.is_nil(r, "no fallback was held")
      H.eq(err, "language-disabled")
      H.falsy(vim.tbl_contains(asked, "lang:lsp"), "no provider ran")

      local weak = { kind = "file", path = "/a.lua", exists = false, confidence = 0.3 }
      local r2, err2 = run({ filetoken = weak })
      H.eq(r2, weak, "a held filetoken fallback is still handed back")
      H.eq(err2, "language-disabled")
    end)
  end)

  H.check("resolve: an unknown filetype skips the language pipeline entirely", function()
    H.line_at("x", "x", { filetype = "markdown" })
    local _, _, asked = run({})
    H.falsy(vim.tbl_contains(asked, "lang:lsp"), "markdown has no languages entry")
    H.contains(asked, "url-loose", "but the later phases still run")
  end)

  H.check("resolve: the loose URL pass runs only after every file resolver failed", function()
    H.line_at("clone github.com/a/b", "github", { filetype = "lua" })
    local hit = { kind = "url", path = "https://github.com/a/b", exists = true }
    local r, _, asked = run({ ["url-loose"] = hit })
    H.eq(r, hit)
    H.eq(asked[#asked], "url-loose", "last of the resolvers")
    H.contains(asked, "lang:builtin", "the language pipeline had its chance first")
  end)

  H.check(
    "resolve: a throwing provider does not abort the pipeline, and is logged (LLS-31)",
    function()
      H.config_sandbox(function(c)
        c.setup({ dev_mode = true })
        H.line_at("x", "x", { filetype = "lua" })
        local replacements, asked = phases({})
        replacements["gopath.registry"].run_language_pipeline = function(_, provider)
          asked[#asked + 1] = "lang:" .. provider
          error("provider " .. provider .. " exploded")
        end
        local result
        local notes = H.capture_notify(function()
          H.with_modules(replacements, function()
            local resolve = require("gopath.resolve")
            result = resolve.resolve_at_cursor({})
          end, { unload = { "gopath.resolve" } })
        end)
        H.fresh("gopath.resolve")
        H.contains(asked, "lang:builtin", "all three were still tried")
        H.contains(asked, "url-loose", "and the phases after them too")
        H.truthy(result, "and the run still ended in the <cfile> fallback rather than an error")
        H.eq(result.source, "builtin-fallback")

        -- `safe.call` used to discard the traceback entirely -- not even
        -- dev_mode surfaced it, so a resolver could stay broken indefinitely
        -- with the pipeline quietly degrading to a weaker guess every time.
        local text = H.notify_text(notes)
        H.match(text, "lsp resolver failed for filetype 'lua'", "the crash is no longer silent")
        H.match(text, "exploded", "the original error survives, not just a generic message")
      end)
    end
  )

  H.check("resolve: <cfile> is the last resort, and answers 'no-match' when empty", function()
    H.line_at("see some/token.xyz here", "some", { filetype = "lua" })
    local r, err = run({})
    H.truthy(r, "expected the raw-cfile fallback")
    H.eq(r.source, "builtin-fallback")
    H.eq(r.confidence, 0.5)
    H.eq(r.exists, false, "nothing claims it is there")
    H.eq(r.language, "lua", "carries the buffer's filetype")
    H.is_nil(err)

    H.line_at("", "", { filetype = "lua" })
    local none, no_err = run({})
    H.is_nil(none, "an empty line has no <cfile> either")
    H.eq(no_err, "no-match")
  end)

  H.check("resolve: the pre-language stages are one ordered list the probe can report", function()
    H.same(require("gopath.resolve").stage_names(), {
      "help",
      "url_strict",
      "env_path",
      "task_id",
      "commit_file",
      "commit",
      "filetoken",
      "linepath",
    }, "the order the header documents")
  end)
end
