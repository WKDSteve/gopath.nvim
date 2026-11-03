---@module 'gopath.bindings.usrcmds'
---@brief User command registration: unified :Gopath (built via
--- lib.nvim.bindings.usercmd.composer) + individual convenience commands.
---
--- Unified command:
---   :Gopath open [edit|split|vsplit|tab]   resolve & open
---   :Gopath copy                           copy path:line:col to clipboard
---   :Gopath debug                          show resolution info
---   :Gopath probe [edit|split|vsplit|explorer|filetree]  suffix/visual probe
---   :Gopath cache build                    rebuild fs cache
---   :Gopath cache info                     show cache stats
---   :Gopath cache add-root <dir>           add cache root
---   :Gopath to-repos-dir                   shorten line's abs. path to $VAR
---   :Gopath to-nvim-dir                    shorten line's stdpath('config')
---                                          occurrences to $VAR
---
--- Individual aliases kept alongside as an explicit backward-compat layer
--- (same "keep alongside" call as pickers.nvim's compat flat aliases —
--- these are individually toggleable via config.commands.*, a deliberate
--- design, not accidental duplication):
---   :GopathOpen [mode]  :GopathCopy  :GopathDebug  :GopathResolve
---   :GopathCacheBuild   :GopathCacheInfo  :GopathCacheAddRoot
---   :GopathToReposDir   :GopathToNvimDir

local composer = require("lib.nvim.bindings.usercmd.composer")
local usercmd = require("lib.nvim.bindings.usercmd")
local expand_path = require("lib.nvim.cross.fs.expand_path")
local LOG = require("gopath.util.log")

local M = {}

-- ── Subcommand table ─────────────────────────────────────────────────────────

local OPEN_MODES = { "edit", "split", "vsplit", "tab", "explorer", "filetree" }
local PROBE_MODES = { "edit", "split", "vsplit", "explorer", "filetree" }

---Texts for the `mode` values a route offers (all of them, so the float shows no
---bare rows). The two reveal modes behave the same for `open` and `probe`; the
---default mode differs (`edit` for `open`, `vsplit` for `probe`), so each route
---gets its own table with the default marked.
---@internal
---@param values string[]  the modes the route offers (`probe` has no `tab`)
---@param default "edit"|"vsplit"
---@return table<string, string>
local function mode_texts(values, default)
  local all = {
    edit = "In the current window",
    split = "In a horizontal split",
    vsplit = "In a vertical split",
    tab = "In a new tab",
    explorer = "Reveal in the system file explorer",
    filetree = "Reveal in filetree.nvim (soft dependency)",
  }
  local texts = {}
  for _, mode in ipairs(values) do
    texts[mode] = all[mode] .. (mode == default and " (default)" or "")
  end
  return texts
end

---Normalize open/probe mode strings to the keys used by commands.lua.
---@internal
---@param raw string
---@return string
local function norm_mode(raw)
  local m = (raw or "edit"):lower()
  if m == "split" or m == "window" then return "window" end
  if m == "vsplit" then return "vsplit" end
  if m == "tab" then return "tab" end
  if m == "explorer" then return "explorer" end
  if m == "filetree" then return "filetree" end
  return "edit"
end

-- ── Cache subcommand bodies (extracted from the old inline handler so the
-- composer routes below can call them directly) ─────────────────────────────

---Rebuild the filesystem cache asynchronously, logging the outcome.
---@internal
---@return nil
local function cache_build()
  local cache = require("gopath.truncated.cache")
  LOG.info("Building filesystem cache…")
  cache.build_async(function(ok)
    local msg = "Cache build " .. (ok and "complete" or "failed")
    if ok then
      LOG.info(msg)
    else
      LOG.error(msg)
    end
  end)
end

---Log a summary of the filesystem cache's current state (size, age, staleness).
---@internal
---@return nil
local function cache_info()
  local cache = require("gopath.truncated.cache")
  cache.load_from_disk()
  local state = cache._get_state()
  local age = state.last_built and (os.time() - state.last_built) or nil
  LOG.info(table.concat({
    "=== Gopath Cache Info ===",
    "  Files indexed : " .. #(state.paths or {}),
    "  Last built    : "
      .. (state.last_built and os.date("%Y-%m-%d %H:%M:%S", state.last_built) or "never"),
    "  Age           : "
      .. (age and string.format("%d s (%d min)", age, math.floor(age / 60)) or "—"),
    "  Needs refresh : " .. (cache.needs_refresh() and "yes" or "no"),
    "  Building      : " .. (state.building and "yes" or "no"),
    "=========================",
  }, "\n"))
end

---Add a directory to the filesystem cache roots and persist it.
---@internal
---@param dir string
---@return nil
local function cache_add_root(dir)
  local cache = require("gopath.truncated.cache")
  cache.add_root(expand_path(dir), true)
end

-- ── Unified :Gopath dispatcher ───────────────────────────────────────────────

---Register the unified `:Gopath` command with all its subcommand routes.
---@internal
---@param config GopathOptions
---@param commands table
local function register_gopath_cmd(config, commands)
  local truncated_enabled = config.truncated and config.truncated.enable

  local routes = {
    {
      path = { "open" },
      args = {
        {
          name = "mode",
          type = "STRING",
          optional = true,
          enum = OPEN_MODES,
          desc = "Where to open the target; default: edit",
          enum_desc = mode_texts(OPEN_MODES, "edit"),
        },
      },
      desc = "Resolve & open the path under the cursor",
      run = function(ctx)
        commands.goto_at_cursor(norm_mode(ctx.args.mode))
      end,
    },

    {
      path = { "commit" },
      args = {
        {
          name = "target",
          type = "STRING",
          optional = true,
          enum = { "ask", "web", "float", "split", "vsplit", "tab", "current" },
          desc = "Where to show the commit; default: ask",
        },
      },
      desc = "Open the commit hash under the cursor (git show view, or the web page)",
      run = function(ctx)
        local target = ctx.args.target
        commands.ask_commit((target and target ~= "ask") and target or nil)
      end,
    },

    {
      path = { "copy" },
      desc = "Copy path:line:col to clipboard",
      run = function()
        commands.copy_location()
      end,
    },

    {
      path = { "debug" },
      desc = "Show resolution info for the path under the cursor",
      run = function()
        commands.debug_under_cursor()
      end,
    },

    {
      path = { "check" },
      desc = "Check existence / offer to create the path under the cursor",
      run = function()
        commands.check_under_cursor()
      end,
    },

    {
      path = { "probe" },
      args = {
        {
          name = "mode",
          type = "STRING",
          optional = true,
          enum = PROBE_MODES,
          desc = "Where to open the match; default: vsplit",
          enum_desc = mode_texts(PROBE_MODES, "vsplit"),
        },
      },
      -- `range` is what makes `:'<,'>Gopath probe` reach the selection at all:
      -- without it the command is registered range-less, so ctx.range.range is
      -- always 0 and the probe can never tell a selection from a bare call.
      range = true,
      desc = "Probe path under cursor/selection",
      run = function(ctx)
        commands.probe_selection({
          open_cmd = ctx.args.mode or "vsplit",
          ask = true,
          selection = ctx.range.range > 0,
        })
      end,
    },

    {
      path = { "to-repos-dir" },
      -- `range` is what makes `:'<,'>Gopath to-repos-dir` shorten just the
      -- selection instead of the whole line -- see `probe`'s route above.
      range = true,
      desc = "Rewrite the current line's repos-root path to $VAR, or just a visual selection of it (see env_variable_resolution.shorten_dirs)",
      run = function(ctx)
        commands.shorten_to_env({ selection = ctx.range.range > 0 })
      end,
    },

    {
      path = { "to-nvim-dir" },
      range = true,
      desc = "Rewrite the current line's stdpath('config') occurrences to $VAR, or just a visual selection of it (see env_variable_resolution.shorten_known_dirs)",
      run = function(ctx)
        commands.shorten_to_known_dir({ selection = ctx.range.range > 0 })
      end,
    },
  }

  if truncated_enabled then
    routes[#routes + 1] = {
      path = { "cache", "build" },
      desc = "Rebuild the filesystem cache",
      run = cache_build,
    }
    routes[#routes + 1] = {
      path = { "cache", "info" },
      desc = "Show filesystem cache stats",
      run = cache_info,
    }
    routes[#routes + 1] = {
      path = { "cache", "add-root" },
      args = { { name = "dir", type = "DIR" } },
      desc = "Add a directory to the filesystem cache roots",
      run = function(ctx)
        cache_add_root(ctx.args.dir)
      end,
    }
  end

  composer.verb("Gopath", {
    desc = "Gopath: unified navigation command",
    routes = routes,
  })
end

-- ── Individual convenience commands ─────────────────────────────────────────

---Register the individual backward-compat convenience commands (:GopathOpen etc.).
---@internal
---@param config GopathOptions
---@param commands table
local function register_individual(config, commands)
  local cmds = config.commands or {}
  local truncated_enabled = config.truncated and config.truncated.enable

  if cmds.resolve ~= false then
    usercmd.create("GopathResolve", function()
      commands.debug_under_cursor()
    end, { desc = "Gopath: show resolution result (alias for :Gopath debug)" })
  end

  if cmds.open ~= false then
    usercmd.create("GopathOpen", function(o)
      local mode = o.args ~= "" and o.args or "edit"
      if mode == "window_vsplit" then mode = "vsplit" end
      commands.goto_at_cursor(norm_mode(mode))
    end, {
      nargs = "?",
      complete = function()
        return OPEN_MODES
      end,
      desc = "Gopath: open target (alias for :Gopath open [mode])",
    })
  end

  if cmds.copy ~= false then
    usercmd.create("GopathCopy", function()
      commands.copy_location()
    end, { desc = "Gopath: copy path:line:col (alias for :Gopath copy)" })
  end

  if cmds.debug ~= false then
    usercmd.create("GopathDebug", function()
      commands.debug_under_cursor()
    end, { desc = "Gopath: debug resolution (alias for :Gopath debug)" })
  end

  if cmds.check ~= false then
    usercmd.create("GopathCheck", function()
      commands.check_under_cursor()
    end, { desc = "Gopath: check existence / offer create (alias for :Gopath check)" })
  end

  if cmds.to_repos_dir ~= false then
    usercmd.create("GopathToReposDir", function(o)
      commands.shorten_to_env({ selection = (o.range or 0) > 0 })
    end, {
      range = true,
      desc = "Gopath: shorten line's repos-root path to $VAR, or just a visual selection of it (alias for :Gopath to-repos-dir)",
    })
  end

  if cmds.to_nvim_dir ~= false then
    usercmd.create("GopathToNvimDir", function(o)
      commands.shorten_to_known_dir({ selection = (o.range or 0) > 0 })
    end, {
      range = true,
      desc = "Gopath: shorten line's stdpath('config') occurrences to $VAR, or just a visual selection of it (alias for :Gopath to-nvim-dir)",
    })
  end

  -- Probe command (absorbed from pathprobe)
  usercmd.create("GopathProbe", function(o)
    local mode = o.bang and "split" or (o.args ~= "" and o.args or "vsplit")
    commands.probe_selection({
      open_cmd = mode,
      ask = true,
      selection = (o.range or 0) > 0,
    })
  end, {
    nargs = "?",
    bang = true,
    range = true,
    complete = function()
      return PROBE_MODES
    end,
    desc = "Gopath: probe path under cursor/selection (! = split)",
  })

  if truncated_enabled then
    usercmd.create("GopathCacheBuild", function()
      local cache = require("gopath.truncated.cache")
      LOG.info("Building filesystem cache…")
      cache.build_async(function(ok)
        local msg = "Cache " .. (ok and "built" or "build failed")
        if ok then
          LOG.info(msg)
        else
          LOG.error(msg)
        end
      end)
    end, { desc = "Gopath: rebuild fs cache (alias for :Gopath cache build)" })

    usercmd.create(
      "GopathCacheInfo",
      cache_info,
      { desc = "Gopath: show cache info (alias for :Gopath cache info)" }
    )

    usercmd.create("GopathCacheAddRoot", function(o)
      local dir = o.args
      if not dir or dir == "" then
        LOG.error("Usage: :GopathCacheAddRoot <dir>")
        return
      end
      local cache = require("gopath.truncated.cache")
      cache.add_root(expand_path(dir), true)
    end, {
      nargs = 1,
      complete = "dir",
      desc = "Gopath: add cache root (alias for :Gopath cache add-root <dir>)",
    })
  end
end

-- ── Public setup ─────────────────────────────────────────────────────────────

---@param config GopathOptions
function M.setup(config)
  if config.commands == false then return end
  local commands = require("gopath.commands")
  register_gopath_cmd(config, commands)
  register_individual(config, commands)
end

return M
