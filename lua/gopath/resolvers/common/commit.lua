---@module 'gopath.resolvers.common.commit'
---@brief A commit hash under the cursor (`a02ddae`, `repo@a02ddae`) as a result of kind "commit".
---@description
--- Two stages share this module:
---
---   * `resolve()`: the token under the cursor has the form of a commit reference. Only the FORM is read here (no git,
---     no process): what a reference is comes from `lib.nvim.git.commit_ref`, the repository and the commit are looked
---     up when the result is opened (`gopath.open.commit`), asynchronously. A bare hash needs 7 to 40 hex digits with at
---     least one digit and one letter, so a word such as `deadbeef` or a number is never taken; `repo@` makes the form
---     explicit. A file on disk with the same spelling wins (a path is never taken for a commit).
---   * `resolve_in_show()`: in a `git show` buffer that `gopath.open.commit` made (`vim.b.gopath_commit`), a file line
---     (`diff --git a/x b/x`, `+++ b/x`, `--- a/x`) is the file in the repository. A file the work tree no longer has is
---     read from the commit instead (the parent for a file the commit deleted): result kind "commit_file".
---
--- Both are soft: without lib.nvim's `git.commit_ref` the stages answer nil.

local C = require("gopath.config")

local M = {}

---`commit_ref`, or nil (an older lib.nvim).
---@return table|nil
local function commit_ref()
  local ok, mod = pcall(require, "lib.nvim.git.commit_ref")
  if ok and type(mod) == "table" and type(mod.token_at) == "function" then return mod end
  return nil
end

---@return boolean
local function enabled()
  local cfg = C.get().commit
  return not (cfg == false or (type(cfg) == "table" and cfg.enable == false))
end

---Directory of the current buffer (its file's, else the cwd).
---@return string
local function buffer_dir()
  local name = vim.api.nvim_buf_get_name(0)
  local b = vim.b.gopath_commit
  if type(b) == "table" and type(b.dir) == "string" then return b.dir end
  if name ~= "" and vim.uv.fs_stat(name) then return vim.fs.dirname(name) end
  return vim.uv.cwd() or "."
end

---A commit reference under the cursor as a result, or nil.
---@return GopathResult|nil
function M.resolve()
  if not enabled() then return nil end
  local line = vim.api.nvim_get_current_line()
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  -- Cheap pre-check before `require`: a reference has at least 7 hex digits in a row.
  if not line:find("%x%x%x%x%x%x%x") then return nil end
  local mod = commit_ref()
  if not mod then return nil end
  local ref = mod.token_at(line, col0 + 1)
  if not ref then return nil end
  local text = line:sub(ref.first, ref.last)
  local dir = buffer_dir()
  -- A file (or directory) spelled like the token is that file, not a commit.
  if vim.uv.fs_stat(vim.fs.joinpath(dir, text)) then return nil end
  return {
    kind = "commit",
    path = text,
    language = vim.bo.filetype or "text",
    range = { line = row, col = ref.first },
    chain = nil,
    source = "commit",
    confidence = 0.9,
    exists = true,
    commit = { sha = ref.sha, repo = ref.repo, to = ref.to, dir = dir },
  }
end

---The path of a file line of `git show` / `git diff` output, with the side it names.
---@param line string
---@return string|nil path
---@return "new"|"old"|nil side
local function file_of_line(line)
  local _, new = line:match("^diff %-%-git a/(.-) b/(.+)$")
  if new then return new, "new" end
  new = line:match("^%+%+%+ b/(.+)$")
  if new then return new, "new" end
  local old = line:match("^%-%-%- a/(.+)$")
  if old then return old, "old" end
  return nil, nil
end

---Whether the commit of a `git show` buffer deleted `path` (the diff's new side is /dev/null).
---@param buf integer
---@param path string
---@return boolean
local function deleted_in_commit(buf, path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l == ("--- a/" .. path) and lines[i + 1] == "+++ /dev/null" then return true end
  end
  return false
end

---The file named by the file line under the cursor of a `git show` buffer, or nil.
---@return GopathResult|nil
function M.resolve_in_show()
  if not enabled() then return nil end
  local info = vim.b.gopath_commit
  if type(info) ~= "table" or type(info.dir) ~= "string" or type(info.full) ~= "string" then
    return nil
  end
  local line = vim.api.nvim_get_current_line()
  local path = file_of_line(line)
  if not path then return nil end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local abs = vim.fs.joinpath(info.dir, path):gsub("\\", "/")
  if vim.uv.fs_stat(abs) then
    return {
      kind = "file",
      path = abs,
      language = vim.bo.filetype or "text",
      range = { line = 1, col = 1 },
      chain = nil,
      source = "commit",
      confidence = 0.95,
      exists = true,
    }
  end
  return {
    kind = "commit_file",
    path = abs,
    language = vim.bo.filetype or "text",
    range = { line = row, col = 1 },
    chain = nil,
    source = "commit",
    confidence = 0.8,
    exists = true,
    commit_file = {
      dir = info.dir,
      -- A file the commit deleted exists only in its parent.
      rev = deleted_in_commit(0, path) and (info.full .. "^") or info.full,
      relpath = path,
    },
  }
end

return M
