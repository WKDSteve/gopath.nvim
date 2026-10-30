---@module 'gopath.health'
---@brief :checkhealth gopath — verifies all plugin dependencies and config.

local M = {}

-- ── Helpers ──────────────────────────────────────────────────────────────────

local ok_s = vim.health.ok or vim.health.report_ok
local warn_s = vim.health.warn or vim.health.report_warn
local err_s = vim.health.error or vim.health.report_error
local info_s = vim.health.info or vim.health.report_info
local start_s = vim.health.start or vim.health.report_start

---Check whether an external binary is on `$PATH`.
---@internal
---@param bin string
---@return boolean
local function exe(bin)
  return vim.fn.executable(bin) == 1
end

---Check whether a module can be `require`d without erroring.
---@internal
---@param mod string
---@return boolean
local function require_ok(mod)
  local ok, _ = pcall(require, mod)
  return ok
end

-- ── Sections ─────────────────────────────────────────────────────────────────

---Report the running Neovim version and `vim.fs.joinpath` availability.
---@internal
local function check_neovim()
  start_s("Neovim version")
  local v = vim.version()
  if v.major > 0 or v.minor >= 9 then
    ok_s(string.format("Neovim %d.%d.%d (>= 0.9 required)", v.major, v.minor, v.patch))
  else
    err_s(
      string.format(
        "Neovim %d.%d.%d detected — gopath.nvim requires 0.9+",
        v.major,
        v.minor,
        v.patch
      ),
      { "Upgrade Neovim to 0.9+" }
    )
  end
  if v.major > 0 or v.minor >= 10 then
    ok_s("vim.fs.joinpath available (Neovim 0.10+)")
  else
    info_s("vim.fs.joinpath not available (Neovim < 0.10) — using string concat fallback")
  end
end

---Report presence of `fd`/`fdfind`, `rg` and `git` on `$PATH`.
---@internal
local function check_external_tools()
  start_s("External CLI tools")

  if exe("fd") then
    ok_s("fd found — used by tailsearch + truncated.finder")
  elseif exe("fdfind") then
    ok_s("fdfind found — used by tailsearch + truncated.finder")
  else
    warn_s(
      "fd / fdfind not found — tailsearch and truncated.finder fall back to rg",
      { "Install fd-find (https://github.com/sharkdp/fd) for best search performance" }
    )
  end

  if exe("rg") then
    ok_s("rg (ripgrep) found — used as fallback search tool")
  else
    warn_s(
      "rg not found — without fd AND rg, suffix search and live-search fallback are unavailable",
      { "Install ripgrep (https://github.com/BurntSushi/ripgrep)" }
    )
  end

  if exe("git") then
    ok_s("git found — used for git-root detection in tailsearch roots")
  else
    warn_s("git not found — git-root detection is skipped in tailsearch roots", { "Install git" })
  end
end

---Report active LSP clients for the current buffer.
---@internal
local function check_lsp()
  start_s("LSP")
  local clients
  if vim.lsp.get_clients then
    clients = vim.lsp.get_clients()
  else
    -- `get_active_clients` is the pre-0.10 name, deprecated since; it is only
    -- looked at (and only called) when `get_clients` is absent.
    ---@diagnostic disable-next-line: deprecated
    clients = vim.lsp.get_active_clients and vim.lsp.get_active_clients() or {}
  end
  if #clients > 0 then
    local names = {}
    for _, c in ipairs(clients) do
      names[#names + 1] = c.name
    end
    ok_s(string.format("%d active LSP client(s): %s", #clients, table.concat(names, ", ")))
  else
    info_s("No active LSP clients in current buffer — language resolvers need LSP")
  end
end

---Report which-key.nvim availability and whether its label is enabled.
---@internal
local function check_which_key()
  start_s("which-key")
  local ok_cfg, cfg_mod = pcall(require, "gopath.config")
  local which_key_enabled = ok_cfg and cfg_mod.get().which_key ~= false

  if require_ok("which-key") then
    if which_key_enabled then
      ok_s("which-key.nvim installed — the probe prefix is labelled as a group")
    else
      info_s("which-key.nvim installed, but which_key = false in config")
    end
  else
    info_s("which-key.nvim not installed — optional; mappings still carry their own descriptions")
  end
end

---Report open.nvim availability for external-file opening.
---@internal
local function check_open_nvim()
  start_s("open.nvim")
  if require_ok("open_nvim") then
    ok_s("open.nvim installed — external files routed through its 'default' handler (WSL-aware)")
  else
    info_s(
      "open.nvim not installed — external files use gopath's built-in per-OS opener\n"
        .. "  install WKDSteve/open.nvim for shared handlers and WSL support"
    )
  end
end

---Report whether task ids resolve: tasks.nvim is a soft dependency, and its
---absence is silent everywhere else (gF on an id then reads it as a path).
---@internal
local function check_tasks_nvim()
  start_s("tasks.nvim")
  local _, message, level = require("gopath.resolvers.common.task_id").status()
  if level == "ok" then
    ok_s(message)
  elseif level == "warn" then
    -- Installed, and still nothing to resolve against (or a vault that is not
    -- there): gF on an id quietly does nothing, which is worth a warning.
    warn_s(message)
  else
    -- Off on purpose, or a soft dependency that is simply not there.
    info_s(message)
  end
end

---Report lib.nvim availability (required for the `:Gopath` command layer).
---@internal
local function check_lib_nvim()
  start_s("lib.nvim")
  -- Required: the :Gopath command layer (lib.nvim.bindings.usercmd.composer)
  -- registers unconditionally, no pcall fallback.
  if require_ok("lib.nvim.bindings.usercmd.composer") then
    ok_s("lib.nvim detected (:Gopath command layer available)")
  else
    err_s(
      "lib.nvim not found — :Gopath will fail to register",
      { "Install WKDSteve/lib.nvim as a dependency" }
    )
  end
  if require_ok("ui.kit") then
    ok_s("ui.nvim installed — create-on-missing dialog uses ui.kit.confirm")
  else
    info_s(
      "ui.nvim not installed — create-on-missing dialog falls back to vim.ui.select\n"
        .. "  install WKDSteve/ui.nvim for the themed dialog"
    )
  end
end

---Report filetree.nvim availability and setup state.
---@internal
local function check_filetree_nvim()
  start_s("filetree.nvim")
  local ok_ft, filetree = pcall(require, "filetree")
  if ok_ft and type(filetree) == "table" and filetree.is_initialized() then
    ok_s(
      "filetree.nvim installed and set up — create-on-missing dialog offers 'Open in filetree', "
        .. "open_filetree (gT) reveals resolved paths there"
    )
  elseif ok_ft then
    info_s(
      "filetree.nvim installed but setup() not called (or not yet run) — "
        .. "'Open in filetree' choice and open_filetree (gT) unavailable until then"
    )
  else
    info_s(
      "filetree.nvim not installed — create-on-missing dialog has no 'Open in filetree' choice, "
        .. "and open_filetree (gT) has nothing to reveal into\n"
        .. "  install WKDSteve/filetree.nvim to open the nearest existing ancestor "
        .. "directory there instead of just creating the file, or to reveal a resolved path"
    )
  end
end

---Report pdfport.nvim availability and the effective PDF-open mode.
---@internal
local function check_pdfport()
  start_s("pdfport.nvim")
  local ok_cfg, cfg_mod = pcall(require, "gopath.config")
  local pdf_cfg = ok_cfg and (cfg_mod.get().external or {}).pdf or {}

  if require_ok("pdfport") then
    if pdf_cfg.picker ~= false then
      ok_s("pdfport.nvim installed — PDFs offer System app / Buffer / Float / Terminal")
    else
      info_s(
        "pdfport.nvim installed, but external.pdf.picker = false — "
          .. "PDFs always open with mode '"
          .. tostring(pdf_cfg.default or "system")
          .. "'"
      )
    end
  else
    info_s(
      "pdfport.nvim not installed — PDFs go straight to the system viewer\n"
        .. "  install WKDSteve/pdfport.nvim to read PDFs inside Neovim"
    )
  end
end

---Whether a Tree-sitter parser can be loaded for filetype `ft`, asked of core
---`vim.treesitter` only (nvim-treesitter's `parsers.has_parser` is gone in its
---rewrite, and gopath never needs the plugin at runtime).
---@internal
---@param ft string
---@return boolean available
---@return string lang  the language `ft` maps to
local function parser_available(ft)
  local lang = vim.treesitter.language.get_lang(ft) or ft
  -- 0.9/0.10 raise when no parser is found and return nothing on success;
  -- 0.11+ return `true`, or `nil, err` when no parser is found.
  local ok, loaded, err = pcall(vim.treesitter.language.add, lang)
  return ok and not (loaded == nil and err ~= nil), lang
end

---Filetype of the buffer `:checkhealth` was run from. By the time a check runs,
---`vim.health` has already made its fresh `health://` scratch buffer current (filetype
---"" on 0.11+, "checkhealth" on 0.10), in a split, a float, a new tab or the same
---window. After a split or a float the window it was run from is the previous window;
---a new tab has no previous window, there (and in the same window) the user's buffer is
---the alternate buffer. The previous window comes first because `:keepalt` reaches the
---float (opened by `nvim_open_win`, not by an Ex command): it then inherits the
---alternate buffer of the window it was run from instead of that window's own buffer.
---Calling `check()` directly from a normal buffer keeps working.
---@internal
---@return string? ft  nil when no filetype can be determined
local function origin_filetype()
  local function usable(buf)
    if not (buf and buf > 0 and vim.api.nvim_buf_is_valid(buf)) then return nil end
    local ft = vim.bo[buf].filetype
    if ft == "" or ft == "checkhealth" then return nil end
    return ft
  end
  local ft = usable(vim.api.nvim_get_current_buf())
  if ft then return ft end
  local prev = vim.fn.winnr("#")
  if prev > 0 then
    ft = usable(vim.api.nvim_win_get_buf(vim.fn.win_getid(prev)))
    if ft then return ft end
  end
  return usable(vim.fn.bufnr("#"))
end

---Report nvim-treesitter availability and parser coverage for the filetype of the
---buffer `:checkhealth` was run from.
---@internal
local function check_treesitter()
  start_s("Tree-sitter")
  if require_ok("nvim-treesitter") then
    ok_s("nvim-treesitter installed (parser installer; gopath itself uses core vim.treesitter)")
  else
    info_s(
      "nvim-treesitter not installed — fine: gopath uses core vim.treesitter, "
        .. "it only needs a parser for the filetype"
    )
  end
  local ft = origin_filetype()
  if not ft then
    info_s(
      "No filetype to check a parser for — run :checkhealth gopath from a buffer of the "
        .. "filetype you care about"
    )
    return
  end
  local available, lang = parser_available(ft)
  if available then
    ok_s("Parser available for filetype: " .. ft .. " (language '" .. lang .. "')")
  else
    info_s("No Tree-sitter parser for filetype '" .. ft .. "'")
  end
end

---Report the resolved `GopathOptions` (mode, order, feature toggles, keymaps).
---@internal
local function check_config()
  start_s("Configuration")
  local ok, cfg_mod = pcall(require, "gopath.config")
  if not ok then
    err_s(
      "Could not load gopath.config — plugin may not be set up",
      { "Call require('gopath').setup() in your config" }
    )
    return
  end
  local cfg = cfg_mod.get()

  if type(cfg_mod.issues) == "function" then
    local setup_issues = cfg_mod.issues()
    if #setup_issues > 0 then
      for _, msg in ipairs(setup_issues) do
        warn_s(msg)
      end
    else
      ok_s("setup() options: no unknown keys, nothing invalid")
    end
  end

  info_s("mode = " .. (cfg.mode or "hybrid"))
  info_s("order = " .. vim.inspect(cfg.order or { "lsp", "treesitter", "builtin" }))

  if cfg.linepath and cfg.linepath.enable then
    ok_s("linepath.enable = true  (whole-line path extraction active)")
  else
    info_s("linepath.enable = false — whole-line scanning disabled by configuration")
  end

  local ts = cfg.tailsearch or {}
  if ts.enable ~= false then
    ok_s("tailsearch.enable = true  (suffix-based filesystem search active)")
    info_s("  max_components   = " .. tostring(ts.max_components or 6))
    info_s("  ask_on_ambiguous = " .. tostring(ts.ask_on_ambiguous ~= false))
    if ts.roots then
      info_s("  roots (custom)   = " .. vim.inspect(ts.roots))
    else
      info_s("  roots            = auto (bufdir -> cwd -> git root -> stdpaths)")
    end
  else
    info_s("tailsearch.enable = false — suffix search disabled by configuration")
  end

  local alt = cfg.alternate or {}
  if alt.enable then
    ok_s("alternate.enable = true  (Levenshtein fuzzy fallback active)")
    info_s("  similarity_threshold = " .. tostring(alt.similarity_threshold or 75))
    local frec = alt.frecency or {}
    if frec.enable == false then
      info_s("  frecency = off  (candidates ordered by similarity alone)")
    else
      info_s(
        "  frecency = on, max_bonus = "
          .. tostring(frec.max_bonus or 10)
          .. "  (previously chosen candidates rise within their similarity band)"
      )
    end
  else
    info_s("alternate.enable = false")
  end

  local ext = cfg.external or {}
  if ext.enable then
    ok_s("external.enable = true  (images/PDFs open in system viewer)")
  else
    info_s("external.enable = false")
  end

  local com = cfg.create_on_missing or {}
  if com.enable ~= false then
    ok_s("create_on_missing.enable = true  (offers to create missing files)")
    info_s(
      "  confirm = "
        .. tostring(com.confirm ~= false)
        .. "  (dialog: ui.nvim ui.kit.confirm / vim.ui.select — see below)"
    )
  else
    info_s("create_on_missing.enable = false — 'gC'/:GopathCheck still offers to create")
  end

  start_s("Keymaps")
  local maps = cfg.mappings or {}
  ---Print one keymap's binding if it is set and not disabled.
  ---@internal
  ---@param name string
  local function km(name)
    local v = maps[name]
    if v and v ~= false then info_s(string.format("  %-16s %s", name .. " =", vim.inspect(v))) end
  end
  km("open_here")
  km("open_split")
  km("open_vsplit")
  km("open_tab")
  km("open_explorer")
  km("open_filetree")
  km("copy_location")
  km("debug")
  km("probe")
  km("check")
end

---Report the truncated-path cache backend state (loaded, size, last build).
---@internal
local function check_truncated()
  start_s("Truncated path cache")
  local ok_cfg, cfg_mod = pcall(require, "gopath.config")
  if not ok_cfg then return end
  local cfg = cfg_mod.get()

  if not (cfg.truncated and cfg.truncated.enable) then
    info_s("truncated path resolution is disabled in config")
    return
  end

  ok_s("truncated.enable = true")

  if require_ok("gopath.truncated.finder") then
    ok_s("gopath.truncated.finder loaded (live search backend)")
  else
    err_s("gopath.truncated.finder failed to load", { "Reinstall gopath.nvim" })
  end

  local ok_cache, cache = pcall(require, "gopath.truncated.cache")
  if not ok_cache then
    err_s("gopath.truncated.cache failed to load", { "Reinstall gopath.nvim" })
    return
  end

  local ok_load = pcall(function()
    cache.load_from_disk()
  end)
  if ok_load then
    local state = cache._get_state and cache._get_state() or {}
    local n = #(state.paths or {})
    local built = state.last_built
    if n > 0 then
      ok_s(
        string.format(
          "Cache loaded: %d files indexed (last built: %s)",
          n,
          built and os.date("%Y-%m-%d %H:%M", built) or "unknown"
        )
      )
    else
      warn_s("Cache is empty", { "Run :Gopath cache build to index the filesystem" })
    end
    info_s("  use_cache  = " .. tostring(cfg.truncated.use_cache ~= false))
    info_s("  max_depth  = " .. tostring(cfg.truncated.max_depth or 6))
    info_s("  max_paths  = " .. tostring(cfg.truncated.max_paths or 300000))
  else
    warn_s("Could not load cache from disk", { "Run :Gopath cache build" })
  end
end

---Report per-filetype language resolver configuration.
---@internal
local function check_languages()
  start_s("Language resolvers")
  local ok_cfg, cfg_mod = pcall(require, "gopath.config")
  if not ok_cfg then return end
  local cfg = cfg_mod.get()
  local langs = cfg.languages or {}

  if not next(langs) then
    info_s("No language-specific resolvers configured")
    return
  end

  for ft, lang_cfg in pairs(langs) do
    if lang_cfg == false or (type(lang_cfg) == "table" and lang_cfg.enable == false) then
      info_s(ft .. ": disabled")
    else
      ok_s(ft .. ": enabled")
    end
  end
end

-- ── Entry point ───────────────────────────────────────────────────────────────

---Run all `:checkhealth gopath` sections and register the report with lib.nvim.
function M.check()
  check_neovim()
  check_external_tools()
  check_lsp()
  check_open_nvim()
  check_tasks_nvim()
  check_lib_nvim()
  check_filetree_nvim()
  check_pdfport()
  check_treesitter()
  check_which_key()
  check_config()
  check_truncated()
  check_languages()

  -- gopath.nvim's own docs/install.json via lib.nvim.deps — the same
  -- fd/rg check_external_tools() already probes, but with their declared
  -- `why` and a pointer to `:Lib deps show`. Does nothing if
  -- lib.nvim.deps is unavailable (older lib.nvim).
  local ok_deps, deps_health = pcall(require, "lib.nvim.deps.health")
  if ok_deps then
    start_s("Declared tools (lib.nvim.deps)")
    deps_health.report_for("gopath.nvim")
  end

  -- Guarded like the deps report above it: without lib.nvim this require
  -- throws, and `:checkhealth gopath` would abort right here -- on exactly the
  -- machine whose report says lib.nvim is missing, so the user would never get
  -- to read the diagnosis they came for.
  local ok_composer, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  if ok_composer then composer.checkhealth("Gopath") end
end

return M
