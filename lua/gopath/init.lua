---@module 'gopath'
---@brief Public setup and API surface for gopath.nvim.
---@description
--- Main entry point called by package managers (lazy.nvim, packer, …).
--- Delegates to focused helpers so that `setup()` itself stays thin:
---   • Config merge  → gopath.config
---   • Bindings      → gopath.bindings (keymaps, usrcmds, autocmds)
---   • Cache init    → private `_setup_cache()`

local C = require("gopath.config")
local R = require("gopath.resolve")

local M = {}

---Initialise the truncated-path cache subsystem.
---Separated from `setup()` to keep each function single-purpose.
---@private
---@param config GopathOptions
local function _setup_cache(config)
  local tcfg = config.truncated
  if not (tcfg and tcfg.enable) then return end

  local cache = require("gopath.truncated.cache")
  local LOG = require("gopath.util.log")

  -- Configure scan roots / depth / exclusions. Without this the cache would
  -- index nothing (scan_roots stays empty) and every resolve would fall back
  -- to the slow live search.
  cache.setup({
    roots = tcfg.cache_roots,
    max_depth = tcfg.max_depth,
    max_paths = tcfg.max_paths,
    excluded_dirs = tcfg.excluded_dirs,
    index_home = tcfg.index_home,
  })

  -- The persisted index is NOT read here. Reading and decoding it cost about
  -- 30 ms of the `VeryLazy` wave (startup analysis 2026-09-26; 40-60 ms for
  -- `load_from_disk` on a 26.4k-path index, 2026-10-22), for an index
  -- `cache.search` loads by itself the first time it is asked. The staleness
  -- check below reads the file's mtime instead (`cache.needs_refresh`), so a
  -- fresh cache still means no rescan. The first lookup of a session pays the
  -- read instead (docs/cache.md).

  -- Periodic background refresh.
  if tcfg.use_cache then cache.start_periodic_refresh(tcfg.cache_refresh_interval or 600) end

  -- Initial async build when the cache is missing or stale.
  if cache.needs_refresh(tcfg.max_cache_age or 3600) then
    vim.defer_fn(function()
      -- A lookup in the first two seconds may have started a build already
      -- (a rejected cache file). Not a failure: that build is this one.
      if cache.building() then return end
      cache.build_async(function(success)
        if success then
          LOG.debug("Filesystem cache built successfully")
        else
          LOG.error("Filesystem cache build failed")
        end
      end)
    end, 2000)
  end
end

---Set up gopath.nvim with user options and register keymaps / commands.
---@param opts GopathOptions|nil
function M.setup(opts)
  C.setup(opts)
  local config = C.get()

  require("gopath.bindings").setup(config)
  _setup_cache(config)

  -- One-time (persisted across restarts) popup on the first setup() after
  -- installing this plugin: which CLI tools it wants and why
  -- (docs/install.json). `:Lib deps show gopath.nvim` thereafter.
  -- `C.get().deps_popup = false` (set right in the setup() spec,
  -- config/DEFAULTS.lua) disables it for this plugin specifically. pcall'd:
  -- an older lib.nvim without lib.nvim.deps mustn't break setup() over an
  -- informational popup.
  if C.get().deps_popup ~= false then
    local ok_deps, deps = pcall(require, "lib.nvim.deps")
    if ok_deps then deps.show_once("gopath.nvim") end
  end
end

---Resolve the entity under the cursor without opening anything.
---Useful for custom integrations that need the raw GopathResult.
---@param opts GopathResolveOpts|nil
---@return GopathResult|nil result
---@return string|nil err
function M.resolve(opts)
  return R.resolve_at_cursor(opts)
end

---Resolve a piece of TEXT -- not the token under the cursor -- without opening
---anything: a `$VAR/rest` / `${VAR}/rest` reference (including the "well-known"
---directories such as `$NVIM_CONFIG_DIR`, with or without a real environment
---variable) or a URL. For integrations that already hold the text, e.g. a
---language server or a link parser that extracted a Markdown link target.
---
---Same rules as the cursor-based resolvers, including the
---`env_variable_resolution.enable` and `url.enable` switches. `result.path` is
---the absolute forward-slash path. `result.exists` is true only for an existing
---**regular file**: a directory reports `false`, exactly as for the cursor-based
---resolvers (`gopath.util.path.exists`). A caller that needs "is anything
---there" -- a link to a folder is valid -- checks `result.path` itself.
---nil when the text is neither an env reference nor a URL, or names a variable
---nothing defines. Plain relative paths are deliberately not resolved here --
---there is no cursor or buffer to resolve them against.
---@param text string
---@return GopathResult|nil result
function M.resolve_text(text)
  return require("gopath.resolve_selection").resolve_text(text)
end

---Shorten one absolute path to its `$VAR` form (`$NVIM_CONFIG_DIR/...` for the
---configured well-known directories, `$REPOS_DIR/...` for the repos root): the
---same logic as `:Gopath to-nvim-dir` / `:Gopath to-repos-dir`, for a caller
---that holds the path as a string. See `env_variable_resolution.shorten_dirs`
---and `shorten_known_dirs`.
---@param abs string An absolute path (either slash style)
---@return string|nil shortened nil when no configured root contains `abs`
---@return string|nil var The variable name used, e.g. "REPOS_DIR"
function M.shorten_path(abs)
  return require("gopath.env_shorten").shorten_path(abs)
end

---Direct access to command implementations for custom keymaps.
---Example: `require("gopath").commands.goto_at_cursor("vsplit")`
M.commands = require("gopath.commands")

return M
