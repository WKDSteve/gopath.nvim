---@module 'gopath.resolvers.common.task_id'
---@brief A task id under the cursor (`<area>/<slug>`), resolved to the task file through tasks.nvim.
---@description
--- A to-do list, a commit message or a handover names tasks by id. `gF` on one opens the task file: the open task in
--- `ROADMAP/tasks/`, or the finished one in `Backlog/`. A group symbol (`[[group/<name>]]`, cursor on the name) opens
--- the file that explains the group (`ALL/groups/<name>.md` of a vault), at the line tasks.nvim names.
---
--- **All the knowledge is tasks.nvim's.** What an id looks like, where a vault is, which areas exist and where an open
--- or a finished task lives is answered by `tasks_nvim.resolve`; this module only turns its targets into a
--- `GopathResult`. That is also what keeps it from misreading a path: `lua/gopath` in `lua/gopath/init.lua` is not
--- an id there (a second `/`), and `docs/api` is not one either unless a vault has an area `docs` with that task.
---
--- **A soft dependency.** Without tasks.nvim (`pcall(require, "tasks_nvim.resolve")` fails) the resolver answers
--- nil, says nothing and costs one failed `require`, once. With `tasks.enable = false` it is not asked at all.
---
--- **Several targets are offered, not guessed.** The same id can name an open and a finished task (after a reopen),
--- or a task in two of `tasks.vaults`. The result then carries `alternatives`, one `GopathResult` per target, and
--- `gopath.commands` asks which one to open (`M.pick`).

local C = require("gopath.config")

local M = {}

---@type table|nil  tasks.nvim's resolver, once found
local _resolver = nil
---@type string|nil  the 'runtimepath' the last failed `require` looked through
local _missing_rtp = nil

---tasks.nvim's resolver, or nil.
---
---A miss is remembered only for the 'runtimepath' it was looked for in: a
---failed `require` walks the whole path, and hover.nvim asks on every pause of
---the cursor. A plugin that is added later (`packadd`, a lazy load on a
---command) changes 'runtimepath', so it is found on the next lookup rather
---than after a restart.
---@return table|nil
local function resolver()
  if _resolver then return _resolver end
  local rtp = vim.o.runtimepath
  if _missing_rtp == rtp and not package.loaded["tasks_nvim.resolve"] then return nil end
  local ok, mod = pcall(require, "tasks_nvim.resolve")
  if ok and type(mod) == "table" and type(mod.resolve_at) == "function" then
    _resolver, _missing_rtp = mod, nil
    return mod
  end
  _missing_rtp = rtp
  return nil
end

---`tasks.vaults` with `~` and environment variables expanded: tasks.nvim takes
---each entry as a path as written, and an unexpanded one names no directory.
---@param vaults any
---@return string[]|nil
local function expand_vaults(vaults)
  if type(vaults) ~= "table" then return nil end
  local out = {}
  for _, v in ipairs(vaults) do
    if type(v) == "string" and v ~= "" then
      -- `${VAR}` first: gopath reads it everywhere else, `vim.fs.normalize` only
      -- knows `$VAR`. A relative entry stays relative to the working directory.
      out[#out + 1] = vim.fs.normalize((v:gsub("%${([%w_]+)}", "$%1")))
    end
  end
  return out
end

---Whether the text under the cursor has the shape of a task id at all: one
---run of path characters with exactly one `/` inside it. A copy of the run
---and trim rules of `tasks_nvim.resolve.token_at` (tasks.nvim), kept at least
---as wide: if those widen, widen these, or ids that tasks.nvim would resolve
---are never asked about. A cheap test before
---tasks.nvim is asked -- and, under lazy.nvim, before asking it loads it:
---step 2.5 runs for every resolve, hover.nvim's included, and most of them are
---on a word or a path.
---@return boolean
local function looks_like_id()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local run = "[%w_.%-/]"
  if not line:sub(col, col):match(run) then return false end
  local s, e = col, col
  while s > 1 and line:sub(s - 1, s - 1):match(run) do
    s = s - 1
  end
  while e < #line and line:sub(e + 1, e + 1):match(run) do
    e = e + 1
  end
  local token = line:sub(s, e):gsub("^_+", ""):gsub("[._]+$", "")
  return token:match("^[^/]+/[^/]+$") ~= nil
end

---@param target table  a `Tasks.ResolveTarget`
---@return GopathResult
local function result_of(target)
  return {
    kind = "file",
    path = (target.path or ""):gsub("\\", "/"),
    language = vim.bo.filetype or "text",
    range = { line = target.line or 1, col = 1 },
    chain = nil,
    source = "tasks",
    confidence = 0.95,
    exists = true,
    task = {
      id = target.id,
      kind = target.kind,
      title = target.title,
      root = target.root,
      date = target.date,
    },
  }
end

---The task id under the cursor as a result, or nil (no id there, an id no vault knows, tasks.nvim missing, the
---feature off). With several targets the first is the result and `alternatives` lists all of them.
---@return GopathResult|nil
function M.resolve()
  local cfg = C.get().tasks
  if cfg == false or (type(cfg) == "table" and cfg.enable == false) then return nil end
  if not looks_like_id() then return nil end
  local mod = resolver()
  if not mod then return nil end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local roots = type(cfg) == "table" and expand_vaults(cfg.vaults) or nil
  local ok, targets = pcall(mod.resolve_at, 0, row, col, { roots = roots })
  if not ok or type(targets) ~= "table" or #targets == 0 then return nil end
  local first = result_of(targets[1])
  if #targets > 1 then
    local all = {}
    for i, t in ipairs(targets) do
      all[i] = result_of(t)
    end
    first.alternatives = all
  end
  return first
end

---`path` relative to the vault `root` (forward slashes), or `path` itself when it lies elsewhere.
---@param path string
---@param root string|nil
---@return string
local function relative_to(path, root)
  path = path:gsub("\\", "/")
  if not root or root == "" then return path end
  root = root:gsub("\\", "/"):gsub("/+$", "")
  if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
  return path
end

---What tells `res` apart from the other targets of the same id and kind: a finished task's day
---(`date`) when every one of them has its own, else the path relative to the vault (file or folder).
---nil when it is the only one of its kind.
---@param res GopathResult
---@param all GopathResult[]
---@return string|nil
local function distinction(res, all)
  local t = res.task or {}
  local peers = {}
  for _, other in ipairs(all) do
    local o = other.task or {}
    if o.id == t.id and o.kind == t.kind then peers[#peers + 1] = other end
  end
  if #peers < 2 then return nil end
  if t.kind == "done" and t.date then
    local seen, distinct = {}, true
    for _, other in ipairs(peers) do
      local d = (other.task or {}).date
      if not d or seen[d] then distinct = false end
      seen[d or ""] = true
    end
    if distinct then return t.date end
  end
  return relative_to(res.path or "", t.root)
end

---@param res GopathResult
---@param all GopathResult[]|nil  every target offered, to tell same-looking ones apart
---@return string
local function label(res, all)
  local t = res.task or {}
  local where = t.kind == "done" and "finished" or t.kind == "group" and "group" or "open"
  local extra = distinction(res, all or { res })
  if extra then where = where .. " " .. extra end
  return ("%s  %s (%s)  %s"):format(t.id or "?", t.title or "", where, t.root or "")
end

---Ask which of `res.alternatives` to open; `on_choice(nil)` when the picker is dismissed.
---@param res GopathResult
---@param on_choice fun(choice: GopathResult|nil)
---@return nil
function M.pick(res, on_choice)
  local items = res.alternatives or { res }
  local ok_kit, kit = pcall(require, "ui.kit")
  if ok_kit and type(kit.select) == "function" then
    kit.select({
      items = items,
      title = "gopath: task id in several places — pick one",
      format_item = function(item)
        return label(item, items)
      end,
      on_select = on_choice,
      on_cancel = function()
        on_choice(nil)
      end,
    })
    return
  end
  vim.ui.select(items, {
    prompt = "gopath: task id in several places — pick one",
    format_item = function(item)
      return label(item, items)
    end,
  }, on_choice)
end

---Forget whether tasks.nvim was found. For the specs.
---@return nil
function M._reset()
  _resolver, _missing_rtp = nil, nil
end

---Whether task ids can resolve, and why not when they cannot: for `:checkhealth`.
---`level` is how the report should rate it: `ok`, `info` (off on purpose, or
---the soft dependency simply absent) or `warn` (installed, and still nothing
---to resolve against).
---@return boolean ok
---@return string message
---@return "ok"|"info"|"warn" level
function M.status()
  local cfg = C.get().tasks
  if cfg == false or (type(cfg) == "table" and cfg.enable == false) then
    return false, "task ids are not resolved (tasks = false / tasks.enable = false)", "info"
  end
  if not resolver() then
    local vaults_wanted = type(cfg) == "table" and type(cfg.vaults) == "table" and #cfg.vaults > 0
    if pcall(require, "tasks_nvim") then
      -- "not found": tasks.nvim predates the resolver. Anything else: it is there and
      -- fails to load, and the error is the thing to read.
      local ok_res, res_err = pcall(require, "tasks_nvim.resolve")
      local absent = not ok_res and tostring(res_err):find("not found", 1, true) ~= nil
      return false,
        (ok_res or absent)
            and "tasks.nvim is too old: it has no usable tasks_nvim.resolve — update it to resolve task ids"
          or ("tasks.nvim's resolver does not load: " .. tostring(res_err)),
        "warn"
    end
    -- Named vaults say the feature is wanted: then a missing tasks.nvim is a problem.
    return false,
      "tasks.nvim not installed — task ids are read as paths",
      vaults_wanted and "warn" or "info"
  end
  local vaults = type(cfg) == "table" and expand_vaults(cfg.vaults) or nil
  if vaults and #vaults > 0 then
    local missing = {}
    for _, v in ipairs(vaults) do
      if vim.fn.isdirectory(v) ~= 1 then missing[#missing + 1] = v end
    end
    if #missing == #vaults then
      return false, "none of tasks.vaults is a directory: " .. table.concat(missing, ", "), "warn"
    end
    if #missing > 0 then
      return true,
        "task ids resolve; these tasks.vaults are no directory: " .. table.concat(missing, ", "),
        "warn"
    end
    return true,
      "gF on a task id (<area>/<slug>) opens the task file, in " .. #vaults .. " vault(s)",
      "ok"
  end
  -- pcall'd: a broken or future tasks.nvim that raises here must not take the
  -- rest of `:checkhealth gopath` down with it.
  local ok_vault, vault = pcall(require, "tasks_nvim.vault")
  local root, why
  if ok_vault and type(vault.root) == "function" then
    local ok_root, r, err = pcall(vault.root)
    root, why = ok_root and r or nil, ok_root and err or r
  end
  if not root then
    return false,
      ("tasks.nvim has no usable vault (%s) and tasks.vaults is empty — nothing to resolve against"):format(
        tostring(why or "no setup({ vault = ... }), no $TASKS_VAULT")
      ),
      "warn"
  end
  return true, "gF on a task id (<area>/<slug>) opens the task file, in " .. tostring(root), "ok"
end

return M
