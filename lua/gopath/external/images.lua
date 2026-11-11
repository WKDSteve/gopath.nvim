---@module 'gopath.external.images'
---@brief Choose how to open an image: system app or one of images.nvim's terminal views.
---@description
--- Same shape as `gopath.external.pdf`. Without images.nvim installed, an image goes straight to the system
--- viewer -- exactly as before, no dialog, no behaviour change.
---
--- With images.nvim present, gopath offers the choice instead. "System app" is deliberately the FIRST entry and is
--- routed through gopath's own opener (`gopath.external`), so the exception path behaves identically whether or
--- not images.nvim is installed (open.nvim delegation, WSL path translation).
---
--- Config (`external.images`):
---   picker  = true      show the chooser; false -> always use `default`
---   default = "system"  mode used when the picker is off (or the list is empty)
---   optout  = false     true -> never offer images.nvim, images always go to the system app

local LOG = require("gopath.util.log")

local M = {}

---Chooser entries, in display order. "system" first -- see module docs.
---`GopathImageMode` is declared in `gopath.@types.config`.
---@type { label: string, mode: GopathImageMode }[]
local CHOICES = {
  { label = "System app", mode = "system" },
  { label = "In the terminal (inline)", mode = "show" },
  { label = "Zoomable float (zen)", mode = "zen" },
}

-- Formats images.nvim draws or converts; anything else (tiff, ico) stays with the system viewer.
local EXTENSIONS =
  { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true, svg = true }

---@param path string
---@return boolean
function M.is_image(path)
  if type(path) ~= "string" or path == "" then return false end
  return EXTENSIONS[vim.fn.fnamemodify(path, ":e"):lower()] == true
end

---Whether images.nvim is installed (soft dependency).
---@return boolean
function M.available()
  local ok, images = pcall(require, "images")
  return ok and type(images) == "table" and type(images.show) == "function"
end

---@return { picker: boolean, default: GopathImageMode, optout: boolean }
local function image_config()
  local ext = require("gopath.config").get().external or {}
  local cfg = ext.images or {}
  return {
    picker = cfg.picker ~= false,
    default = cfg.default or "system",
    optout = cfg.optout == true,
  }
end

---Open `path` in the given mode.
---@param mode GopathImageMode
---@param path string
---@return nil
local function dispatch(mode, path)
  if mode == "system" then
    require("gopath.external").open(path)
    return
  end

  local ok, images = pcall(require, "images")
  local fn = ok and type(images) == "table" and images[mode] or nil
  if type(fn) ~= "function" then
    LOG.warn("images.nvim unavailable -- opening in system app instead")
    require("gopath.external").open(path)
    return
  end

  local ok_open, err = pcall(fn, path)
  if not ok_open then
    LOG.error("images.nvim failed: " .. tostring(err) .. " -- falling back to system app")
    require("gopath.external").open(path)
  end
end

---Handle an image, offering the mode chooser when images.nvim is available.
---@param path string
---@return boolean handled  false -> caller should fall back to the system opener
function M.try_open(path)
  if not M.is_image(path) then return false end
  local cfg = image_config()
  if cfg.optout then return false end
  if not M.available() then return false end

  if not cfg.picker then
    dispatch(cfg.default, path)
    return true
  end

  local ok_kit, kit = pcall(require, "ui.kit")
  if not ok_kit or type(kit.select) ~= "function" then
    -- ui.nvim missing: don't silently pick a mode for the user, keep the pre-images.nvim behaviour.
    return false
  end

  kit.select({
    items = CHOICES,
    title = "Open image: " .. vim.fn.fnamemodify(path, ":t"),
    format_item = function(item)
      return item.label
    end,
    on_select = function(item)
      dispatch(item.mode, path)
    end,
    -- Cancelling means "never mind" -- opening it anyway would defeat the point.
    on_cancel = function() end,
  })

  return true
end

return M
