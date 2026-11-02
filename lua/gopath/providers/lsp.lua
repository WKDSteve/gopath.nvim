---@module 'gopath.providers.lsp'
---@brief LSP provider with proper range normalization.

local LOC = require("gopath.util.location")

local M = {}

---True when `v` is a real value of `expected_type` -- rejects both Lua `nil`
---and `vim.NIL` (what JSON/LSP `null` decodes to). `vim.NIL` is truthy in
---Lua, so a bare `if v then` admits it and the next use throws instead of
---treating the field as absent.
---@internal
---@param v any
---@param expected_type type
---@return boolean
local function present(v, expected_type)
  return v ~= nil and v ~= vim.NIL and type(v) == expected_type
end

---Whether `rng.start` is a usable LSP Position -- present as a table (not
---nil, not vim.NIL) with numeric `line`/`character` fields.
---
---`present(rng, "table")` alone only proves `range` itself survived the
---nil/vim.NIL check; `range.start` (and `.line`/`.character` on it) are
---separate JSON fields that can independently decode to vim.NIL or be
---omitted entirely, and either would throw on `rng.start.line` below rather
---than being skipped like a malformed uri/range is (LUA-16).
---@internal
---@param rng table
---@return boolean
local function has_start_position(rng)
  local start = rng.start
  return present(start, "table")
    and present(start.line, "number")
    and present(start.character, "number")
end

---Whether any language server is attached to the current buffer.
---
---Asked before the request, because `buf_request_sync` does not return early
---when nothing is attached -- it blocks for the whole timeout instead. See
---docs/resolution.md#the-lsp-step-does-not-wait-for-a-server-that-is-not-there
---for the measurements and why this deliberately does not check
---`textDocument/definition` support.
---
---@return boolean
local function has_client()
  local ok, clients = pcall(vim.lsp.get_clients, { bufnr = 0 })
  return ok and type(clients) == "table" and #clients > 0
end

---Short, sync definition request with normalized ranges
---@param timeout_ms integer Timeout in milliseconds
---@return table[]|nil results List of { path: string, range: { line: integer, col: integer } }
function M.definition_at_cursor(timeout_ms)
  if not has_client() then return nil end

  local params = vim.lsp.util.make_position_params(0, "utf-8")
  local res = vim.lsp.buf_request_sync(0, "textDocument/definition", params, timeout_ms)

  if not res then return nil end

  local out = {}
  for _, r in pairs(res) do
    local result = r.result
    if type(result) == "table" then
      local list = result.uri and { result } or result

      for _, loc in ipairs(list) do
        local uri = loc.uri or loc.targetUri
        local rng = loc.range or loc.targetRange

        -- A spec-conforming server never sends `null` here (both fields are
        -- non-nullable in Location/LocationLink), but a `uri`/`rng` of
        -- vim.NIL must not sail through a bare truthiness check and throw
        -- three lines down -- one bad entry should be skipped, not take the
        -- whole response down with it. Same reasoning one level deeper for
        -- `rng.start` (LUA-16).
        if present(uri, "string") and present(rng, "table") and has_start_position(rng) then
          local p = vim.uri_to_fname(uri)

          -- LSP ranges are 0-indexed, convert to 1-indexed
          local normalized = LOC.normalize_range({
            line = rng.start.line + 1,
            col = rng.start.character + 1,
          })

          out[#out + 1] = {
            path = p,
            range = normalized,
          }
        end
      end
    end
  end

  return (#out > 0) and out or nil
end

return M
