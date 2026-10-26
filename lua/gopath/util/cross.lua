---@module 'gopath.util.cross'
---@brief Cross-platform path-separator helpers, backed by lib.nvim.
---@description
--- gopath canonicalizes paths to forward slashes internally (this matches
--- `vim.fs.normalize` and every suffix-matching routine in the resolver
--- pipeline). The platform-aware pieces — OS-native separator normalization,
--- Windows drive detection, and platform checks — are delegated to
--- `lib.nvim.cross` so that behaviour stays consistent across the author's
--- plugins.
---
--- lib.nvim is a hard dependency of gopath.nvim overall (several resolver
--- files — e.g. `alternate/helpers/matcher.lua`, `resolvers/common/
--- tailsearch.lua` — already `require("lib.lua...")` unconditionally, with
--- no fallback). This specific module is more defensive than that baseline:
--- it degrades to built-in path-separator equivalents and warns once if
--- lib.nvim is somehow missing, rather than erroring, since separator
--- normalization is cheap to approximate locally. That does not make
--- lib.nvim actually optional for the plugin as a whole — add it to your
--- plugin spec (`dependencies = { "WKDSteve/lib.nvim" }`) regardless.

local M = {}

---@type table|nil  the lib.nvim.cross module, or nil when unavailable
local cross
do
  local ok, mod = pcall(require, "lib.nvim.cross")
  if ok and type(mod) == "table" then
    cross = mod
  else
    cross = nil
    vim.schedule(function()
      require("gopath.util.log").warn(
        "dependency 'lib.nvim' not found — using built-in "
          .. "path-separator fallbacks here, but other gopath modules require "
          .. "it unconditionally. Add it to your plugin spec "
          .. "(dependencies = { 'WKDSteve/lib.nvim' })."
      )
    end)
  end
end

---Whether the current runtime is native Windows.
---@return boolean
function M.is_windows()
  if cross and cross.is_windows then
    local ok, r = pcall(cross.is_windows)
    if ok then return r and true or false end
  end
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

---Whether `path` begins with a Windows drive prefix ("C:/" or "C:\").
---@param path string
---@return boolean
function M.has_drive(path)
  if type(path) ~= "string" then return false end
  if cross and cross.separators and cross.separators.has_win_sep then
    local ok, r = pcall(cross.separators.has_win_sep, path)
    if ok then return r ~= nil and r ~= false end
  end
  return path:match("^%a:[\\/]") ~= nil
end

---Canonical internal form: forward slashes everywhere, regardless of platform.
---Used for token cleaning and all suffix matching.
---@param path string
---@return string
function M.to_forward(path)
  if type(path) ~= "string" then return path end
  return (path:gsub("\\", "/"))
end

---OS-native separators (backslash on Windows) for handing a path to the OS /
---editor. Delegates to lib.nvim.cross when present.
---@param path string
---@return string
function M.to_native(path)
  if type(path) ~= "string" or path == "" then return path end
  if cross and cross.separators and cross.separators.normalize then
    local ok, r = pcall(cross.separators.normalize, path)
    if ok and type(r) == "string" then return r end
  end
  if M.is_windows() then return (path:gsub("/", "\\")) end
  return (path:gsub("\\", "/"))
end

return M
