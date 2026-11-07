---@module 'gopath.integrations.menu'
---@brief Context-aware "Paths" menu entry for a host's global right-click menu.
---@description
--- gopath.nvim does not depend on a menu plugin. It *provides* a list of
--- entries in the shape `ui.contextmenu` (ui.nvim, soft dependency) expects,
--- and a host -- typically the user's own RightMouse dispatcher -- composes
--- them into its own menu for the current buffer:
--- >
---   local items = require("gopath.integrations.menu").items()
---   -- prepend/append `items` to your own menu table, then menu.open(composed)
--- <
--- Same "Pattern-B" shape as `open.integrations.menu` (`items`/`submenu`, no
--- trigger, no hard renderer dependency) and `filetree.integrations.menu`.
---
--- Resolves whatever gopath would resolve right here:
---   - Still in Visual mode when this runs (a right-click while a selection
---     is up, before any <Esc>): the selected text, via
---     `gopath.resolve_selection` -- a `$VAR/rest` reference or a URL, which
---     is what lets a PARTIALLY selected one resolve here too, not just a
---     fully recognized path (tailsearch's filesystem suffix search is
---     deliberately NOT tried here: it is what `:GopathProbe` is for, and a
---     menu entry that silently kicks off a filesystem walk on every
---     right-click would be a bad trade for the common "nothing matched"
---     case).
---   - Otherwise: the normal cursor-based pipeline
---     (`gopath.resolve.resolve_at_cursor`) -- help/url/env/language
---     resolvers, a free-text path, a Markdown link, anything `gF` would
---     find. The "lsp" language provider is skipped (treesitter/builtin
---     stay) -- see `MENU_RESOLVE_OPTS` for why.
---
--- Self-gating: an empty list / nil submenu when ui.nvim is absent, or
--- nothing resolves under the cursor/selection -- so a host can safely
--- `vim.list_extend` `M.items()` unconditionally, or skip the fly-out
--- entirely when `M.submenu()` returns nil.

local M = {}

---@internal
---Lazily load ui.contextmenu. This module is itself opt-in (never required
---by `gopath.setup()`); without ui.nvim there is nothing to build entries
---with, not a hard error.
---@return table|nil
local function contextmenu()
  local ok, mod = pcall(require, "ui.contextmenu")
  return ok and mod or nil
end

---The live visual selection, as plain text -- `vim.fn.getpos("v")` (the
---selection's other end) to `vim.fn.getpos(".")` (the cursor), NOT the `'<`/
---`'>` marks: those persist long after Visual mode ends and cannot tell a
---live selection from a stale one (the exact ambiguity
---`gopath.commands.probe_selection` needs an explicit `opts.selection` flag
---to work around). Checking `vim.fn.mode()` fresh, right here, is what lets
---this module tell the difference on its own -- multi-line selections are
---deliberately not supported: a right-click menu is about "this one thing
---under/around the pointer", not a multi-line span.
---
---Charwise ("v") and blockwise ("\22", single line only -- multi-line is
---already excluded above) both use column bounds that mean what they say.
---Linewise ("V") does not: pressing `V` without moving the cursor further
---reports the SAME column for both `getpos("v")` and `getpos(".")` (the
---cursor's own), so slicing the line by column would grab one arbitrary
---character instead of the whole selected line -- excluded here for that
---reason, falling through to the cursor-based pipeline like the multi-line
---case.
---@internal
---@return string|nil
local function live_selection_text()
  local m = vim.fn.mode()
  if m ~= "v" and m ~= "\22" then return nil end

  local ok_v, spos = pcall(vim.fn.getpos, "v")
  local ok_c, cpos = pcall(vim.fn.getpos, ".")
  if not (ok_v and ok_c) then return nil end
  if spos[2] ~= cpos[2] then return nil end -- multi-line: not handled here

  local line = vim.api.nvim_get_current_line()
  local scol, ecol = spos[3], cpos[3]
  if ecol < scol then
    scol, ecol = ecol, scol
  end
  local text = line:sub(scol, ecol):gsub("^%s+", ""):gsub("%s+$", "")
  return text ~= "" and text or nil
end

---Cursor-pipeline options for a menu popup: same as the default except the
---language pipeline skips the "lsp" provider. `resolve_at_cursor` would
---otherwise try an LSP request (up to `lsp_timeout_ms`, 200ms by default)
---*synchronously* whenever nothing cheaper already matched -- i.e. most
---right-clicks on ordinary code, since help/url/env/filetoken/linepath all
---come up empty there. gopath's own docs/FEATURES/INTEGRATIONS.md documents
---this exact cost for hover.nvim's CursorHold trigger, worked around with a
---caller-side gate; a context menu is at least as latency-sensitive as a
---hover, and unlike CursorHold it fires on every click, not after idling.
---treesitter/builtin stay in the order -- only the network/IPC-bound
---provider is skipped.
---
---Only takes effect in the default "hybrid" mode: `gopath.resolve`'s own
---precedence forces `order = {"lsp"}` outright when the user has configured
---`mode = "lsp"`, ignoring any `opts.order` passed in -- a deliberate
---per-user choice this does not fight.
---@internal
---@type GopathResolveOpts
local MENU_RESOLVE_OPTS = { order = { "treesitter", "builtin" } }

---What a right-click here would act on.
---@internal
---@return GopathResult|nil
local function resolve_here()
  local sel = live_selection_text()
  if sel then
    local direct = require("gopath.resolve_selection").resolve_text(sel)
    if direct then return direct end
  end

  local ok, res = pcall(require("gopath.resolve").resolve_at_cursor, MENU_RESOLVE_OPTS)
  return ok and res or nil
end

---Whether a host that asks first (ui.nvim's `ui.menu`) may show the "Paths"
---entry: `integrations.ui_menu` is not false. `items()`/`submenu()` are not
---affected, so other hosts keep working.
---@return boolean
function M.enabled()
  local cfg = require("gopath.config").get()
  return (cfg.integrations or {}).ui_menu ~= false
end

---Kinds whose `path` is not a local path to reveal: a URL, a commit (a
---`git show` view or a web page) and a file at a commit, a `:help` subject.
---@internal
local NOT_REVEALABLE = { url = true, commit = true, commit_file = true, help = true }

---Whether the reveal entries make sense for `res`: it names a local path the
---resolver confirmed to exist (module, task id, require target, plain file,
---...), and is not one of `NOT_REVEALABLE`.
---@internal
---@param res GopathResult
---@return boolean
local function revealable(res)
  return not NOT_REVEALABLE[res.kind] and type(res.path) == "string" and res.exists == true
end

---Build the gopath menu entries for the current cursor/selection context.
---Returns an empty list when ui.nvim is not installed or nothing resolves.
---@param _opts? table  reserved for future use
---@return table[]  ui.contextmenu entry list (possibly empty)
function M.items(_opts)
  local cm = contextmenu()
  if not cm then return {} end

  local res = resolve_here()
  if not res then return {} end

  local commands = require("gopath.commands")
  local can_reveal = revealable(res)

  local out = {}
  cm.group(
    out,
    cm.entry(true, "  Open", function()
      commands.open_result(res, "edit")
    end),
    cm.entry(can_reveal, "  Reveal in File Manager", function()
      commands.open_result(res, "explorer")
    end),
    cm.entry(can_reveal, "  Reveal in filetree.nvim", function()
      commands.open_result(res, "filetree")
    end)
  )
  return out
end

---Convenience: the gopath entries wrapped as a single nested submenu entry,
---for hosts that prefer a "Paths ▸" fly-out instead of inline entries.
---Returns nil when there is nothing to show (including when ui.nvim is not
---installed, or nothing resolves).
---@param label? string  submenu label (default "  Paths")
---@return table|nil
function M.submenu(label)
  local cm = contextmenu()
  if not cm then return nil end
  local items = M.items()
  if #items == 0 then return nil end
  return cm.submenu(label or "  Paths", items)
end

return M
