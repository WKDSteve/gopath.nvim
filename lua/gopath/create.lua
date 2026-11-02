---@module 'gopath.create'
---@brief Offer to create a resolved-but-missing file, then hand it back to the caller.
---@description
--- Used by `gopath.open` (passive: gP/g|/g\/g}, honors `create_on_missing.enable`)
--- and by the dedicated `check` keymap/command (explicit user action, always offers
--- regardless of `create_on_missing.enable`; see `gopath.commands.check_under_cursor`).
---
--- A directory can't be opened in an editor buffer the way a file can. Two distinct
--- cases fall out of that:
---   1. The resolved path itself IS an existing directory (`M.offer` detects this
---      up front, independent of `create_on_missing`/`confirm`, since it is not a
---      "missing" case at all): the dialog offers "Create file in this folder"
---      (asks for a name, then creates it there) and, when filetree.nvim is
---      installed, "Open in filetree" for that same directory.
---   2. The resolved path does not exist, but has an existing ANCESTOR directory:
---      the dialog (lib.nvim's `ui.kit.create_on_missing`) offers Create (the
---      resolved path itself, parents included) and, when filetree.nvim is
---      installed, "Open in filetree" for the nearest existing ancestor —
---      instead of silently `:edit`-ing a path that used to dump you into
---      netrw with no warning.
---
--- The directory prompt (case 1) uses ui.nvim's `ui.kit.confirm` when present
--- (soft dependency, same convention as `gopath.util.cross` / `gopath.util.log`)
--- and falls back to `vim.ui.select`.

local LOG = require("gopath.util.log")
local CROSS = require("gopath.util.cross")
local PATH = require("gopath.util.path")
local FILETREE_UTIL = require("gopath.util.filetree")

local M = {}

local create_entry = require("lib.nvim.fs.create_entry")
local create_on_missing = require("lib.nvim.ui.kit.create_on_missing")

-- lib.nvim is gopath's hard dependency (see bindings/keymaps.lua); its
-- `fs.create_entry` backs the silent/no-dialog creation below, and
-- `ui.kit.create_on_missing` owns the dialog for a missing path.

-- ── File creation ────────────────────────────────────────────────────────────

---Create an empty file at `path` WITHOUT asking (`confirm = false`, and the
---explicit "Create file in this folder" name prompt); parent directories are
---created as needed. A missing path that needs asking goes through
---`ui.kit.create_on_missing` instead (see `M.offer`).
---@internal
---@param path string
---@return boolean ok
---@return string|nil err
local function touch(path)
  local native = CROSS.to_native(path)
  local dir = vim.fn.fnamemodify(native, ":h")
  local name = vim.fn.fnamemodify(native, ":t")
  local ok, _, path_or_err = create_entry(dir, name)
  if not ok then return false, path_or_err end
  -- The path searches cache directory listings; a file created now would
  -- otherwise stay invisible to the next lookup until those caches expire.
  PATH.invalidate_caches()
  return true, nil
end

-- ── filetree.nvim (soft dependency) ──────────────────────────────────────────

---Set cwd to `dir` and hand it to filetree.nvim's tree (rooted + focused there).
---@internal
---@param dir string
---@return boolean opened
local function open_in_filetree(dir)
  local adapter = FILETREE_UTIL.adapter()
  if not adapter then
    LOG.warn("filetree.nvim not available — could not open: " .. dir)
    return false
  end
  local ok_cd = pcall(vim.cmd.cd, vim.fn.fnameescape(dir))
  if not ok_cd then LOG.warn("Could not set cwd to: " .. dir) end
  local opened = false
  if type(adapter.toggle_at) == "function" then
    opened = adapter.toggle_at("left", { dir = dir }) and true or false
  end
  if not opened and type(adapter.set_root) == "function" then
    opened = adapter.set_root(dir) and true or false
  end
  if opened then
    LOG.info("Opened in filetree: " .. dir)
  else
    LOG.error("Could not open in filetree: " .. dir)
  end
  return opened
end

-- ── Confirm dialog (ui.kit, soft dependency) ────────────────────────

---@type table|nil  ui.kit module, or nil when unavailable
local kit
do
  local ok, mod = pcall(require, "ui.kit")
  if ok and type(mod) == "table" and type(mod.confirm) == "function" then
    kit = mod
  else
    kit = nil
    vim.schedule(function()
      LOG.debug(
        "optional dependency 'ui.nvim' not found — using vim.ui.select "
          .. "fallback for the create-on-missing prompt. Add it to your plugin "
          .. "spec (dependencies = { 'WKDSteve/ui.nvim' }) for the themed dialog."
      )
    end)
  end
end

---Ask the user to pick one of `choices` (button dialog via ui.kit, or
---vim.ui.select when ui.kit is unavailable).
---@internal
---@param question string
---@param choices string[]
---@param on_choice fun(choice: string|nil)  nil = cancelled
---@return nil
local function ask(question, choices, on_choice)
  if kit then
    kit.confirm({
      question = question,
      choices = choices,
      default = 1,
      on_answer = on_choice,
    })
    return
  end
  vim.ui.select(choices, { prompt = question }, function(choice)
    on_choice(choice)
  end)
end

---Ask the user for a single line of text (ui.kit's `input`, or vim.ui.input
---when ui.kit is unavailable / too old to provide it).
---@internal
---@param question string
---@param on_submit fun(text: string|nil)  nil = cancelled / empty
---@return nil
local function ask_input(question, on_submit)
  if kit and type(kit.input) == "function" then
    kit.input({ title = question, on_submit = on_submit })
    return
  end
  vim.ui.input({ prompt = question }, on_submit)
end

-- ── Public API ────────────────────────────────────────────────────────────────

local CREATE_HERE = "Create file in this folder"
local FILETREE = "Open in filetree"
local CANCEL = "Cancel"

---Whether `name` (a user-typed filename for "create in this folder") has a
---`..` path-traversal segment -- either separator, since the prompt takes
---whatever the user types verbatim. A subdirectory ("sub/new.lua") or even
---an absolute/drive path is still honoured as-is here -- filetree.nvim's own
---smart_create established that flexibility for the same kind of prompt, and
---an absolute path is at least explicit about where it lands. `..` is
---different: it silently walks OUT of the folder the dialog just named, into
---wherever that happens to land relative to `dir` -- not a folder the user
---ever saw or chose.
---@internal
---@param name string
---@return boolean
local function has_parent_traversal(name)
  for seg in name:gsub("\\", "/"):gmatch("[^/]+") do
    if seg == ".." then return true end
  end
  return false
end

---Offer a choice for a resolved path that is itself an existing directory
---(gopath can't `:edit` a directory as a file). Always asks, independent of
---`create_on_missing.enable`/`confirm` — this is not a "missing file" case.
---On "Create file in this folder": asks for a name, creates `<dir>/<name>`,
---and calls `on_created` with a copy of `res` pointed at that new file.
---On "Open in filetree" (only offered when filetree.nvim is installed + set
---up): hands `dir` to filetree.nvim; `on_created` is not called.
---@internal
---@param res GopathResult  res.path is a directory that exists on disk
---@param on_created fun(res: GopathResult)
---@return nil
local function offer_for_directory(res, on_created)
  local dir = res.path
  local choices = { CREATE_HERE }
  if FILETREE_UTIL.adapter() then choices[#choices + 1] = FILETREE end
  choices[#choices + 1] = CANCEL

  ask("gopath: '" .. tostring(dir) .. "' is a directory", choices, function(choice)
    if choice == CREATE_HERE then
      ask_input("New file name in " .. dir .. ": ", function(name)
        if not name or name == "" then
          LOG.warn("File not created: no name given")
          return
        end
        if has_parent_traversal(name) then
          LOG.warn("File not created: '" .. name .. "' contains '..' (would escape " .. dir .. ")")
          return
        end
        local target = PATH.join(dir, name)
        local ok, err = touch(target)
        if not ok then
          LOG.error("Could not create file: " .. tostring(err))
          return
        end
        LOG.info("Created: " .. target)
        on_created(vim.tbl_extend("force", res, { path = target, exists = true, kind = "file" }))
      end)
    elseif choice == FILETREE then
      open_in_filetree(dir)
    else
      LOG.warn("File not created: " .. tostring(dir))
    end
  end)
end

---Offer to create `res.path` when it does not exist, or (see
---`offer_for_directory`) a choice for it when it exists but is a directory.
---On "Create file": creates the file (+ parent dirs), marks `res.exists = true`
---and calls `on_created(res)` so the caller can open/jump into it.
---On "Open in filetree" (only offered when a nearest existing ancestor
---directory was found and filetree.nvim is installed + set up): hands that
---directory to filetree.nvim and sets it as cwd; `on_created` is not called.
---On decline / cancel / failure: notifies and does not call `on_created`.
---@param res GopathResult
---@param on_created fun(res: GopathResult)
---@param opts { force?: boolean }|nil  force=true bypasses `create_on_missing.enable`
--- (use for explicit user actions like the `check` keymap)
function M.offer(res, on_created, opts)
  opts = opts or {}

  if PATH.is_dir(res.path) then
    offer_for_directory(res, on_created)
    return
  end

  local cfg = require("gopath.config").get().create_on_missing or {}
  if cfg.enable == false and not opts.force then
    LOG.error("File not found: " .. tostring(res.path))
    return
  end

  if cfg.confirm == false then
    -- Silent mode: skip the dialog and create directly.
    local ok, err = touch(res.path)
    if not ok then
      LOG.error("Could not create file: " .. tostring(err))
      return
    end
    res.exists = true
    LOG.info("Created: " .. tostring(res.path))
    on_created(res)
    return
  end

  -- The dialog (Create with parents / Open in filetree / Cancel) is lib.nvim's
  -- `ui.kit.create_on_missing`; gopath only says what happens afterwards.
  create_on_missing.open({
    path = res.path,
    title = "gopath: file not found",
    open = function()
      PATH.invalidate_caches()
      res.exists = true
      LOG.info("Created: " .. tostring(res.path))
      on_created(res)
    end,
    -- Reveal through gopath's own adapter (sets cwd, roots the tree); no
    -- button when filetree.nvim is not installed.
    filetree = FILETREE_UTIL.adapter() and open_in_filetree or false,
    on_done = function(result)
      if result.action == "cancelled" then LOG.warn("File not created: " .. tostring(res.path)) end
    end,
  })
end

return M
