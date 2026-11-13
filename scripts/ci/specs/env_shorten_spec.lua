-- scripts/ci/specs/env_shorten_spec.lua
-- gopath.env_shorten: rewrite an absolute path on the current line whose root
-- segment is a configured directory name back into a `$VAR` reference.
--
-- The property under test is that the match is *structural*, not literal: it
-- must not consult the actual value of $REPOS_DIR, so the same text rewrites
-- identically on a Windows drive, a POSIX root, a `~`-relative path, or with
-- no root marker at all. TESTS/06_env_shorten.lua is the manual guide for the
-- same ten cases; these are the assertions.

---@param H table
return function(H)
  local ES = require("gopath.env_shorten")

  local PAIRS = { { segment = "repos", var = "REPOS_DIR" } }

  ---@param line string
  ---@return string result, integer count
  local function shorten(line)
    return ES.shorten(line, PAIRS)
  end

  -- ── shorten_path: one absolute path, the API behind `:Image paste env` ──────

  H.check("shorten_path: structural repos root, either slash style, any drive", function()
    H.eq(ES.shorten_path([[E:\repos\lib.nvim\README.md]]), "$REPOS_DIR/lib.nvim/README.md")
    H.eq(ES.shorten_path("C:/repos/lib.nvim/README.md"), "$REPOS_DIR/lib.nvim/README.md")
    H.eq(ES.shorten_path("/repos/lib.nvim/README.md"), "$REPOS_DIR/lib.nvim/README.md")
    local _, var = ES.shorten_path("E:/repos/x.md")
    H.eq(var, "REPOS_DIR", "second return is the variable name")
  end)

  H.check("shorten_path: the literal known directory wins, and needs no env var", function()
    H.config_sandbox(function(c)
      local dir = H.tmpdir():gsub("\\", "/")
      c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
      local out, var = ES.shorten_path(dir .. "/docs/a.md")
      H.eq(out, "$NVIM_CONFIG_DIR/docs/a.md")
      H.eq(var, "NVIM_CONFIG_DIR")
    end)
  end)

  H.check("shorten_path: a root registered in lib.nvim's registry is folded to", function()
    local roots = require("lib.nvim.fs.roots")
    local dir = H.tmpdir():gsub("\\", "/")
    local unregister = roots.register("GOPATH_SPEC_REG", dir)
    local ok, err = pcall(function()
      local out, var = ES.shorten_path(dir .. "/sub/a.md")
      H.eq(out, "$GOPATH_SPEC_REG/sub/a.md", "no environment variable needed")
      H.eq(var, "GOPATH_SPEC_REG")
      H.is_nil(ES.shorten_path(dir .. "/../outside.md"), "'..' does not stay inside the root")
    end)
    unregister()
    if not ok then error(err, 0) end
  end)

  H.check("shorten_path: nil under no configured root, for relative paths and URLs", function()
    H.is_nil(ES.shorten_path("C:/Users/me/Documents/a.md"), "outside every root")
    H.is_nil(
      ES.shorten_path("C:/Users/me/repos/a.md"),
      "a nested folder named repos is not the root"
    )
    H.is_nil(ES.shorten_path("./assets/a.png"), "relative")
    H.is_nil(ES.shorten_path("https://example.com/repos/a"), "a URL")
    H.is_nil(ES.shorten_path(""), "empty")
    ---@diagnostic disable-next-line: param-type-mismatch
    H.is_nil(ES.shorten_path(nil), "nil")
  end)

  -- ── the four recognised root forms ─────────────────────────────────────────

  H.check("Windows drive root, backslashes", function()
    local out, n = shorten([[see E:\repos\gopath.nvim\lua\gopath\env_shorten.lua]])
    H.eq(out, [[see $REPOS_DIR\gopath.nvim\lua\gopath\env_shorten.lua]])
    H.eq(n, 1, "one replacement")
  end)

  H.check("the drive letter itself never matters", function()
    local a = shorten("path: C:/repos/gopath.nvim/README.md")
    local b = shorten("path: E:/repos/gopath.nvim/README.md")
    H.eq(a, "path: $REPOS_DIR/gopath.nvim/README.md")
    H.eq(a, b, "C: and E: produce the same text")
  end)

  H.check("POSIX absolute root", function()
    H.eq(
      shorten("on Linux: /repos/gopath.nvim/README.md"),
      "on Linux: $REPOS_DIR/gopath.nvim/README.md"
    )
  end)

  H.check("home-relative root", function()
    H.eq(shorten("or: ~/repos/gopath.nvim/README.md"), "or: $REPOS_DIR/gopath.nvim/README.md")
    H.eq(shorten([[or: ~\repos\x]]), [[or: $REPOS_DIR\x]], "backslash after ~")
  end)

  H.check("bare root-relative, with a trailing separator", function()
    H.eq(shorten("repos/gopath.nvim/README.md"), "$REPOS_DIR/gopath.nvim/README.md")
  end)

  H.check("a marked root may end the token bare", function()
    H.eq(shorten([[E:\repos]]), "$REPOS_DIR", "a directory reference with nothing after it")
    H.eq(shorten("cd /repos then"), "cd $REPOS_DIR then")
  end)

  H.check("multiple occurrences, mixed case", function()
    local out, n = shorten("E:/repos/gopath.nvim and E:/REPOS/replacer.nvim")
    H.eq(out, "$REPOS_DIR/gopath.nvim and $REPOS_DIR/replacer.nvim")
    H.eq(n, 2, "both rewritten")
  end)

  -- ── the negative cases: what must stay untouched ───────────────────────────

  H.check("'repos' nested deeper than the root is left alone", function()
    local line = [[C:\Users\bartl\AppData\Local\nvim\somefolder\repos\notthis.md]]
    local out, n = shorten(line)
    H.eq(out, line, "unchanged")
    H.eq(n, 0, "no replacement")
  end)

  H.check("a longer word starting with the segment is not truncated", function()
    local line = [[E:\repository\unrelated.md]]
    H.eq(shorten(line), line, "'repository' must not become '$REPOS_DIRitory'")
    H.eq(select(2, shorten(line)), 0)
  end)

  H.check("a bare 'repos' with no marker and no separator is an ordinary word", function()
    local line = "this line has no repos path at all, just words"
    H.eq(shorten(line), line, "unchanged")
  end)

  H.check("nothing path-like at all", function()
    local line = "nothing path-like on this line whatsoever"
    local out, n = shorten(line)
    H.eq(out, line)
    H.eq(n, 0)
  end)

  H.check("an empty line is not an error", function()
    local out, n = shorten("")
    H.eq(out, "")
    H.eq(n, 0)
  end)

  -- ── multiple configured pairs ──────────────────────────────────────────────

  H.check("the longest segment name is tried first", function()
    -- Without the length ordering, "repos" would match inside "repos-archive"
    -- first and shadow the more specific pair.
    local pairs_list = {
      { segment = "repos", var = "REPOS_DIR" },
      { segment = "repos-archive", var = "ARCHIVE_DIR" },
    }
    local out = ES.shorten("E:/repos-archive/old.md", pairs_list)
    H.eq(out, "$ARCHIVE_DIR/old.md", "the specific pair wins")
    H.eq(
      ES.shorten("E:/repos/new.md", pairs_list),
      "$REPOS_DIR/new.md",
      "and the short one still works"
    )
  end)

  H.check("the caller's pair list is not reordered in place", function()
    local pairs_list = {
      { segment = "repos", var = "REPOS_DIR" },
      { segment = "repos-archive", var = "ARCHIVE_DIR" },
    }
    ES.shorten("E:/repos-archive/old.md", pairs_list)
    H.eq(pairs_list[1].segment, "repos", "the caller's table is sorted on a copy")
  end)

  H.check("two different segments in one line", function()
    local pairs_list = {
      { segment = "repos", var = "REPOS_DIR" },
      { segment = "work", var = "WORK_DIR" },
    }
    local out, n = ES.shorten("cp E:/repos/a.md /work/b.md", pairs_list)
    H.eq(out, "cp $REPOS_DIR/a.md $WORK_DIR/b.md")
    H.eq(n, 2)
  end)

  -- ── the buffer-facing entry point ──────────────────────────────────────────

  H.check("shorten_current_line rewrites the line in place and reports the count", function()
    H.config_sandbox(function()
      H.buf({ "first", [[see E:\repos\gopath.nvim\README.md]], "third" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      local notes = H.capture_notify(function()
        ES.shorten_current_line()
      end)

      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      H.eq(lines[2], [[see $REPOS_DIR\gopath.nvim\README.md]], "only line 2 changed")
      H.eq(lines[1], "first", "line above untouched")
      H.eq(lines[3], "third", "line below untouched")
      H.match(H.notify_text(notes), "shortened 1 occurrence", "reported in the singular")
    end)
  end)

  H.check("shorten_current_line pluralises correctly", function()
    H.config_sandbox(function()
      H.buf({ "E:/repos/a and C:/repos/b" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local notes = H.capture_notify(function()
        ES.shorten_current_line()
      end)
      H.eq(vim.api.nvim_get_current_line(), "$REPOS_DIR/a and $REPOS_DIR/b")
      H.match(H.notify_text(notes), "shortened 2 occurrences")
    end)
  end)

  H.check("shorten_current_line warns and leaves the line alone when nothing matches", function()
    H.config_sandbox(function()
      H.buf({ "nothing to see here" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local notes = H.capture_notify(function()
        ES.shorten_current_line()
      end)
      H.eq(vim.api.nvim_get_current_line(), "nothing to see here", "unchanged")
      H.match(H.notify_text(notes), "nothing to shorten on this line")
    end)
  end)

  H.check(
    "shorten_current_line warns instead of raising in a non-modifiable buffer (ERR-01)",
    function()
      H.config_sandbox(function()
        H.buf({ "see E:/repos/a.md" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.bo.modifiable = false
        local notes = H.capture_notify(function()
          ES.shorten_current_line()
        end)
        vim.bo.modifiable = true
        H.eq(
          vim.api.nvim_get_current_line(),
          "see E:/repos/a.md",
          "unchanged -- the write never landed"
        )
        H.match(H.notify_text(notes), "not modifiable")
      end)
    end
  )

  H.check("shorten_current_line honours a user-configured shorten_dirs map", function()
    H.config_sandbox(function(c)
      c.setup({ env_variable_resolution = { shorten_dirs = { projects = "PROJ_DIR" } } })
      H.buf({ "/projects/thing/main.go" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      H.capture_notify(function()
        ES.shorten_current_line()
      end)
      H.eq(vim.api.nvim_get_current_line(), "$PROJ_DIR/thing/main.go")
    end)
  end)

  H.check("shorten_current_line falls back to the built-in pair without config", function()
    H.config_sandbox(function(c)
      -- `shorten_dirs` is a map, so the merge replaces individual keys; setting
      -- the whole feature table to a non-table exercises the `or` fallback.
      c.setup({ env_variable_resolution = false })
      H.buf({ "/repos/x.md" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      H.capture_notify(function()
        ES.shorten_current_line()
      end)
      H.eq(vim.api.nvim_get_current_line(), "$REPOS_DIR/x.md", "default pair used")
    end)
  end)

  -- ── M.shorten_known / :GopathToNvimDir: literal well-known-dir match ───────

  H.check("shorten_known: a literal absolute path, any case, any separator", function()
    local pairs_list = { { var = "NVIM_CONFIG_DIR", dir = [[C:\Users\bartl\AppData\Local\nvim]] } }
    local out, n = ES.shorten_known(
      [[edit C:/Users/bartl/AppData/Local/NVIM/lua/plugins/personal/init.lua]],
      pairs_list
    )
    H.eq(out, "edit $NVIM_CONFIG_DIR/lua/plugins/personal/init.lua")
    H.eq(n, 1)
  end)

  H.check("shorten_known: unlike shorten_segment, a bare folder name never matches", function()
    -- The whole point of the literal match: "nvim" alone (no full stdpath
    -- prefix before it) must NOT be rewritten -- that would be exactly the
    -- false-positive risk shorten_prefix exists to avoid.
    local pairs_list = { { var = "NVIM_CONFIG_DIR", dir = "/home/x/.config/nvim" } }
    local line = "cd /some/other/nvim/project"
    local out, n = ES.shorten_known(line, pairs_list)
    H.eq(out, line, "unchanged")
    H.eq(n, 0)
  end)

  H.check("shorten_known: a longer directory wins over a shorter one nested in it", function()
    local pairs_list = {
      { var = "NVIM_CONFIG_DIR", dir = "/home/x/.config/nvim" },
      { var = "CONFIG_DIR", dir = "/home/x/.config" },
    }
    H.eq(
      ES.shorten_known("/home/x/.config/nvim/init.lua", pairs_list),
      "$NVIM_CONFIG_DIR/init.lua",
      "the more specific (longer) directory wins"
    )
    H.eq(
      ES.shorten_known("/home/x/.config/other/x", pairs_list),
      "$CONFIG_DIR/other/x",
      "and the shorter one still works outside the nested one"
    )
  end)

  H.check(
    "shorten_current_line_known rewrites the current line using shorten_known_dirs",
    function()
      H.config_sandbox(function(c)
        -- A real absolute path of this platform: on Windows `/home/x/...` is
        -- no root (it means "on the current drive"), the registry refuses it.
        local proj = H.tmpdir():gsub("\\", "/")
        c.setup({
          env_variable_resolution = {
            shorten_known_dirs = { PROJ_ROOT = proj },
          },
        })
        H.buf({ "see " .. proj .. "/README.md" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local notes = H.capture_notify(function()
          ES.shorten_current_line_known()
        end)
        H.eq(vim.api.nvim_get_current_line(), "see $PROJ_ROOT/README.md")
        H.match(H.notify_text(notes), "shortened 1 occurrence")
      end)
    end
  )

  H.check("shorten_current_line_known accepts a resolver function, called fresh", function()
    H.config_sandbox(function(c)
      local calls = 0
      local computed = H.tmpdir():gsub("\\", "/")
      c.setup({
        env_variable_resolution = {
          shorten_known_dirs = {
            NVIM_CONFIG_DIR = function()
              calls = calls + 1
              return computed
            end,
          },
        },
      })
      H.buf({ "open " .. computed .. "/init.lua" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      H.capture_notify(function()
        ES.shorten_current_line_known()
      end)
      H.eq(vim.api.nvim_get_current_line(), "open $NVIM_CONFIG_DIR/init.lua")
      H.eq(calls, 1, "the resolver ran")
    end)
  end)

  -- The known dirs are resolved by lib.nvim's root registry (opts.extra), which
  -- decides what a value means: a relative one is no root, a leading `~` is
  -- the home directory.

  H.check("shorten_current_line_known: a relative known-dir value is no root", function()
    H.config_sandbox(function(c)
      c.setup({
        env_variable_resolution = { shorten_known_dirs = { GOPATH_SPEC_REL = "relative/dir" } },
      })
      H.buf({ "see relative/dir/x.md" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      H.capture_notify(function()
        ES.shorten_current_line_known()
      end)
      H.eq(
        vim.api.nvim_get_current_line(),
        "see relative/dir/x.md",
        "a value that moves with :cd is not rewritten to $GOPATH_SPEC_REL"
      )
    end)
  end)

  H.check("shorten_current_line_known: a known-dir value starting with ~ is expanded", function()
    H.config_sandbox(function(c)
      c.setup({
        env_variable_resolution = {
          shorten_known_dirs = { GOPATH_SPEC_HOME = "~/gopath-spec-known" },
        },
      })
      local home = (vim.uv or vim.loop).os_homedir():gsub("\\", "/"):gsub("/$", "")
      H.buf({ "see " .. home .. "/gopath-spec-known/a.md" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      H.capture_notify(function()
        ES.shorten_current_line_known()
      end)
      H.eq(vim.api.nvim_get_current_line(), "see $GOPATH_SPEC_HOME/a.md")
    end)
  end)

  -- These two mock `gopath.config` directly rather than going through
  -- `config_sandbox`/`c.setup()`: `deep_merge_into` merges map fields
  -- key-by-key (see the "shorten_dirs...falls back" test above), so setting
  -- `shorten_known_dirs = {}` through setup() is a no-op that leaves the
  -- default NVIM_CONFIG_DIR entry in place -- there is no way to reach a
  -- genuinely empty map through the public config API, only by replacing
  -- what `gopath.config.get()` itself returns.

  H.check(
    "shorten_current_line_known warns instead of raising when nothing is configured",
    function()
      H.with_modules({
        ["gopath.config"] = {
          get = function()
            return { env_variable_resolution = { shorten_known_dirs = {} } }
          end,
        },
      }, function()
        H.buf({ "anything at all" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local notes = H.capture_notify(function()
          ES.shorten_current_line_known()
        end)
        H.eq(vim.api.nvim_get_current_line(), "anything at all", "unchanged")
        H.match(H.notify_text(notes), "no known directories configured")
      end)
    end
  )

  H.check("shorten_current_line_known ignores a resolver that fails or returns nothing", function()
    H.with_modules({
      ["gopath.config"] = {
        get = function()
          return {
            env_variable_resolution = {
              shorten_known_dirs = {
                BROKEN = function()
                  error("boom")
                end,
                EMPTY = function()
                  return ""
                end,
              },
            },
          }
        end,
      },
    }, function()
      H.buf({ "anything at all" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local notes = H.capture_notify(function()
        ES.shorten_current_line_known()
      end)
      H.eq(vim.api.nvim_get_current_line(), "anything at all", "unchanged")
      H.match(H.notify_text(notes), "no known directories configured")
    end)
  end)

  -- ── Markdown-link relative paths, resolved against the buffer's directory ──

  H.check(
    "shorten_current_line_known: a relative Markdown image link under the known dir is rewritten",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        H.write(dir .. "/docs/ROADMAP/assets/ROADMAP-123.png", { "" })
        local note = H.write(dir .. "/docs/ROADMAP/note.md", {
          "![no symlink because not focused filetree](./assets/ROADMAP-123.png)",
        })
        c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
        vim.cmd.edit(vim.fn.fnameescape(note))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        local notes = H.capture_notify(function()
          ES.shorten_current_line_known()
        end)
        H.eq(
          vim.api.nvim_get_current_line(),
          "![no symlink because not focused filetree]($NVIM_CONFIG_DIR/docs/ROADMAP/assets/ROADMAP-123.png)"
        )
        H.match(H.notify_text(notes), "shortened 1 occurrence")
      end)
    end
  )

  H.check(
    "shorten_current_line_known: two Markdown links on one line, both under the known dir",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        local note = H.write(dir .. "/docs/note.md", {
          "see [a](./assets/a.png) and [b](./assets/sub/b.png) here",
        })
        c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
        vim.cmd.edit(vim.fn.fnameescape(note))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        ES.shorten_current_line_known()
        H.eq(
          vim.api.nvim_get_current_line(),
          "see [a]($NVIM_CONFIG_DIR/docs/assets/a.png) and [b]($NVIM_CONFIG_DIR/docs/assets/sub/b.png) here"
        )
      end)
    end
  )

  H.check(
    "shorten_current_line_known: a relative Markdown link that resolves OUTSIDE every known dir is left untouched",
    function()
      H.config_sandbox(function(c)
        -- The known dir and the buffer's own directory are unrelated trees,
        -- so "./assets/x.png" resolves somewhere no configured root covers.
        local known_dir = H.tmpdir()
        local elsewhere = H.tmpdir()
        local note = H.write(elsewhere .. "/docs/note.md", {
          "see [x](./assets/x.png) here",
        })
        c.setup({
          env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = known_dir } },
        })
        vim.cmd.edit(vim.fn.fnameescape(note))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        local line_before = vim.api.nvim_get_current_line()
        local notes = H.capture_notify(function()
          ES.shorten_current_line_known()
        end)
        H.eq(vim.api.nvim_get_current_line(), line_before, "unchanged")
        H.match(H.notify_text(notes), "nothing to shorten")
      end)
    end
  )

  H.check(
    "shorten_current_line_known: the Markdown pass and a literal absolute path on the same line both count",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        local note = H.write(dir .. "/docs/note.md", {
          "[rel](./assets/a.png) and " .. dir:gsub("\\", "/") .. "/README.md",
        })
        c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
        vim.cmd.edit(vim.fn.fnameescape(note))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        local notes = H.capture_notify(function()
          ES.shorten_current_line_known()
        end)
        H.eq(
          vim.api.nvim_get_current_line(),
          "[rel]($NVIM_CONFIG_DIR/docs/assets/a.png) and $NVIM_CONFIG_DIR/README.md"
        )
        H.match(H.notify_text(notes), "shortened 2 occurrences")
      end)
    end
  )

  H.check(
    "shorten_current_line_known: a URL inside a Markdown link is NEVER treated as a relative path"
      .. " (regression: used to mangle it when the buffer itself lives under the known dir)",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        -- The bug: joining "https://github.com/foo/bar" to a bufdir that is
        -- itself under the known dir makes the JOINED string start with the
        -- known dir purely because the bufdir does -- nothing to do with the
        -- URL. shorten_prefix then matched that prefix and spliced
        -- "$NVIM_CONFIG_DIR/docs/https:/github.com/foo/bar" into the link.
        local note = H.write(dir .. "/docs/note.md", {
          "see [GitHub](https://github.com/foo/bar) and [rel](./a.png) here",
        })
        c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
        vim.cmd.edit(vim.fn.fnameescape(note))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        ES.shorten_current_line_known()
        H.eq(
          vim.api.nvim_get_current_line(),
          "see [GitHub](https://github.com/foo/bar) and [rel]($NVIM_CONFIG_DIR/docs/a.png) here",
          "the URL survives untouched; the genuine relative link (bufdir is dir/docs) still resolves"
        )
      end)
    end
  )

  H.check(
    "shorten_current_line: same URL guard applies to the structural (repos-dir) flavour",
    function()
      H.config_sandbox(function()
        local root = H.tmpdir():match("^(%a:[/\\])") or "/"
        H.buf(
          { "see [x](https://example.com/repos/thing) here" },
          { name = root .. "repos/note.md" }
        )
        local before = vim.api.nvim_get_current_line()
        local notes = H.capture_notify(function()
          ES.shorten_current_line()
        end)
        H.eq(vim.api.nvim_get_current_line(), before, "unchanged -- the URL is not a relative path")
        H.match(H.notify_text(notes), "nothing to shorten")
      end)
    end
  )

  H.check(
    "shorten_current_line_known: a bare-host (schemeless) Markdown link is also excluded",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        local note = H.write(dir .. "/docs/note.md", { "see [x](github.com/foo/bar) here" })
        c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
        vim.cmd.edit(vim.fn.fnameescape(note))
        local before = vim.api.nvim_get_current_line()
        local notes = H.capture_notify(function()
          ES.shorten_current_line_known()
        end)
        H.eq(vim.api.nvim_get_current_line(), before, "unchanged")
        H.match(H.notify_text(notes), "nothing to shorten")
      end)
    end
  )

  H.check(
    "shorten_current_line_known: a URL directly selected (not in a Markdown link) is also excluded",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        local note = H.write(dir .. "/docs/note.md", { "https://github.com/foo/bar" })
        c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
        vim.cmd.edit(vim.fn.fnameescape(note))
        vim.api.nvim_buf_set_mark(0, "<", 1, 0, {})
        vim.api.nvim_buf_set_mark(0, ">", 1, #"https://github.com/foo/bar" - 1, {})

        local notes = H.capture_notify(function()
          ES.shorten_current_line_known({ selection = true })
        end)
        H.eq(vim.api.nvim_get_current_line(), "https://github.com/foo/bar", "unchanged")
        H.match(H.notify_text(notes), "nothing to shorten")
      end)
    end
  )

  H.check(
    "shorten_current_line_known: an unnamed buffer skips relative resolution, no error",
    function()
      H.config_sandbox(function(c)
        c.setup({
          env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = H.tmpdir() } },
        })
        H.buf({ "see [x](./assets/a.png) here" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local notes = H.capture_notify(function()
          ES.shorten_current_line_known()
        end)
        H.eq(vim.api.nvim_get_current_line(), "see [x](./assets/a.png) here", "unchanged")
        H.match(H.notify_text(notes), "nothing to shorten")
      end)
    end
  )

  H.check(
    "shorten_current_line: the structural (repos-dir) flavour gets the same Markdown-relative treatment",
    function()
      H.config_sandbox(function()
        -- "repos" must be root-adjacent for the structural matcher (see the
        -- "nested deeper than the root" case in the segment tests above), so
        -- this fakes the buffer's own name rather than nesting under
        -- H.tmpdir() (always deep inside the OS temp tree). expand("%:p:h")
        -- works from the registered name alone -- the file need not exist.
        -- The root prefix is taken from a REAL tmpdir so it matches
        -- whatever absolute-path convention this platform actually uses
        -- (a Windows drive letter is required for `:p` to treat a bare
        -- leading "/" as already-absolute instead of cwd-relative).
        local root = H.tmpdir():match("^(%a:[/\\])") or "/"
        H.buf({ "see [x](../assets/logo.png) here" }, { name = root .. "repos/proj/docs/note.md" })

        ES.shorten_current_line()
        H.eq(vim.api.nvim_get_current_line(), "see [x]($REPOS_DIR/proj/assets/logo.png) here")
      end)
    end
  )

  -- ── Visual-selection range: shorten just the selected span ─────────────────

  H.check(
    "shorten_current_line_known: a selected literal span is rewritten, the rest is untouched",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
        local abs = dir:gsub("\\", "/") .. "/README.md"
        local line = "prefix " .. abs .. " suffix"
        H.buf({ line })
        -- Select just the absolute path span (1-indexed, inclusive).
        local scol, ecol = #"prefix ", #("prefix " .. abs) - 1
        vim.api.nvim_buf_set_mark(0, "<", 1, scol, {})
        vim.api.nvim_buf_set_mark(0, ">", 1, ecol, {})

        ES.shorten_current_line_known({ selection = true })
        H.eq(vim.api.nvim_get_current_line(), "prefix $NVIM_CONFIG_DIR/README.md suffix")
      end)
    end
  )

  H.check(
    "shorten_current_line_known: a selected bare relative path resolves against the buffer dir",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        local note = H.write(dir .. "/docs/note.md", { "prefix ./assets/a.png suffix" })
        c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
        vim.cmd.edit(vim.fn.fnameescape(note))
        local line = vim.api.nvim_get_current_line()
        local scol, ecol = #"prefix ", #"prefix ./assets/a.png" - 1
        vim.api.nvim_buf_set_mark(0, "<", 1, scol, {})
        vim.api.nvim_buf_set_mark(0, ">", 1, ecol, {})
        H.eq(line:sub(scol + 1, ecol + 1), "./assets/a.png", "selection sanity check")

        ES.shorten_current_line_known({ selection = true })
        H.eq(vim.api.nvim_get_current_line(), "prefix $NVIM_CONFIG_DIR/docs/assets/a.png suffix")
      end)
    end
  )

  H.check(
    "shorten_current_line_known: opts.selection with no marks warns instead of erroring",
    function()
      H.config_sandbox(function(c)
        c.setup({
          env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = H.tmpdir() } },
        })
        H.buf({ "nothing selected here" })
        local notes = H.capture_notify(function()
          ES.shorten_current_line_known({ selection = true })
        end)
        H.eq(vim.api.nvim_get_current_line(), "nothing selected here", "unchanged")
        H.match(H.notify_text(notes), "no %(single%-line%) selection")
      end)
    end
  )

  H.check(
    "shorten_current_line_known: opts.selection with a multi-line selection warns, does not fall back to the whole line",
    function()
      H.config_sandbox(function(c)
        local dir = H.tmpdir()
        c.setup({ env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = dir } } })
        local abs = dir:gsub("\\", "/") .. "/README.md"
        H.buf({ abs, "second line" })
        vim.api.nvim_buf_set_mark(0, "<", 1, 0, {})
        vim.api.nvim_buf_set_mark(0, ">", 2, 0, {})

        local notes = H.capture_notify(function()
          ES.shorten_current_line_known({ selection = true })
        end)
        H.eq(
          vim.api.nvim_get_current_line(),
          abs,
          "unchanged -- not silently widened to the whole line"
        )
        H.match(H.notify_text(notes), "no %(single%-line%) selection")
      end)
    end
  )

  -- ── bare relative paths located below a root ───────────────────────────────

  ---A root with `wkdbooks/dev/wkdbook-x/proj/ROADMAP/ROADMAP.md` and
  ---`proj-b/README.md` below it, configured as both the repos var and a known dir.
  ---The cwd is a fresh temp directory outside the root for the length of `fn` (the
  ---harness restores it after the check): an unnamed buffer must never be resolved
  ---against the cwd, and if that regressed, a checkout below a folder named `repos`
  ---would turn the expectations below into `$REPOS_DIR/<checkout>/...`. The two
  ---"an unnamed buffer" cases cd below the root themselves to pin that guard.
  ---@param fn fun(root: string, set: fun(extra: table|nil))
  local function with_root(fn)
    H.config_sandbox(function(c)
      local root = H.tmpdir()
      vim.cmd.cd(vim.fn.fnameescape(H.tmpdir()))
      H.write(root .. "/wkdbooks/dev/wkdbook-x/proj/ROADMAP/ROADMAP.md", { "x" })
      H.write(root .. "/proj-b/README.md", { "x" })
      H.write(root .. "/deep/a/b/c/hidden-dir/f.md", { "x" })
      local old = vim.env.REPOS_DIR
      vim.env.REPOS_DIR = root
      local function set(extra)
        c.setup(vim.tbl_deep_extend("force", {
          env_variable_resolution = { shorten_known_dirs = { NVIM_CONFIG_DIR = root } },
        }, extra or {}))
      end
      set()
      local ok, err = pcall(fn, root, set)
      vim.env.REPOS_DIR = old
      if not ok then error(err, 0) end
    end)
  end

  H.check("to-repos-dir: a bare relative path found below $REPOS_DIR gets its prefix", function()
    with_root(function()
      H.buf({ "see wkdbook-x/proj/ROADMAP/ROADMAP.md for details" })
      ES.shorten_current_line()
      H.eq(
        vim.api.nvim_get_current_line(),
        "see $REPOS_DIR/wkdbooks/dev/wkdbook-x/proj/ROADMAP/ROADMAP.md for details"
      )
    end)
  end)

  H.check("to-nvim-dir: the same lookup against the known directory", function()
    with_root(function()
      H.buf({ "wkdbook-x/proj/ROADMAP/ROADMAP.md" })
      ES.shorten_current_line_known()
      H.eq(
        vim.api.nvim_get_current_line(),
        "$NVIM_CONFIG_DIR/wkdbooks/dev/wkdbook-x/proj/ROADMAP/ROADMAP.md"
      )
    end)
  end)

  H.check("a direct child of the root is found, backslashes are kept", function()
    with_root(function()
      H.buf({ [[proj-b\README.md]] })
      ES.shorten_current_line()
      H.eq(vim.api.nvim_get_current_line(), [[$REPOS_DIR\proj-b\README.md]])
    end)
  end)

  H.check("a trailing sentence dot is not part of the path", function()
    with_root(function()
      H.buf({ "open proj-b/README.md." })
      ES.shorten_current_line()
      H.eq(vim.api.nvim_get_current_line(), "open $REPOS_DIR/proj-b/README.md.")
    end)
  end)

  H.check("the whole path must exist: an unrelated 'proj-b/nope.md' stays", function()
    with_root(function()
      H.buf({ "proj-b/nope.md" })
      local notes = H.capture_notify(function()
        ES.shorten_current_line()
      end)
      H.eq(vim.api.nvim_get_current_line(), "proj-b/nope.md")
      H.match(H.notify_text(notes), "nothing to shorten")
    end)
  end)

  H.check("URLs, ./ paths, $VAR paths and plain words are never candidates", function()
    with_root(function()
      local line =
        "https://example.com/proj-b/README.md ./proj-b/README.md and/or $REPOS_DIR/proj-b/README.md"
      H.buf({ line })
      ES.shorten_current_line()
      H.eq(vim.api.nvim_get_current_line(), line)
    end)
  end)

  H.check("the search depth is bounded by root_search.max_depth", function()
    with_root(function(_, set)
      H.buf({ "hidden-dir/f.md" })
      ES.shorten_current_line()
      H.eq(vim.api.nvim_get_current_line(), "hidden-dir/f.md", "depth 5 is out of reach by default")

      set({ env_variable_resolution = { root_search = { max_depth = 5 } } })
      ES.shorten_current_line()
      H.eq(vim.api.nvim_get_current_line(), "$REPOS_DIR/deep/a/b/c/hidden-dir/f.md")
    end)
  end)

  H.check("root_search.enable = false switches the lookup off", function()
    with_root(function(_, set)
      set({ env_variable_resolution = { root_search = { enable = false } } })
      H.buf({ "proj-b/README.md" })
      H.capture_notify(function()
        ES.shorten_current_line()
      end)
      H.eq(vim.api.nvim_get_current_line(), "proj-b/README.md")
    end)
  end)

  H.check("an unset $REPOS_DIR contributes no root", function()
    with_root(function()
      vim.env.REPOS_DIR = nil
      H.buf({ "proj-b/README.md" })
      H.capture_notify(function()
        ES.shorten_current_line()
      end)
      H.eq(vim.api.nvim_get_current_line(), "proj-b/README.md")
    end)
  end)

  H.check("the search root of a shorten_dirs variable may be a registry root", function()
    with_root(function(_, set)
      local roots = require("lib.nvim.fs.roots")
      local other = H.tmpdir():gsub("\\", "/")
      H.write(other .. "/proj-z/README.md", { "x" })
      vim.env.GOPATH_SPEC_REG = nil
      local unregister = roots.register("GOPATH_SPEC_REG", other)
      local ok, err = pcall(function()
        set({ env_variable_resolution = { shorten_dirs = { gpspec = "GOPATH_SPEC_REG" } } })
        H.buf({ "proj-z/README.md" })
        H.capture_notify(function()
          ES.shorten_current_line()
        end)
        H.eq(
          vim.api.nvim_get_current_line(),
          "$GOPATH_SPEC_REG/proj-z/README.md",
          "found below the registered root, no environment variable set"
        )
      end)
      unregister()
      if not ok then error(err, 0) end
    end)
  end)

  H.check("a selection holding a path with spaces is looked up as one path", function()
    with_root(function(root)
      H.write(root .. "/proj-b/my notes.md", { "x" })
      H.buf({ "see proj-b/my notes.md ok" })
      vim.api.nvim_buf_set_mark(0, "<", 1, #"see ", {})
      vim.api.nvim_buf_set_mark(0, ">", 1, #"see proj-b/my notes.md" - 1, {})
      ES.shorten_current_line({ selection = true })
      H.eq(vim.api.nvim_get_current_line(), "see $REPOS_DIR/proj-b/my notes.md ok")
    end)
  end)

  H.check("a path that exists next to the buffer is rewritten from its real location", function()
    with_root(function(root)
      local note = H.write(root .. "/wkdbooks/dev/wkdbook-x/note.md", { "proj/ROADMAP/ROADMAP.md" })
      vim.cmd.edit(vim.fn.fnameescape(note))
      ES.shorten_current_line_known()
      H.eq(
        vim.api.nvim_get_current_line(),
        "$NVIM_CONFIG_DIR/wkdbooks/dev/wkdbook-x/proj/ROADMAP/ROADMAP.md"
      )
    end)
  end)

  H.check(
    "a path that exists next to the buffer but outside every root is not 'found' elsewhere",
    function()
      with_root(function()
        -- Same relative text exists below the root (proj-b/README.md) AND next to
        -- the buffer, which sits outside every root: the buffer's one is the file.
        local other = H.tmpdir()
        local note = H.write(other .. "/note.md", { "proj-b/README.md" })
        H.write(other .. "/proj-b/README.md", { "x" })
        vim.cmd.edit(vim.fn.fnameescape(note))
        H.capture_notify(function()
          ES.shorten_current_line()
        end)
        H.eq(vim.api.nvim_get_current_line(), "proj-b/README.md")
      end)
    end
  )

  H.check("a '..' segment never walks the existence check out of the root", function()
    with_root(function()
      H.buf({ "proj-b/../proj-b/README.md" })
      H.capture_notify(function()
        ES.shorten_current_line()
      end)
      H.eq(vim.api.nvim_get_current_line(), "proj-b/../proj-b/README.md")
    end)
  end)

  H.check("dot directories are not searched", function()
    with_root(function(root)
      H.write(root .. "/.claude/worktrees/hidden-dot/f.md", { "x" })
      H.buf({ "hidden-dot/f.md" })
      H.capture_notify(function()
        ES.shorten_current_line()
      end)
      H.eq(vim.api.nvim_get_current_line(), "hidden-dot/f.md")
    end)
  end)

  -- An unnamed buffer has no directory: `expand("%:p:h")` answers the cwd there, and resolving
  -- "proj-b/README.md" against it would yield `$NVIM_CONFIG_DIR/<cwd below the root>/proj-b/...`
  -- whenever the cwd sits below a known directory. The cwd is `<root>/work` in both cases; the
  -- harness restores it after each check.
  H.check("an unnamed buffer: a selection is not resolved against the cwd", function()
    with_root(function(root)
      local cwd = H.write(root .. "/work/keep", { "x" }):gsub("/keep$", "")
      vim.cmd.cd(vim.fn.fnameescape(cwd))
      H.buf({ "proj-b/README.md" })
      vim.api.nvim_buf_set_mark(0, "<", 1, 0, {})
      vim.api.nvim_buf_set_mark(0, ">", 1, #"proj-b/README.md" - 1, {})
      ES.shorten_current_line_known({ selection = true })
      H.eq(vim.api.nvim_get_current_line(), "$NVIM_CONFIG_DIR/proj-b/README.md")
    end)
  end)

  H.check(
    "an unnamed buffer: a path that exists below the cwd is not taken for the file",
    function()
      with_root(function(root)
        -- <cwd>/proj-b/README.md exists too: with the cwd as the buffer's directory it would be
        -- "the file next to the buffer" and win over the one below the root.
        local cwd = root .. "/work"
        H.write(cwd .. "/proj-b/README.md", { "x" })
        vim.cmd.cd(vim.fn.fnameescape(cwd))
        H.buf({ "see proj-b/README.md ok" })
        ES.shorten_current_line_known()
        H.eq(vim.api.nvim_get_current_line(), "see $NVIM_CONFIG_DIR/proj-b/README.md ok")
      end)
    end
  )

  H.check("a selection keeps the whitespace around the path it rewrites", function()
    with_root(function()
      H.buf({ "a  proj-b/README.md  b" })
      vim.api.nvim_buf_set_mark(0, "<", 1, 1, {})
      vim.api.nvim_buf_set_mark(0, ">", 1, #"a  proj-b/README.md " - 1, {})
      ES.shorten_current_line({ selection = true })
      H.eq(vim.api.nvim_get_current_line(), "a  $REPOS_DIR/proj-b/README.md  b")
    end)
  end)

  H.check("several tokens on one line are all placed", function()
    with_root(function()
      H.buf({ "proj-b/README.md and wkdbook-x/proj/ROADMAP/ROADMAP.md" })
      ES.shorten_current_line()
      H.eq(
        vim.api.nvim_get_current_line(),
        "$REPOS_DIR/proj-b/README.md and $REPOS_DIR/wkdbooks/dev/wkdbook-x/proj/ROADMAP/ROADMAP.md"
      )
    end)
  end)
end
