---@module 'gopath.config'
---@brief User-options merge and sane defaults.
---@description
--- Owns a single module-level state table that is populated once by `setup()`
--- and read-only afterwards via `get()`. Deep-merges user options on top of
--- the built-in defaults (see `gopath.config.DEFAULTS`) so that callers can
--- override only what they need.

local M = {}

local defaults = require("gopath.config.DEFAULTS")

---True when `t` is a plain array: keys are exactly `1..n` with no holes and
---no string keys. An empty table counts as a list.
---@private
---@param t table
---@return boolean
local function is_list(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

---True when array-shaped `t` (already known to satisfy `is_list`) holds only
---string elements. An empty list is vacuously a string list, matching how
---`"list"` already treats an empty table as valid.
---@private
---@param t table
---@return boolean
local function is_string_list(t)
  for _, v in ipairs(t) do
    if type(v) ~= "string" then return false end
  end
  return true
end

---Keys `setup()` recognizes, recursively: a nested table's own value may
---itself be one of these tags (see `alternate.frecency`/`external.pdf`
---below), and `validate_value` walks the whole thing by full dotted path
---(ERR-50) -- not just one or two levels, which is the shape this fleet's
---audit keeps finding half-fixed elsewhere. The levenshtein did-you-mean
---candidates in `describe_unknown` are always drawn from the correct
---sibling set for whatever depth is being checked, never a flat/bare-name
---match across the whole schema.
---
---  * `"list"` — a curated array (see `deep_merge_into`'s docstring); a
---    non-list value is a type error, not an override.
---  * `"string_list"` — a curated array like `"list"`, plus every element
---    must be a string; a non-list value, or a list with a non-string
---    element, is a type error. Reserved for a field a downstream consumer
---    feeds straight into a string-keyed lookup without its own per-element
---    guard: `truncated.excluded_dirs` (`vim.tbl_contains(config.excluded_dirs,
---    name)` in `truncated/cache.lua`'s `is_excluded()`, reached from the
---    async scan callback on every directory visited).
---  * `"open"` — a table whose own keys are not a closed set (`languages` is
---    keyed by filetype, including ones gopath has no built-in resolver for)
---    and are therefore never flagged as unknown, nor recursed into.
---  * a nested table — recursed into, the same way as the top level: an
---    unknown key is flagged (by its full dotted path) but kept (extension
---    point), a `"list"`/`"open"`/`"number"` leaf is type-checked, and a
---    further nested table is validated the same way again, to whatever
---    depth the schema actually has. Leaf value types this fleet's consumers
---    already guard well enough for themselves (`string|string[]|false`
---    keymaps, `boolean` toggles) stay tagged `true` rather than duplicating
---    that guard here. `mappings`/`commands` additionally accept a bare
---    `false` in place of the table (see `ALLOW_FALSE`) — the documented way
---    to disable the whole preset (docs/configuration.md); that shorthand is
---    only recognized at the top level, since nothing nested currently uses it.
---  * `true` — any value goes unchecked (scalars, and `languages`' sibling
---    `dev_mode`/`mode`/`which_key`/`deps_popup`).
---  * `"number"` — value must be a Lua number or it is dropped so the default
---    survives (ERR-22). Reserved for fields a downstream consumer feeds
---    straight into arithmetic or a relational comparison without its own
---    type guard: `lsp_timeout_ms` (`vim.wait` inside LSP resolution),
---    `alternate.similarity_threshold` (`similarity >= threshold`),
---    `truncated.max_depth` (`item.depth < config.max_depth` during the async
---    scan), `truncated.cache_refresh_interval`/`truncated.max_cache_age`
---    (both reached synchronously from `setup()` itself, so a wrong type here
---    used to crash the whole plugin init, not just degrade one feature), and
---    `tailsearch.max_components`/`tailsearch.limit` (`math.min`/`math.max`
---    on the resolve fast path). Zero and negative values are left alone —
---    every one of those consumers already tolerates them.
---@alias GopathConfigSpec true|"list"|"string_list"|"open"|"number"|table<string, GopathConfigSpec>
---@type table<string, GopathConfigSpec>
local KNOWN = {
  dev_mode = true,
  mode = true,
  order = "list",
  lsp_timeout_ms = "number",
  languages = "open",
  alternate = {
    enable = true,
    similarity_threshold = "number",
    -- Itself a nested table (enable/max_bonus/dir), not a scalar -- a typo
    -- here (e.g. `max_bnus`) used to be invisible: the old schema stopped
    -- recursing at `alternate`'s own keys and marked this whole sub-table
    -- `true` ("any value unchecked"), so nothing below it was ever looked
    -- at (ERR-50: recursion that stops 1-2 levels deep).
    frecency = {
      enable = true,
      max_bonus = true, -- already tonumber()-coerced at its consumer
      dir = true,
    },
  },
  external = {
    enable = true,
    extensions = true,
    -- Same fix as `alternate.frecency` above: `pdf` is a nested
    -- {picker, default} table, not a scalar.
    pdf = {
      picker = true,
      default = true,
    },
    images = {
      picker = true,
      default = true,
      optout = true,
    },
  },
  url = {
    enable = true,
    bare_hosts = true,
    schemes = true,
    tlds = true,
  },
  env_variable_resolution = {
    enable = true,
    shorten_dirs = true,
    shorten_known_dirs = true,
    root_search = {
      enable = true,
      max_depth = "number",
      max_dirs = "number",
    },
  },
  create_on_missing = {
    enable = true,
    confirm = true,
  },
  truncated = {
    enable = true,
    use_cache = true,
    cache_refresh_interval = "number",
    rtp_index_ttl_ms = true,
    max_cache_age = "number",
    live_search_fallback = true,
    similarity_threshold = true,
    cache_roots = "string_list",
    max_depth = "number",
    max_paths = "number",
    excluded_dirs = "string_list",
    watch_patterns = true,
    auto_rebuild_on_save = true,
  },
  linepath = {
    enable = true,
    cascade = true,
  },
  tailsearch = {
    enable = true,
    max_components = "number",
    ask_on_ambiguous = true,
    roots = true,
    limit = "number",
  },
  tasks = {
    enable = true,
    vaults = "string_list",
  },
  commit = {
    enable = true,
    open = true,
  },
  mappings = {
    open_here = true,
    open_split = true,
    open_vsplit = true,
    open_tab = true,
    open_explorer = true,
    copy_location = true,
    debug = true,
    probe = true,
    check = true,
    ask_commit = true,
  },
  commands = {
    resolve = true,
    open = true,
    copy = true,
    debug = true,
    check = true,
    to_repos_dir = true,
  },
  which_key = true,
  deps_popup = true,
  integrations = { ui_menu = true },
}

---Top-level keys whose known-table entry also accepts a bare `false` instead
---of a table (see `KNOWN`'s docstring).
---@type table<string, true>
local ALLOW_FALSE = { mappings = true, commands = true, tasks = true, commit = true }

---What the last `setup()` had to reject or flag, for `:checkhealth`. Reset on
---every call so issues from an earlier setup() never linger.
---@type string[]
local issues = {}

---`key` with the nearest known one as a hint when there is a plausible one
---(edit distance <= 3).
---@internal
---@param key any
---@param known table<string, any>
---@param prefix string
---@return string
local function describe_unknown(key, known, prefix)
  local levenshtein = require("lib.lua.strings.distance").levenshtein
  local name = tostring(key)
  local best, best_distance = nil, nil
  for candidate in pairs(known) do
    local d = levenshtein(name, candidate)
    if d <= 3 and (best_distance == nil or d < best_distance) then
      best, best_distance = candidate, d
    end
  end
  if best then
    return ("unknown option '%s%s' (did you mean '%s%s'?)"):format(prefix, name, prefix, best)
  end
  return ("unknown option '%s%s'"):format(prefix, name)
end

---Validate one `value` against one `spec` node (a `KNOWN` entry or one of its
---descendants), recording any issue against its full dotted `path`.
---
---This is the ERR-50/ERR-22 workhorse, and it recurses: when `spec` is
---itself a table, every one of `value`'s keys is checked against it, and a
---sub-key whose own spec is *also* a table recurses again through this same
---function -- to whatever depth the schema actually has, not just one or two
---levels (the self-inflicted bug this fleet's audit keeps finding: a
---validator that stops recursing before the config actually does).
---
---An unknown key is flagged but kept in the returned copy (an established
---extension point -- see the "unknown keys are kept" spec) so a typo like
---`truncted` for `truncated`, or `alternate.frecency.max_bnus` for
---`max_bonus`, is at least visible instead of silently leaving the real
---option at its default forever. A `"list"`/`"string_list"`/`"open"`/`"number"`
---leaf whose value does not fit is dropped instead -- one field falls back to
---its default rather than a crash three modules downstream: `order = "lsp"`
---(a string, not a list) used to throw "table expected, got string" out of
---`resolve.lua`'s `ipairs(cfg.order)`, `languages = false` used to throw
---"attempt to index a boolean value" the same way, a wrong-type `"number"`
---leaf (e.g. `truncated.max_depth = "6"`, `tailsearch.max_components = "abc"`)
---used to throw a "compare"/"arithmetic on a string/table/boolean value"
---error out of whichever consumer used the raw value without its own guard
----- for `truncated.cache_refresh_interval`/`max_cache_age` that consumer is
---`setup()` itself (`gopath.init._setup_cache`), so the crash took the whole
---plugin init down rather than just degrading the one feature -- and a
---non-string-list `truncated.excluded_dirs` (e.g. a bare string) used to
---throw "expected table, got string" out of `truncated/cache.lua`'s
---`is_excluded()` (`vim.tbl_contains(config.excluded_dirs, name)`), reached
---from the async scan's `fs_scandir` callback on the first directory visited.
---Dropping only the one bad leaf (not its whole parent table) means
---`deep_merge_into` leaves every other, valid sibling of e.g. `truncated` or
---`alternate.frecency` exactly as the caller supplied it.
---
---`false` in place of a table is accepted only when `allow_false` is true
---(top-level `mappings`/`commands` -- see `ALLOW_FALSE`); nothing nested
---currently has that shorthand, so recursive calls never pass it.
---@internal
---@param value any
---@param spec GopathConfigSpec
---@param path string  full dotted path for messages, e.g. "alternate.frecency.max_bonus"
---@param allow_false boolean
---@param found_issues string[]  appended to in place
---@return any cleaned  the value to keep (a filtered copy, for a table spec)
---@return boolean keep  false means the caller must not merge this in at all
local function validate_value(value, spec, path, allow_false, found_issues)
  if spec == true then
    return value, true
  elseif spec == "list" then
    if type(value) == "table" and is_list(value) then return value, true end
    found_issues[#found_issues + 1] = ("option '%s' must be a list, got %s -- using the default"):format(
      path,
      type(value)
    )
    return nil, false
  elseif spec == "string_list" then
    if type(value) == "table" and is_list(value) and is_string_list(value) then
      return value, true
    end
    local got = type(value) ~= "table" and type(value) or "a list with a non-string element"
    found_issues[#found_issues + 1] = ("option '%s' must be a list of strings, got %s -- using the default"):format(
      path,
      got
    )
    return nil, false
  elseif spec == "open" then
    if type(value) == "table" then return value, true end
    found_issues[#found_issues + 1] = ("option '%s' must be a table, got %s -- using the default"):format(
      path,
      type(value)
    )
    return nil, false
  elseif spec == "number" then
    if type(value) == "number" then return value, true end
    found_issues[#found_issues + 1] = ("option '%s' must be a number, got %s -- using the default"):format(
      path,
      type(value)
    )
    return nil, false
  elseif type(spec) == "table" then
    if value == false and allow_false then return value, true end
    if type(value) ~= "table" then
      local shape = allow_false and "a table or false" or "a table"
      found_issues[#found_issues + 1] = ("option '%s' must be %s, got %s -- using the default"):format(
        path,
        shape,
        type(value)
      )
      return nil, false
    end
    local clean_value = {}
    for sub_key, sub_value in pairs(value) do
      local sub_spec = spec[sub_key]
      local sub_path = path .. "." .. tostring(sub_key)
      if sub_spec == nil then
        found_issues[#found_issues + 1] = describe_unknown(sub_key, spec, path .. ".")
        clean_value[sub_key] = sub_value
      else
        local cleaned, keep = validate_value(sub_value, sub_spec, sub_path, false, found_issues)
        if keep then clean_value[sub_key] = cleaned end
      end
    end
    return clean_value, true
  end
  return value, true
end

---Validate `opts` against `KNOWN` before the merge (ERR-50/ERR-22, see
---`validate_value`).
---
---Does not mutate `opts` — a type-invalid entry is left out of the returned
---copy rather than stripped from the caller's own table.
---@internal
---@param opts table
---@return table  a shallow copy of opts, minus type-invalid entries
---@return string[] found_issues
local function validate(opts)
  local clean, found_issues = {}, {}
  for key, value in pairs(opts) do
    local known = KNOWN[key]
    if known == nil then
      found_issues[#found_issues + 1] = describe_unknown(key, KNOWN, "")
      clean[key] = value
    else
      local cleaned, keep = validate_value(value, known, key, ALLOW_FALSE[key], found_issues)
      if keep then clean[key] = cleaned end
    end
  end
  table.sort(found_issues)
  return clean, found_issues
end

---Recursively merge `src` into `dst`, preferring `src` values.
---
---Closed, curated array fields (e.g. `order`, `truncated.excluded_dirs`) are
---replaced wholesale rather than merged index-wise: index-wise merging (the
---same trap `vim.tbl_deep_extend` has for lists) would otherwise leave
---trailing default entries behind a shorter user-supplied list. E.g. a user
---setting `order = { "treesitter" }` to opt out of "lsp" and "builtin" would,
---under index-wise merging, get back `{ "treesitter", "treesitter", "builtin" }`
---(index 1 overwritten, indices 2-3 left over from the 3-element default) —
---"builtin" silently keeps running despite being explicitly left out.
---@private
---@param dst table
---@param src table
local function deep_merge_into(dst, src)
  assert(type(dst) == "table", "deep_merge_into: dst must be a table")
  for k, v in pairs(src or {}) do
    if type(v) == "table" and type(dst[k]) == "table" then
      if is_list(v) and is_list(dst[k]) then
        dst[k] = vim.deepcopy(v)
      else
        deep_merge_into(dst[k], v)
      end
    else
      dst[k] = v
    end
  end
end

---Reset `dst` in place to match `src` (the defaults), mutating rather than
---replacing every table it descends into (ERR-53) — a consumer that stashed
---a reference to one of `dst`'s sub-tables (e.g. `gopath.init._setup_cache`'s
---`tcfg`, or a test's `config.get().truncated`) must still see the reset
---values through that same reference, not a detached copy.
---@private
---@param dst table
---@param src table
local function reset_into(dst, src)
  for k in pairs(dst) do
    if src[k] == nil then dst[k] = nil end
  end
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      reset_into(dst[k], v)
    else
      dst[k] = v
    end
  end
end

---@type GopathOptions
local state = vim.deepcopy(defaults)

---Merge `opts` on top of the built-in defaults.
---
---`state` is reset to a fresh copy of the defaults first, so every call
---starts from the same baseline instead of re-merging on top of whatever an
---earlier call left behind — `setup({ truncated = { enable = false } })`
---followed by `setup({})` leaves `truncated.enable` back at its default
---(`true`), not stuck at `false` (LUA-87). That holds for `setup(nil)` and
---`setup()` too: they are the defaults, not a call that changes nothing. A
---non-table argument (`setup("x")`) resets as well and is reported through
---`M.issues()`.
---
---`opts` is validated first (ERR-50/ERR-22): a value whose shape does not fit
---its option is dropped so the built-in default is what actually takes
---effect, and every issue is both warned here and kept for `:checkhealth`
---(see `M.issues()`).
---@param opts GopathOptions|nil
function M.setup(opts)
  reset_into(state, defaults)
  local clean, found_issues
  if opts ~= nil and type(opts) ~= "table" then
    clean, found_issues =
      {}, { ("setup() takes a table of options, got %s -- ignored"):format(type(opts)) }
  else
    clean, found_issues = validate(opts or {})
  end
  issues = found_issues
  if #issues > 0 then
    require("gopath.util.log").warn("invalid config: " .. table.concat(issues, "; "))
  end
  deep_merge_into(state, clean)
end

---Return the current effective configuration (read-only reference).
---@return GopathOptions
function M.get()
  return state
end

---What the last `setup()` had to reject or flag: unknown keys (with a
---did-you-mean hint) and options whose value did not fit their expected
---shape, one human-readable line each. Empty when everything was recognized
---and well-typed.
---@return string[]
function M.issues()
  return vim.list_extend({}, issues)
end

return M
