---@module 'gopath.open'
---@brief Unified opener for resolved locations.
---@description
--- Replaces the previous per-mode openers (edit/window/vsplit/tab). A single
--- `M.open(res, mode)` handles external files, existence checks, window/tab
--- placement and the optional line/col jump. Help results are handled by
--- `gopath.open.help` and routed separately by `gopath.commands`.

local LOC = require("gopath.util.location")
local LOG = require("gopath.util.log")
local CROSS = require("gopath.util.cross")

local M = {}

---@alias GopathOpenMode "edit"|"window"|"vsplit"|"tab"|"explorer"|"filetree"

---Create the target window/tab before editing the file.
---Each function is a no-op or issues one window-management command only.
---@type table<GopathOpenMode, fun()>
local PLACEMENT = {
  edit = function() end,
  window = function()
    vim.cmd.split()
  end,
  vsplit = function()
    vim.cmd.vsplit()
  end,
  tab = function()
    vim.cmd.tabnew()
  end,
}

---@private
---@param range GopathRange|nil
---@return nil
local function jump_to_range(range)
  if not range then return end
  local normalized = LOC.normalize_range(range)
  if not normalized then return end
  local l = normalized.line
  local c = math.max(0, normalized.col - 1)
  pcall(vim.api.nvim_win_set_cursor, 0, { l, c })
  vim.cmd("normal! zz")
end

---Open a resolved location in the specified window mode.
---@param res  GopathResult
---@param mode GopathOpenMode|nil  defaults to "edit"
---@return nil
function M.open(res, mode)
  if not (res and res.path) then return end

  -- A commit is a `git show` view or a web page, never a file: its own opener.
  if res.kind == "commit" then
    require("gopath.open.commit").open(res, mode)
    return
  end
  if res.kind == "commit_file" then
    require("gopath.open.commit").open_file(res, mode)
    return
  end

  local external = require("gopath.external")

  -- A URL result is never a buffer and never a create-candidate: hand it to
  -- the external opener regardless of what the extension heuristic thinks
  -- (a URL may well end in ".md" or carry no extension at all).
  if res.kind == "url" then
    external.open(res.path)
    return
  end

  -- "explorer" reveals the resolved path in the OS file manager instead of
  -- opening a buffer/window for it -- takes priority over the external-app
  -- heuristic below (an image should still be revealed, not launched, when
  -- the user explicitly asked for the file manager).
  if mode == "explorer" then
    if res.exists == false then
      LOG.warn("cannot reveal — path does not exist: " .. tostring(res.path))
      return
    end
    external.reveal(res.path)
    return
  end

  -- "filetree" reveals the resolved path in filetree.nvim's own in-editor
  -- tree instead of opening a buffer for it -- the in-editor analogue of
  -- "explorer" above, for anyone who navigates the project through the
  -- sidebar rather than the OS file manager. Same priority reasoning: an
  -- image should still be revealed in the tree, not launched externally,
  -- when the user explicitly asked for the tree.
  if mode == "filetree" then
    if res.exists == false then
      LOG.warn("cannot reveal — path does not exist: " .. tostring(res.path))
      return
    end
    local adapter = require("gopath.util.filetree").adapter()
    if not adapter or type(adapter.open_reveal) ~= "function" then
      LOG.warn("filetree.nvim not available — could not reveal: " .. tostring(res.path))
      return
    end
    -- filetree.nvim is a soft dependency we don't control: a bad adapter
    -- (misconfigured, or erroring on a path it doesn't like) must not
    -- surface as a raw Lua traceback -- same convention as pdfport.open()
    -- in external/pdf.lua.
    local ok, revealed = pcall(adapter.open_reveal, res.path)
    if not ok then
      LOG.error(
        "filetree.nvim error while revealing '" .. tostring(res.path) .. "': " .. tostring(revealed)
      )
    elseif not revealed then
      LOG.error("Could not reveal in filetree: " .. tostring(res.path))
    end
    return
  end

  if external.should_open_externally(res.path) then
    -- An external file that does not exist has nothing to hand the OS: launching
    -- the system opener on a missing path yields a cryptic shell/Start-Process
    -- error. Report it here instead. (No create-offer either — an empty .pdf or
    -- .png is not a useful thing to conjure up.)
    if res.exists == false then
      LOG.error("File not found: " .. res.path)
      return
    end

    -- PDFs get a mode chooser when pdfport.nvim is installed; everything else
    -- (and PDFs without pdfport) goes straight to the system viewer.
    if require("gopath.external.pdf").try_open(res.path) then return end
    -- Images likewise, when images.nvim is installed (and `external.images.optout` is off).
    if require("gopath.external.images").try_open(res.path) then return end

    external.open(res.path)
    return
  end

  if res.exists == false then
    local CREATE = require("gopath.create")
    CREATE.offer(res, function(created_res)
      M.open(created_res, mode)
    end)
    return
  end

  local place = PLACEMENT[mode or "edit"] or PLACEMENT.edit
  place()

  -- Hand the OS / editor an OS-native path (backslashes on Windows) via lib.nvim.
  local target = CROSS.to_native(res.path)
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target))
  if not ok then
    LOG.error("Could not open file: " .. tostring(err))
    return
  end

  jump_to_range(res.range)
end

return M
