---@module 'gopath.resolvers.common.linepath'
---@brief Scan the entire current line for path-like candidates.
--- Complements filetoken (which uses <cfile>) by applying three heuristics
--- to the full line content: stacktrace patterns, extension-driven expansion,
--- and absolute path matching.
---
--- Resolution order per candidate:
---   1. Absolute / cwd-relative (vim.uv.fs_stat)
---   2. tailsearch suffix search across project roots
---
--- Meant to run in the pipeline AFTER filetoken but BEFORE language resolvers,
--- so it can catch paths that <cfile> would miss (e.g. the cursor sits on a
--- word in a stacktrace line, not on the path segment itself).

local M = {}

local find = require("gopath.resolvers.common.extractor.find")
local helpers = require("gopath.resolvers.common.extractor.helpers")
local TS = require("gopath.resolvers.common.tailsearch")

local uv = vim.uv or vim.loop

---The cursor line, or `text` when given (`require("gopath").resolve_line`):
---a caller that holds a line -- a stack frame of a log view -- asks without a
---buffer showing it. `opts.dir` then stands in for the buffer's folder.
---@param text string|nil
---@param opts { dir?: string }|nil
---@return GopathResult|nil
function M.resolve(text, opts)
  local cfg = require("gopath.config").get()
  if not (cfg.linepath and cfg.linepath.enable) then return nil end

  local line = text
  if type(line) ~= "string" then line = vim.api.nvim_get_current_line() end
  if not line or line == "" then return nil end
  local language = type(text) == "string" and "text" or (vim.bo.filetype or "text")

  -- Collect candidates from all three heuristics
  local raw = {}
  for _, c in ipairs(find.stack_patterns(line) or {}) do
    raw[#raw + 1] = c
  end
  for _, c in ipairs(find.by_extension(line) or {}) do
    raw[#raw + 1] = c
  end
  for _, c in ipairs(find.absolute_paths(line) or {}) do
    raw[#raw + 1] = c
  end
  local candidates = helpers.uniq(raw)

  if #candidates == 0 then return nil end

  local ts_cfg = cfg.tailsearch or {}
  local max_comp = ts_cfg.max_components or 6

  ---Build a GopathResult for a found file candidate.
  ---@internal
  ---@param path string
  ---@param lineno integer|nil
  ---@param col integer|nil
  ---@param source string
  ---@param confidence number
  ---@return GopathResult
  local function make_result(path, lineno, col, source, confidence)
    return {
      language = language,
      kind = "file",
      path = path,
      range = (lineno and lineno > 0) and { line = lineno, col = col or 1 } or nil,
      chain = nil,
      source = source,
      confidence = confidence,
      exists = true,
    }
  end

  for _, cand in ipairs(candidates) do
    local path = cand.path or ""
    if path == "" then goto continue end

    -- `vim.fs.normalize` only rewrites "\" to "/" on Windows itself -- on
    -- Linux a backslash-spelled candidate (extracted verbatim from the
    -- line's raw text by extractor/find.lua) survives untouched, so every
    -- fs_stat below would silently miss a file that exists under its
    -- forward-slash spelling. Same defect and same fix as
    -- util.path.exists() and tailsearch.normalize().
    path = (path:gsub("\\", "/"))

    local lineno = cand.lineno
    local col = cand.col

    -- 1) Try absolute path as-is
    local norm = vim.fs.normalize(path)
    local st = uv.fs_stat(norm)
    if st and st.type == "file" then
      return make_result(norm, lineno, col, "linepath-absolute", 0.92)
    end

    -- 2) Try cwd-relative
    local cwd = (uv.cwd and uv.cwd()) or vim.fn.getcwd()
    local rel = vim.fs.normalize(cwd .. "/" .. path)
    st = uv.fs_stat(rel)
    if st and st.type == "file" then
      return make_result(rel, lineno, col, "linepath-relative", 0.88)
    end

    -- 2b) Try buffer-relative. Links inside a document (Markdown `[x](a/b.pdf)`,
    --     include directives, …) are *document*-relative by definition, not
    --     cwd-relative — so a link only resolvable this way would otherwise fall
    --     through to the fuzzy tail search, or fail outright when the cursor sits
    --     on the link label rather than on the path token (filetoken, which has
    --     its own bufdir fallback, never sees it in that case).
    --     Deliberately ordered AFTER cwd so existing resolutions never change;
    --     this only adds hits that previously failed.
    local bufdir = type(text) == "string" and (opts and opts.dir or "") or vim.fn.expand("%:p:h")
    if bufdir ~= "" then
      local brel = vim.fs.normalize(bufdir .. "/" .. path)
      st = uv.fs_stat(brel)
      if st and st.type == "file" then
        return make_result(brel, lineno, col, "linepath-bufdir", 0.9)
      end
    end

    -- 3) Suffix search via cache only (instant, non-blocking). The live
    --    filesystem walk is deferred to the async command layer to keep the
    --    resolve pipeline from freezing the UI on large trees.
    local tail = path:gsub("\\", "/"):gsub("[\"'" .. "`]+", ""):gsub("^%.*%/*", "")
    if tail ~= "" then
      local res = TS.resolve_cached(tail, {
        max_components = max_comp,
        line = lineno,
        col = col,
      })
      if res then
        res.source = "linepath-tail"
        res.confidence = res.confidence * 0.95 -- slight discount vs direct hit
        return res
      end
    end

    ::continue::
  end

  return nil
end

return M
