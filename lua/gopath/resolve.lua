---@module 'gopath.resolve'
---@brief Orchestrates providers to produce a GopathResult.
---@description
--- Entry point for all cursor-based resolution. Tries resolvers in this order:
---   1. Help (:h subject) — always, all filetypes.
---   1.5 URL (strict) — explicit scheme / www., which no local path can look like.
---   2. Env var path ($VAR/...) — always, before filetoken sees raw token.
---   2.5 Task id (<area>/<slug>) — through tasks.nvim, when it is installed;
---      only an id a vault knows, so a relative path is never taken for one.
---   3. Filetoken — high-confidence existing hit returned immediately;
---      low-confidence / non-existent result held as fallback.
---   3.5 Linepath — whole-line path extraction (when cascade enabled).
---   4. Language-specific pipeline (lsp / treesitter / builtin).
---   4.5 URL (loose) — bare host / scp-style remote; only once no file matched.
---   5. Filetoken fallback — the low-confidence result from step 3, if any.
---   6. Raw cfile — last resort.

local C = require("gopath.config")
local REG = require("gopath.registry")
local safe = require("gopath.util.safe")
local LOG = require("gopath.util.log")

local M = {}

---@class Gopath.Stage
---@field name string  Reported by `M.stage_names()` and in debug logs
---@field enabled? fun(cfg: table): boolean  Gate on the user's config (default: on)
---@field run fun(cfg: table, held: { fallback: GopathResult|nil }): GopathResult|nil

--- Call `modname.fn()` when the module loads; a module that fails to load is
--- skipped (the stage then finds nothing).
---@param modname string
---@param fn string
---@return GopathResult|nil
local function optional(modname, fn)
  local ok, mod = pcall(require, modname)
  if ok then return mod[fn]() end
end

--- Call `modname.resolve()` with every failure (load or run) swallowed.
---@param modname string
---@return GopathResult|nil
local function guarded(modname)
  local ok, res = pcall(function()
    return require(modname).resolve()
  end)
  if ok then return res end
end

--- The stages that run before the language pipeline, in order; the first one
--- to answer wins. A stage that needs the one before it to have failed (the
--- loose URL, the filetoken fallback) is not here: it runs after the pipeline.
---@type Gopath.Stage[]
local STAGES = {
  -- 1. Help resolver (all filetypes, very cheap)
  {
    name = "help",
    run = function()
      return require("gopath.resolvers.common.help").resolve()
    end,
  },
  -- 1.5 URL with an explicit scheme ("https://…", "mailto:…") or a "www."
  --     prefix. Nothing on disk is spelled like that, so this may run before
  --     every file resolver — which it must: filetoken/linepath would otherwise
  --     turn the URL into "<cwd>/https:/…" and offer to create that file.
  {
    name = "url_strict",
    run = function()
      return optional("gopath.resolvers.common.url", "resolve_strict")
    end,
  },
  -- 2. Environment variable path ($VAR/foo.md, ${VAR}/foo.md).
  --    Runs before filetoken so that the $ prefix is caught here and
  --    filetoken never receives a raw env-var token it cannot handle.
  {
    name = "env_path",
    enabled = function(cfg)
      local ev_cfg = cfg.env_variable_resolution
      return not ev_cfg or ev_cfg.enable ~= false
    end,
    run = function()
      return guarded("gopath.resolvers.common.env_path")
    end,
  },
  -- 2.5 Task id (`lib.nvim/alpha`), resolved by tasks.nvim (soft dependency).
  --     Before filetoken, which would otherwise read the id as a relative path
  --     that does not exist and offer to create it. Safe to run this early:
  --     tasks.nvim answers only for an id whose area and task exist.
  {
    name = "task_id",
    run = function()
      return guarded("gopath.resolvers.common.task_id")
    end,
  },
  -- 3. Filetoken: high-confidence existing hit returned immediately.
  --    Low-confidence or non-existent result held so Phase 3.5/4 can improve on it.
  {
    name = "filetoken",
    run = function(_, held)
      local ftok = require("gopath.resolvers.common.filetoken").resolve()
      if ftok then
        if ftok.exists and (ftok.confidence or 0) >= 0.6 then return ftok end
        held.fallback = ftok
      end
    end,
  },
  -- 3.5. Whole-line path extraction (linepath / pathfinder strategy).
  --      Runs only when linepath.cascade = true (default).
  {
    name = "linepath",
    enabled = function(cfg)
      local lp_cfg = cfg.linepath
      return not lp_cfg or (lp_cfg.enable ~= false and lp_cfg.cascade ~= false)
    end,
    run = function()
      return optional("gopath.resolvers.common.linepath", "resolve")
    end,
  },
}

---Names of the stages that run before the language pipeline, in order.
---@return string[]
function M.stage_names()
  local out = {}
  for i, st in ipairs(STAGES) do
    out[i] = st.name
  end
  return out
end

---Resolve the entity under the cursor using configured providers.
---
---`GopathResolveOpts` is declared once, in `@types/resolvers.lua`; the copy
---that used to sit here declared the same two fields a second time.
---@param opts GopathResolveOpts|nil
---@return GopathResult|nil result
---@return string|nil err
function M.resolve_at_cursor(opts)
  local cfg = C.get()
  local ft = vim.bo.filetype or "text"

  local held = { fallback = nil }
  for _, stage in ipairs(STAGES) do
    if not stage.enabled or stage.enabled(cfg) then
      local res = stage.run(cfg, held)
      if res then
        LOG.debug("stage matched: " .. stage.name)
        return res, nil
      end
    end
  end
  local filetoken_fallback = held.fallback

  -- 4. Language-specific pipeline
  local lang = cfg.languages[ft]

  if lang == false or (type(lang) == "table" and lang.enable == false) then
    LOG.debug("language disabled for filetype: " .. ft)
    return filetoken_fallback or nil, "language-disabled"
  end

  local lang_enabled = type(lang) == "table"

  if lang_enabled then
    local order
    if cfg.mode == "lsp" then
      order = { "lsp" }
    elseif cfg.mode == "treesitter" then
      order = { "treesitter" }
    elseif cfg.mode == "builtin" then
      order = { "builtin" }
    else
      order = (opts and opts.order) or cfg.order or { "lsp", "treesitter", "builtin" }
    end

    for _, provider in ipairs(order) do
      local ok, result = safe.call(function()
        return REG.run_language_pipeline(ft, provider, {
          timeout_ms = (opts and opts.timeout_ms) or cfg.lsp_timeout_ms,
        })
      end)
      if ok and result then
        return result, nil
      elseif not ok then
        -- `safe.call` catching something here always means a resolver threw
        -- (a normal "no match" returns ok=true, result=nil) -- discarding the
        -- traceback would make that indistinguishable from "no match" at
        -- every log level, including dev_mode.
        local message = (type(result) == "table" and result.message) or tostring(result)
        LOG.debug(("%s resolver failed for filetype '%s': %s"):format(provider, ft, message))
      end
    end
  end

  -- 4.5 URL without a scheme ("github.com/neovim/neovim", "git@github.com:a/b").
  --     These forms are indistinguishable from a relative path, so they only
  --     win once every file resolver above has come up empty — a real
  --     "notes.info" on disk still opens as a file.
  do
    local ok, url_mod = pcall(require, "gopath.resolvers.common.url")
    if ok then
      local url = url_mod.resolve_loose()
      if url then return url, nil end
    end
  end

  -- 5. Filetoken fallback (more specific than raw cfile)
  if filetoken_fallback then return filetoken_fallback, nil end

  -- 6. Last resort: raw cfile
  local cfile = vim.fn.expand("<cfile>")
  if cfile and cfile ~= "" then
    return {
      language = ft,
      kind = "file",
      path = cfile,
      range = nil,
      chain = nil,
      source = "builtin-fallback",
      confidence = 0.5,
      exists = false,
    },
      nil
  end

  return nil, "no-match"
end

return M
