---@module 'gopath.external.helpers.opener'
--- Cross-platform system opener for external files.
---@description
--- open.nvim is a soft dependency: when installed, external files are handed
--- to its "default" handler (system default app, incl. WSL win-path
--- translation, shared with `:Open`). Falls back to lib.nvim's
--- cross.open_default (declared dependency, same soft-fallback
--- convention as `gopath.util.cross` / `gopath.util.log`) when open.nvim is
--- not present, or to a minimal built-in opener if lib.nvim is missing too.

local LOG = require("gopath.util.log")

local M = {}

---@type table|nil  the open_nvim module, or nil when unavailable
local open_nvim
do
  local ok, mod = pcall(require, "open_nvim")
  if ok and type(mod) == "table" and type(mod.open) == "function" then
    open_nvim = mod
  else
    open_nvim = nil
    vim.schedule(function()
      LOG.debug(
        "optional dependency 'open_nvim' not found — using built-in "
          .. "system opener fallback. Add it to your plugin spec "
          .. "(dependencies = { 'WKDSteve/open.nvim' }) for WSL support and shared handlers."
      )
    end)
  end
end

---@type fun(target: string, opts?: table): boolean, string?  lib.nvim.cross.open_default, or nil when unavailable
local lib_opener
do
  local ok, mod = pcall(require, "lib.nvim.cross.open_default")
  if ok then
    lib_opener = mod
  else
    vim.schedule(function()
      LOG.warn(
        "optional dependency 'lib.nvim' not found — using a minimal "
          .. "built-in system opener fallback."
      )
    end)
  end
end

---Detect operating system.
---@internal
---@return "macos"|"linux"|"windows"|"unknown"
local function detect_os()
  if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
    return "macos"
  elseif vim.fn.has("unix") == 1 then
    return "linux"
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "windows"
  end
  return "unknown"
end

---Minimal per-OS opener, used only when both open.nvim and lib.nvim are absent.
---@internal
---@param path string File path or URL
---@return boolean success True if opener was invoked
local function minimal_fallback_open(path)
  local os_type = detect_os()
  local cmd
  if os_type == "macos" then
    cmd = { "open", path }
  elseif os_type == "linux" then
    cmd = { "xdg-open", path }
  elseif os_type == "windows" then
    -- explorer.exe hands the target straight to the registered file handler
    -- with no cmd.exe re-tokenizing in between; `cmd.exe /c start` silently
    -- truncates a path containing an unescaped `&` (cmd.exe treats a bare
    -- `&` outside quotes as a command separator).
    cmd = { "explorer.exe", path:gsub("/", "\\") }
  else
    LOG.error("Unsupported operating system for external opener")
    return false
  end

  local name = vim.fn.fnamemodify(path, ":t")

  ---@type vim.SystemCompleted|nil  set once the process exits; read nowhere
  --- but here, purely so the success message below has something real to
  --- point at instead of a job id.
  local finished

  -- Not `jobstart(..., { detach = true })`. On Windows that flag stops a
  -- *console* program from running at all: libuv sets `DETACHED_PROCESS`,
  -- the child gets no standard handles, and an interpreter exits before its
  -- first statement — while `jobstart` still hands back a valid job id, so
  -- `job_id > 0` reported success for a process that never did anything.
  -- media.nvim's `media/core/play.lua` documents the exact same failure
  -- mode. `vim.system(cmd, {})`, not detached, is the form that actually
  -- starts both console and GUI programs on every platform this touches.
  local ok, proc = pcall(vim.system, cmd, { text = true }, function(result)
    finished = result
  end)
  if not ok then
    LOG.error("Failed to start external opener: " .. tostring(proc))
    return false
  end

  -- Not awaited, and not `proc:wait(timeout)` either — that call kills the
  -- process on a timeout, which would shoot down the very app this is
  -- trying to confirm opened. `explorer.exe`, `open` and `xdg-open` are all
  -- short-lived dispatchers that hand off to the real application and exit
  -- within well under a second, so the `on_exit` callback above almost
  -- always has `finished` set by the time this runs — an exit code, not a
  -- job id, is what the message now hangs on.
  vim.defer_fn(function()
    if finished and finished.code ~= 0 then
      local err = (finished.stderr or ""):gsub("%s+$", "")
      LOG.error(
        ("External opener for %s exited with %d%s"):format(
          name,
          finished.code,
          err ~= "" and (": " .. err) or ""
        )
      )
      return
    end
    -- `finished == nil` here means the dispatcher is still running past the
    -- window below — itself the success this was asked to prove, since a
    -- process that silently died (the original bug) would already be gone.
    LOG.info(string.format("Opening externally: %s", name))
  end, 300)

  return true
end

---Open `path` with the OS default handler: lib.nvim's cross.open_default when
---available, falling through to the minimal built-in per-OS opener if it
---fails to dispatch (e.g. no xdg-open on a bare Linux install) rather than
---giving up — the minimal opener covers fewer cases (no vim.ui.open, no WSL
---wslview) but is worth trying before reporting failure to the user.
---@internal
---@param path string File path or URL
---@return boolean success True if opener was invoked
local function fallback_open_with_system(path)
  if lib_opener then
    local ok = lib_opener(path)
    if ok then
      LOG.info(string.format("Opening externally: %s", vim.fn.fnamemodify(path, ":t")))
      return true
    end
    LOG.warn("lib.nvim's opener failed to dispatch — trying minimal fallback opener")
  end

  return minimal_fallback_open(path)
end

---Open a file or URL with the system's default application.
---@param path string File path or URL
---@return boolean success True if opener was invoked
function M.open_with_system(path)
  if not path or path == "" then return false end

  if open_nvim then
    local ok, err = pcall(open_nvim.open, "default", "path=" .. path)
    if ok then return true end
    LOG.warn("open_nvim.open() failed: " .. tostring(err) .. " — falling back to built-in opener")
  end

  return fallback_open_with_system(path)
end

return M
