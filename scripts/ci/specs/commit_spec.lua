-- scripts/ci/specs/commit_spec.lua
-- A commit hash under the cursor: what is taken for one (form only), where each target puts the commit (a real temp
-- repository, `git show` into the expected window), a commit the repository lacks (fetch or web), the web target
-- (the opener is replaced and sees the URL), and the jump from a diff line of the `git show` buffer to the file.

---@param H table
return function(H)
  local COMMIT = require("gopath.resolvers.common.commit")
  local OPEN_COMMIT = require("gopath.open.commit")
  local config = require("gopath.config")

  ---@param cond fun(): boolean
  ---@param what string
  local function wait(cond, what)
    local ok = vim.wait(8000, cond, 20)
    H.truthy(ok, "timed out waiting for " .. what)
  end

  ---Run a git command in `dir`; a failure is a failure of the spec.
  ---@param dir string
  ---@param args string[]
  ---@return string stdout
  local function git(dir, args)
    local argv = {
      "git",
      "-c",
      "user.name=gopath-spec",
      "-c",
      "user.email=spec@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.autocrlf=false",
      "-C",
      dir,
    }
    vim.list_extend(argv, args)
    local res = vim.system(argv, { text = true }):wait()
    H.eq(res.code, 0, "git " .. table.concat(args, " ") .. ": " .. (res.stderr or ""))
    return vim.trim(res.stdout or "")
  end

  ---@param dir string
  ---@param msg string
  ---@return string sha
  local function commit(dir, msg)
    git(dir, { "add", "-A" })
    git(dir, { "commit", "-q", "--allow-empty", "-m", msg })
    return git(dir, { "rev-parse", "HEAD" })
  end

  -- ── form ───────────────────────────────────────────────────────────────────

  H.check("commit: a bare hash under the cursor is a commit result (form only)", function()
    config.setup({})
    H.line_at("fixed in a02ddae1 yesterday", "a02ddae1", { filetype = "markdown" })
    local r = COMMIT.resolve()
    H.truthy(r, "a result")
    H.eq(r.kind, "commit")
    H.eq(r.commit.sha, "a02ddae1")
    H.is_nil(r.commit.repo)
    H.eq(r.path, "a02ddae1")
    H.eq(r.exists, true, "so the open path does not offer to create it")
  end)

  H.check("commit: repo@hash carries the repo name", function()
    H.line_at("see tasks.nvim@a02ddae, then", "tasks.nvim@", { filetype = "markdown" })
    local r = COMMIT.resolve()
    H.truthy(r)
    H.eq(r.commit.repo, "tasks.nvim")
    H.eq(r.commit.sha, "a02ddae")
    H.eq(r.path, "tasks.nvim@a02ddae", "the range stops at the comma")
  end)

  H.check("commit: a word, a number and a short token are not commits", function()
    H.line_at("a deadbeef word", "deadbeef", { filetype = "markdown" })
    H.is_nil(COMMIT.resolve(), "hex letters only: a word")
    H.line_at("number 12345678 here", "12345678", { filetype = "markdown" })
    H.is_nil(COMMIT.resolve(), "digits only: a number")
    H.line_at("short a02dda x", "a02dda", { filetype = "markdown" })
    H.is_nil(COMMIT.resolve(), "6 characters")
  end)

  H.check("commit: a file spelled like the hash wins", function()
    local dir = H.tmpdir()
    local file = dir .. "/a02ddae1"
    H.write(file, { "not a commit" })
    H.buf({ "open a02ddae1 please" }, { filetype = "text" })
    vim.api.nvim_buf_set_name(0, dir .. "/notes.txt")
    H.write(dir .. "/notes.txt", { "x" })
    H.cursor_on(1, "a02ddae1")
    H.is_nil(COMMIT.resolve(), "the file on disk is the target")
  end)

  H.check("commit: commit.enable = false turns it off, as does commit = false", function()
    config.setup({ commit = { enable = false } })
    H.line_at("fixed in a02ddae1", "a02ddae1", { filetype = "markdown" })
    H.is_nil(COMMIT.resolve())
    config.setup({ commit = false })
    H.is_nil(COMMIT.resolve())
    config.setup({})
    H.truthy(COMMIT.resolve(), "and back on after a plain setup")
  end)

  H.check("commit: the pipeline takes it before the file stages", function()
    config.setup({})
    H.line_at("fixed in a02ddae1 yesterday", "a02ddae1", { filetype = "markdown" })
    local r = require("gopath.resolve").resolve_at_cursor({})
    H.truthy(r)
    H.eq(r.kind, "commit")
  end)

  -- ── targets, in a real repository ──────────────────────────────────────────

  local repos = H.tmpdir()
  local proj = repos .. "/proj.nvim"
  H.mkdir(proj)
  git(proj, { "init", "-q", "-b", "main" })
  H.write(proj .. "/f.txt", { "one" })
  H.write(proj .. "/gone.txt", { "will be deleted" })
  local first = commit(proj, "first")
  H.write(proj .. "/f.txt", { "one", "two" })
  vim.fn.delete(proj .. "/gone.txt")
  local second = commit(proj, "second: edit f, delete gone")

  local saved_repos_dir = vim.env.REPOS_DIR
  vim.env.REPOS_DIR = repos

  ---A `commit` result as the resolver would make it, for a buffer in `dir`.
  ---@param sha string
  ---@param repo string|nil
  ---@return GopathResult
  local function result_for(sha, repo)
    return {
      kind = "commit",
      path = sha,
      exists = true,
      commit = { sha = sha, repo = repo, dir = proj },
    }
  end

  ---Close every window and tab but one, so the next target starts from a known layout.
  local function reset_layout()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    vim.cmd("enew!")
  end

  ---@return boolean
  local function in_show_buffer()
    local info = vim.b.gopath_commit
    return type(info) == "table" and info.full == second
  end

  H.check("commit: float shows `git show` read-only, filetype git, and q closes it", function()
    reset_layout()
    OPEN_COMMIT.open(result_for(second:sub(1, 8)), "float")
    wait(in_show_buffer, "the float")
    H.truthy(vim.api.nvim_win_get_config(0).relative ~= "", "the window floats")
    H.eq(vim.bo.filetype, "git")
    H.eq(vim.bo.modifiable, false)
    H.eq(vim.bo.readonly, true)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    H.eq(lines[1], "commit " .. second)
    H.truthy(
      table.concat(lines, "\n"):find("second: edit f", 1, true),
      "the message is in the view"
    )
    H.truthy(table.concat(lines, "\n"):find("+two", 1, true), "the patch is in the view")
    local win = vim.api.nvim_get_current_win()
    vim.cmd("normal q")
    H.falsy(vim.api.nvim_win_is_valid(win), "q closed the float")
  end)

  H.check("commit: split, vsplit and tab each make the window they say", function()
    reset_layout()
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    OPEN_COMMIT.open(result_for(second:sub(1, 8)), "window")
    wait(in_show_buffer, "the split")
    H.eq(#vim.api.nvim_tabpage_list_wins(0), wins + 1, "a window more")
    H.eq(vim.api.nvim_win_get_config(0).relative, "", "not floating")

    reset_layout()
    OPEN_COMMIT.open(result_for(second:sub(1, 8)), "vsplit")
    wait(in_show_buffer, "the vsplit")
    local cur, other = vim.api.nvim_get_current_win(), nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= cur then other = w end
    end
    H.truthy(other, "two windows")
    H.eq(
      vim.api.nvim_win_get_position(cur)[1],
      vim.api.nvim_win_get_position(other)[1],
      "side by side"
    )

    reset_layout()
    local tabs = #vim.api.nvim_list_tabpages()
    OPEN_COMMIT.open(result_for(second:sub(1, 8)), "tab")
    wait(in_show_buffer, "the tab")
    H.eq(#vim.api.nvim_list_tabpages(), tabs + 1, "a tab more")
    reset_layout()
  end)

  H.check("commit: current replaces the buffer of the window, q goes back", function()
    reset_layout()
    local keep = H.buf({ "the note" }, { listed = true })
    local win = vim.api.nvim_get_current_win()
    OPEN_COMMIT.open(result_for(second:sub(1, 8)), "current")
    wait(in_show_buffer, "the current window")
    H.eq(vim.api.nvim_get_current_win(), win, "same window")
    H.truthy(vim.api.nvim_get_current_buf() ~= keep, "another buffer")
    vim.cmd("normal q")
    H.eq(vim.api.nvim_get_current_buf(), keep, "q is back in the note")
  end)

  H.check("commit: a window mode of a mapping picks the target, edit uses commit.open", function()
    reset_layout()
    config.setup({ commit = { open = "tab" } })
    local tabs = #vim.api.nvim_list_tabpages()
    OPEN_COMMIT.open(result_for(second:sub(1, 8)), "edit")
    wait(in_show_buffer, "commit.open = tab")
    H.eq(#vim.api.nvim_list_tabpages(), tabs + 1, "gP followed commit.open")
    reset_layout()
    config.setup({ commit = { open = "no-such-target" } })
    OPEN_COMMIT.open(result_for(second:sub(1, 8)), "edit")
    wait(in_show_buffer, "the float fallback")
    H.truthy(
      vim.api.nvim_win_get_config(0).relative ~= "",
      "an unknown value falls back to the float"
    )
    vim.cmd("normal q")
    config.setup({})
  end)

  H.check("commit: repo@hash opens in the right repo wherever the buffer is", function()
    reset_layout()
    local elsewhere = H.tmpdir()
    OPEN_COMMIT.open({
      kind = "commit",
      path = "proj.nvim@x",
      commit = { sha = first:sub(1, 8), repo = "proj.nvim", dir = elsewhere },
    }, "current")
    wait(function()
      local info = vim.b.gopath_commit
      return type(info) == "table" and info.full == first
    end, "the commit of proj.nvim")
    H.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "commit " .. first)
    reset_layout()
  end)

  -- ── web ────────────────────────────────────────────────────────────────────

  H.check("commit: web hands the commit URL to the opener, no window is made", function()
    reset_layout()
    git(proj, { "remote", "add", "origin", "https://github.com/WKDSteve/proj.nvim.git" })
    require("lib.nvim.git.commit_ref").clear_cache()
    local opened = {}
    H.with_modules({
      ["gopath.external"] = {
        open = function(url)
          opened[#opened + 1] = url
        end,
      },
    }, function()
      local wins = #vim.api.nvim_tabpage_list_wins(0)
      OPEN_COMMIT.open(result_for(second:sub(1, 8)), "web")
      wait(function()
        return #opened > 0
      end, "the opener")
      H.eq(opened[1], "https://github.com/WKDSteve/proj.nvim/commit/" .. second)
      H.eq(#vim.api.nvim_tabpage_list_wins(0), wins, "no window")
    end)
    git(proj, { "remote", "remove", "origin" })
    require("lib.nvim.git.commit_ref").clear_cache()
  end)

  H.check("commit: web without a remote only says so", function()
    reset_layout()
    local opened, messages = {}, {}
    H.with_modules({
      ["gopath.external"] = {
        open = function(url)
          opened[#opened + 1] = url
        end,
      },
    }, function()
      H.with_field(vim, "notify", function(msg)
        messages[#messages + 1] = tostring(msg)
      end, function()
        OPEN_COMMIT.open(result_for(second:sub(1, 8)), "web")
        wait(function()
          return #messages > 0
        end, "the message")
      end)
    end)
    H.eq(#opened, 0, "the opener was not called")
    H.match(messages[1], "no web URL", "the message says why")
    H.match(messages[1], "no remote", "...and that the repository has no remote")
  end)

  -- ── a commit the repository lacks ──────────────────────────────────────────

  H.check("commit: a missing commit offers to fetch it, and shows it once fetched", function()
    reset_layout()
    local origin = repos .. "/origin-src"
    H.mkdir(origin)
    git(origin, { "init", "-q", "-b", "main" })
    H.write(origin .. "/o.txt", { "o" })
    local o1 = commit(origin, "origin one")
    local clone = repos .. "/clone.nvim"
    H.mkdir(clone)
    git(clone, { "init", "-q", "-b", "main" })
    git(clone, { "remote", "add", "origin", origin })

    local offered
    H.with_modules({ ["ui.kit"] = false }, function()
      H.with_field(vim.ui, "select", function(items, _, on_choice)
        offered = vim.deepcopy(items)
        on_choice("fetch")
      end, function()
        OPEN_COMMIT.open({
          kind = "commit",
          path = o1:sub(1, 8),
          commit = { sha = o1:sub(1, 8), dir = clone },
        }, "current")
        wait(function()
          local info = vim.b.gopath_commit
          return type(info) == "table" and info.full == o1
        end, "the fetched commit")
      end)
    end)
    H.same(offered, { "fetch" }, "fetch only: the remote is a path, there is no web page")
    H.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "commit " .. o1)
    reset_layout()
  end)

  H.check("commit: a dismissed offer opens nothing", function()
    reset_layout()
    local before = vim.api.nvim_get_current_buf()
    H.with_modules({ ["ui.kit"] = false }, function()
      H.with_field(vim.ui, "select", function(_, _, on_choice)
        on_choice(nil)
      end, function()
        OPEN_COMMIT.open(result_for("abcdef0123"), "current")
        vim.wait(1500, function()
          return vim.api.nvim_get_current_buf() ~= before
        end, 20)
      end)
    end)
    H.eq(vim.api.nvim_get_current_buf(), before)
  end)

  -- ── from the diff to the file ──────────────────────────────────────────────

  H.check("commit: a diff line of the show buffer jumps to the file in the repo", function()
    reset_layout()
    OPEN_COMMIT.open(result_for(second:sub(1, 8)), "current")
    wait(in_show_buffer, "the show buffer")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for _, anchor in ipairs({ "diff --git a/f.txt", "+++ b/f.txt", "--- a/f.txt" }) do
      local row
      for i, l in ipairs(lines) do
        if vim.startswith(l, anchor) then row = i end
      end
      H.truthy(row, "the diff has " .. anchor)
      H.cursor_on(row, anchor:sub(1, 4))
      local r = COMMIT.resolve_in_show()
      H.truthy(r, anchor)
      H.eq(r.kind, "file")
      H.eq(r.path, (proj .. "/f.txt"):gsub("\\", "/"))
      H.eq(r.exists, true)
    end
    H.eq(
      require("gopath.resolve").resolve_at_cursor({}).path,
      (proj .. "/f.txt"):gsub("\\", "/"),
      "the pipeline goes the same way"
    )
    reset_layout()
  end)

  H.check(
    "commit: a file the work tree lost is read from the commit (the parent if deleted)",
    function()
      reset_layout()
      OPEN_COMMIT.open(result_for(second:sub(1, 8)), "current")
      wait(in_show_buffer, "the show buffer")
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local row
      for i, l in ipairs(lines) do
        if vim.startswith(l, "--- a/gone.txt") then row = i end
      end
      H.truthy(row, "the diff deletes gone.txt")
      H.cursor_on(row, "--- a/gone")
      local r = COMMIT.resolve_in_show()
      H.truthy(r)
      H.eq(r.kind, "commit_file")
      H.eq(r.commit_file.rev, second .. "^", "a deleted file lives in the parent")
      require("gopath.open").open(r, "edit")
      wait(function()
        return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "will be deleted"
      end, "the old content")
      H.eq(vim.bo.modifiable, false)
      reset_layout()
    end
  )

  H.check("commit: the show buffer's own commit line is a commit again", function()
    reset_layout()
    OPEN_COMMIT.open(result_for(second:sub(1, 8)), "current")
    wait(in_show_buffer, "the show buffer")
    H.cursor_on(1, second:sub(1, 10))
    local r = COMMIT.resolve()
    H.truthy(r)
    H.eq(r.commit.sha, second)
    reset_layout()
  end)

  H.check(
    "commit: gP (goto_at_cursor) on repo@hash opens the float, ask_commit takes a target",
    function()
      reset_layout()
      config.setup({})
      H.line_at(("see proj.nvim@%s in the log"):format(second:sub(1, 8)), "proj.nvim@", {
        filetype = "markdown",
      })
      require("gopath.commands").goto_at_cursor("edit")
      wait(in_show_buffer, "the float from gP")
      H.truthy(vim.api.nvim_win_get_config(0).relative ~= "", "gP: a float by default")
      vim.cmd("normal q")

      reset_layout()
      H.line_at(("see proj.nvim@%s in the log"):format(second:sub(1, 8)), "proj.nvim@", {
        filetype = "markdown",
      })
      local tabs = #vim.api.nvim_list_tabpages()
      require("gopath.commands").ask_commit("tab")
      wait(in_show_buffer, "the tab from ask_commit")
      H.eq(#vim.api.nvim_list_tabpages(), tabs + 1, "ask_commit(target) skips the question")
      reset_layout()

      H.line_at("no hash here", "hash", { filetype = "markdown" })
      local seen
      H.with_field(vim, "notify", function(msg)
        seen = tostring(msg)
      end, function()
        require("gopath.commands").ask_commit()
      end)
      H.match(seen or "", "no commit hash", "without a hash it says so")
    end
  )

  vim.env.REPOS_DIR = saved_repos_dir
end
