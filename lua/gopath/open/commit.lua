---@module 'gopath.open.commit'
---@brief Open a commit result: on the web, or as `git show` in a split, vsplit, tab, float or the current window.
---@description
--- `M.open(res, mode)` is what `gopath.open` calls for a result of kind "commit" (`gopath.resolvers.common.commit`).
--- The window mode of the mapping picks the target: `gP` (edit) opens `commit.open` from the config (default
--- "float"), `g|` a split, `g\` a vsplit, `g}` a tab. `M.ask(res)` lets the user choose.
---
--- The repository and the commit are found asynchronously through `lib.nvim.git.commit_ref`; nothing here blocks the
--- editor. A commit the repository does not have offers to fetch it or to open it on the web (when the remote has a
--- known web host); with no remote URL there is only the message.
---
--- The `git show` buffer is a scratch buffer (`filetype=git`, read-only, wiped when hidden) with `q` to close it. It
--- carries `vim.b.gopath_commit = { dir, full }`, which is what lets gopath jump from a file line of the diff to the
--- file (`gopath.resolvers.common.commit.resolve_in_show`).

local C = require("gopath.config")
local LOG = require("gopath.util.log")

local M = {}

---@alias GopathCommitTarget "web"|"float"|"split"|"vsplit"|"tab"|"current"

---Targets in the order the picker offers them.
M.TARGETS = { "web", "float", "split", "vsplit", "tab", "current" }

local LABELS = {
  web = "On the web (browser)",
  float = "In a floating window",
  split = "In a horizontal split",
  vsplit = "In a vertical split",
  tab = "In a new tab",
  current = "In the current window",
}

---@param mode string|nil  a window mode of `gopath.open` ("edit", "window", "vsplit", "tab", ...)
---@return GopathCommitTarget
local function target_of(mode)
  if mode == "window" then return "split" end
  if mode == "vsplit" or mode == "tab" then return mode end
  local cfg = C.get().commit
  local default = type(cfg) == "table" and cfg.open or "float"
  if vim.tbl_contains(M.TARGETS, default) then return default end
  return "float"
end

---`select` through ui.kit when it is there, else `vim.ui.select`.
---@generic T
---@param items T[]
---@param title string
---@param format_item fun(item: T): string
---@param on_choice fun(choice: T|nil)
local function select(items, title, format_item, on_choice)
  local ok_kit, kit = pcall(require, "ui.kit")
  if ok_kit and type(kit.select) == "function" then
    kit.select({
      items = items,
      title = title,
      format_item = format_item,
      on_select = on_choice,
      on_cancel = function()
        on_choice(nil)
      end,
    })
    return
  end
  vim.ui.select(items, { prompt = title, format_item = format_item }, on_choice)
end

---Close the window or buffer of a commit view with `q`.
---@param buf integer
---@param close fun()
local function map_close(buf, close)
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "close the commit view" })
end

---A scratch buffer holding `lines`, marked as the view of `res`.
---@param lines string[]
---@param full string
---@param dir string
---@param name string
---@return integer buf
local function make_buffer(lines, full, dir, name)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "git"
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].gopath_commit = { dir = dir, full = full }
  return buf
end

---Show `buf` the way `target` says.
---@param buf integer
---@param target GopathCommitTarget
---@param title string
local function show_buffer(buf, target, title)
  if target == "float" then
    local width = math.max(60, math.floor(vim.o.columns * 0.8))
    local height = math.max(10, math.floor((vim.o.lines - vim.o.cmdheight) * 0.8))
    width, height = math.min(width, vim.o.columns - 2), math.min(height, vim.o.lines - 4)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      style = "minimal",
      border = "rounded",
      title = " " .. title .. " ",
      title_pos = "center",
    })
    map_close(buf, function()
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    end)
    return
  end
  if target == "split" then
    vim.cmd.split()
  elseif target == "vsplit" then
    vim.cmd.vsplit()
  elseif target == "tab" then
    vim.cmd.tabnew()
  end
  local win = vim.api.nvim_get_current_win()
  local prev = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, buf)
  if target == "split" or target == "vsplit" or target == "tab" then
    -- The empty buffer `tabnew` made is of no use once the view replaced it; one a window still shows is not ours.
    if
      prev ~= buf
      and vim.api.nvim_buf_is_valid(prev)
      and #vim.fn.win_findbuf(prev) == 0
      and vim.bo[prev].buftype == ""
      and vim.api.nvim_buf_get_name(prev) == ""
      and not vim.bo[prev].modified
    then
      pcall(vim.api.nvim_buf_delete, prev, { force = true })
    end
    map_close(buf, function()
      if #vim.api.nvim_tabpage_list_wins(0) > 1 or #vim.api.nvim_list_tabpages() > 1 then
        pcall(vim.cmd.close)
      else
        pcall(vim.cmd.bwipeout)
      end
    end)
  else
    map_close(buf, function()
      pcall(vim.cmd, "bprevious")
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end)
  end
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

---Open `resolved` (a `local` resolution) in `target`.
---@param resolved table  Lib.Git.CommitRefResolved
---@param target GopathCommitTarget
local function open_local(resolved, target)
  local cr = require("lib.nvim.git.commit_ref")
  if target == "web" then
    if resolved.url then
      require("gopath.external").open(resolved.url)
    else
      LOG.warn(
        ("commit %s has no web URL: %s"):format(
          resolved.sha,
          resolved.remote and "the remote's host is not a known one (see lib.nvim git.remote hosts)"
            or "the repository has no remote"
        )
      )
    end
    return
  end
  cr.lines_async(resolved, { patch = true }, function(lines, err)
    if not lines then
      LOG.error("git show failed: " .. tostring(err))
      return
    end
    local short = resolved.full:sub(1, 8)
    local repo = vim.fs.basename(resolved.dir)
    local buf =
      make_buffer(lines, resolved.full, resolved.dir, ("gopath://commit/%s/%s"):format(repo, short))
    show_buffer(buf, target, ("%s@%s"):format(repo, short))
  end)
end

---Resolve `commit` and act on the outcome. `again` is set after a fetch, so a second miss does not offer it again.
---@param commit { sha: string, repo?: string, to?: string, dir?: string }
---@param target GopathCommitTarget
---@param again boolean|nil
local function resolve_and_open(commit, target, again)
  local cr = require("lib.nvim.git.commit_ref")
  cr.resolve_async(
    { sha = commit.sha, repo = commit.repo, to = commit.to },
    { dir = commit.dir },
    function(res)
      if res.status == "local" then return open_local(res, target) end
      local what = commit.repo and ("%s@%s"):format(commit.repo, commit.sha) or commit.sha
      if res.status == "no_repo" then
        LOG.warn(("commit %s: %s"):format(what, res.err or "no repository"))
        return
      end
      if res.status == "ambiguous" then
        LOG.warn(
          ("commit %s: more than one commit starts with this; write more digits"):format(what)
        )
        return
      end
      -- missing: offer to fetch it, or to open it on the web, when that is possible
      cr.url_async(res, { dir = commit.dir }, function(url)
        local choices = {}
        if not again then choices[#choices + 1] = "fetch" end
        if url then choices[#choices + 1] = "web" end
        if #choices == 0 then
          LOG.warn(
            ("commit %s is not in %s%s"):format(
              what,
              vim.fs.basename(res.dir or "?"),
              url and "" or " (no remote URL to open it on)"
            )
          )
          return
        end
        local texts = {
          fetch = "Fetch it from the remote",
          web = "Open it on the web instead",
        }
        select(
          choices,
          ("gopath: commit %s is not in %s"):format(what, vim.fs.basename(res.dir or "?")),
          function(c)
            return texts[c]
          end,
          function(choice)
            if choice == "web" then
              require("gopath.external").open(url)
            elseif choice == "fetch" then
              LOG.info("fetching " .. what .. " …")
              cr.fetch_async(res, {}, function(ok, err)
                if not ok then
                  LOG.warn(("fetch failed: %s"):format(tostring(err)))
                  if url then LOG.info("it can still be opened on the web: " .. url) end
                  return
                end
                resolve_and_open(commit, target, true)
              end)
            end
          end
        )
      end)
    end
  )
end

---Open the commit of `res`.
---@param res GopathResult  kind "commit"
---@param mode string|nil  a `gopath.open` window mode, or a `GopathCommitTarget`
function M.open(res, mode)
  local commit = res and res.commit
  if type(commit) ~= "table" or not commit.sha then return end
  local target = vim.tbl_contains(M.TARGETS, mode) and mode or target_of(mode)
  resolve_and_open(commit, target)
end

---Ask where to open the commit of `res`, then open it.
---@param res GopathResult  kind "commit"
function M.ask(res)
  select(M.TARGETS, "gopath: open commit " .. tostring(res and res.path or "?"), function(t)
    return LABELS[t]
  end, function(choice)
    if choice then M.open(res, choice) end
  end)
end

---Open a file of a commit (`res.kind == "commit_file"`): the work tree no longer has it, so it is read from the
---commit (`git show <rev>:<path>`) into a read-only buffer.
---@param res GopathResult
---@param mode string|nil
function M.open_file(res, mode)
  local cf = res and res.commit_file
  if type(cf) ~= "table" then return end
  local git = require("lib.nvim.git")
  git.run_async(
    { "show", "--no-color", cf.rev .. ":" .. cf.relpath },
    { dir = cf.dir, no_lazy_fetch = true, timeout_ms = 10000 },
    function(r)
      if not r.ok then
        LOG.warn(
          ("cannot read %s at %s: %s"):format(
            cf.relpath,
            cf.rev:sub(1, 8),
            vim.trim(r.stderr or "")
          )
        )
        return
      end
      local lines = vim.split((r.stdout:gsub("\r\n", "\n"):gsub("\n$", "")), "\n", { plain = true })
      local buf = vim.api.nvim_create_buf(false, true)
      pcall(
        vim.api.nvim_buf_set_name,
        buf,
        ("gopath://commit-file/%s:%s"):format(cf.rev:sub(1, 8), cf.relpath)
      )
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local ft = vim.filetype.match({ filename = cf.relpath })
      if ft then vim.bo[buf].filetype = ft end
      vim.bo[buf].modifiable = false
      vim.bo[buf].readonly = true
      vim.bo[buf].bufhidden = "wipe"
      if mode == "window" then
        vim.cmd.split()
      elseif mode == "vsplit" then
        vim.cmd.vsplit()
      elseif mode == "tab" then
        vim.cmd.tabnew()
      end
      vim.api.nvim_win_set_buf(0, buf)
      LOG.info(
        ("%s is not in the work tree: showing it as of %s"):format(cf.relpath, cf.rev:sub(1, 8))
      )
    end
  )
end

return M
