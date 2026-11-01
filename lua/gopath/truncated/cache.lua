---@module 'gopath.truncated.cache'
---@description Async filesystem cache for fast truncated path resolution.
---
---Features:
---  - Async, non-blocking filesystem scanning
---  - In-memory storage for fast lookups
---  - Periodic background refresh
---  - Smart exclusions (.git, node_modules, etc.)
---  - Configurable scan roots (drives, directories)
---
---Cache lifecycle:
---  1. Load from disk on the first lookup that needs it (not in setup())
---  2. Build async if cache is old/missing/rejected (background); the age is
---     the file's mtime until the index is loaded (`needs_refresh`)
---  3. Refresh periodically (configurable interval)
---  4. Save to disk after each build

local M = {}

local safe = require("gopath.util.safe_notify")
local LOG = require("gopath.util.log")
local uv = vim.loop

---Deterministic, filesystem-safe short key for `s`. Not cryptographic --
---only used to tell one project's scan-roots set apart from another's on
---disk (same convention as lib.nvim's store/project module, which cannot be
---required directly here since it is a private local there).
---@internal
---@param s string
---@return string
local function short_hash(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return string.format("%08x", h)
end

---Order-independent, separator/case-normalized fingerprint of a roots list.
---@internal
---@param roots string[]
---@return string
local function roots_fingerprint(roots)
  local normalized = {}
  for i, r in ipairs(roots) do
    normalized[i] = (r:gsub("\\", "/")):lower()
  end
  table.sort(normalized)
  return table.concat(normalized, "\n")
end

---@class CacheConfig
---@field max_depth? integer Maximum directory depth to scan
---@field max_concurrency? integer Max directories scanned concurrently (bounds open handles)
---@field excluded_dirs? string[] Directories to skip during scan
---@field cache_file? string Path to persistent cache file
---@field scan_roots? string[] Directories/drives to scan
---@field max_paths? integer Most file paths one build indexes (shallow levels first)

---Default cache configuration
---User can override via gopath.setup({ truncated = { cache_roots = {...} } })
---@type CacheConfig
local config = {
  max_depth = 6, -- Don't descend too deep (performance)

  -- Most file paths one build indexes. Without a bound, a scan root that
  -- happens to be huge (the cwd of a session started in %TEMP% or the profile
  -- directory) produced a 122 MB cache file of 727,000 paths whose load, decode
  -- and `reindex` blocked startup for ~3 s, and every rebuild again for ~2 s.
  -- The scan is breadth-first, so what survives the cap are the shallow levels
  -- of every root; the live search still covers a miss. Measured: a normal
  -- session indexes ~35,000 paths, a cwd of the profile directory ~207,000.
  max_paths = 300000,

  -- Maximum number of directories scanned concurrently. Bounding this prevents
  -- libuv threadpool / open-file-handle exhaustion (EMFILE) on huge trees.
  max_concurrency = 16,

  -- Smart exclusions: common directories that bloat cache
  excluded_dirs = {
    ".git",
    ".github",
    ".svn",
    ".hg", -- VCS
    "node_modules",
    "target",
    "build",
    "dist", -- Build artifacts
    ".cache",
    ".venv",
    "venv",
    "__pycache__", -- Python
    ".nuxt",
    ".next",
    ".turbo", -- JS frameworks
    "tmp",
    "temp",
    "vendor", -- Temp/deps
  },

  -- Persistent cache location. Recomputed in M.setup() once scan_roots is
  -- known -- see the PERF-46 comment there for why a fixed path is wrong.
  cache_file = vim.fn.stdpath("cache") .. "/gopath_fs_cache.json",

  -- Default scan roots (will be set in M.setup())
  scan_roots = {},
}

---Recompute `config.cache_file` from the current `config.scan_roots` (PERF-46).
---Must be called after ANY mutation of `config.scan_roots` -- not just from
---`M.setup()` -- otherwise the persisted file keeps living at the filename
---hashed from the stale roots set while its `scan_roots` field (written by
---`M._save_to_disk`) reflects the new one. `load_from_disk`'s revalidation
---then rejects that same file on every later session (persisted roots !=
---freshly-recomputed roots), forcing a full rescan forever even though the
---cache was a valid superset. See `M.add_root`.
---@internal
---@return nil
local function refresh_cache_file()
  config.cache_file = vim.fn.stdpath("cache")
    .. "/gopath_fs_cache_"
    .. short_hash(roots_fingerprint(config.scan_roots))
    .. ".json"
end

---Cache state
---Stored in memory for fast access during Neovim session
---`norm[i]` is the lowercased, forward-slash form of `paths[i]`, precomputed
---once per index rather than per query. `M.search` used to derive it inline for
---every cached path on every lookup — two string allocations × 20k+ paths ×
---every keystroke-triggered resolve. Keep the two arrays index-aligned.
---@type { paths: string[], norm: string[], last_built: integer|nil, building: boolean, capped: boolean, unusable: boolean }
local state = {
  paths = {}, -- All indexed file paths
  norm = {}, -- paths[i] lowercased with "/" separators
  last_built = nil, -- Unix timestamp of last cache build
  building = false, -- Flag to prevent concurrent builds
  capped = false, -- The last build stopped at `config.max_paths`
  unusable = false, -- The file on disk was read and rejected (unparseable, other roots)
  rebuild_asked = false, -- `search` already started the one rebuild this `unusable` verdict gets
  saved = nil, -- { file, digest } of the index last written to (or confirmed on) disk
}

---Whether the "path cache is capped" warning was already shown this session.
---@type boolean
local cap_warned = false

---Rebuild the `norm` mirror of `state.paths`.
---@internal
---@return nil
local function reindex()
  local norm = {}
  local paths = state.paths
  for i = 1, #paths do
    norm[i] = paths[i]:gsub("\\", "/"):lower()
  end
  state.norm = norm
end

---Setup cache configuration from user options
---Called during gopath.setup()
---@param opts table|nil User configuration for truncated.cache_roots
function M.setup(opts)
  opts = opts or {}

  -- === Configure Scan Roots ===
  if opts.roots and #opts.roots > 0 then
    -- User explicitly specified roots. Copied, not aliased: `opts.roots` is
    -- `config.get().truncated.cache_roots` (gopath.init._setup_cache), the
    -- live, shared config table documented as a "read-only reference" --
    -- M.add_root mutates `config.scan_roots` in place, and without this copy
    -- that mutation would leak into the user's own options table for the
    -- rest of the session (ERR-54).
    config.scan_roots = vim.deepcopy(opts.roots)
  else
    -- === Auto-detect Default Roots ===
    -- Deliberately conservative: indexing a whole drive (C:\) or the entire
    -- user profile to max_depth on startup produces a huge, slow cache. We
    -- stick to the directories that actually hold openable files for this
    -- editor. Users who need more can pass `truncated.cache_roots`.
    -- Git root is resolved by walking up for a `.git` marker (lib.nvim), NOT by
    -- shelling out to `git rev-parse`. The old call was a synchronous subprocess
    -- spawn on the main loop during setup() — expensive on Windows (AV scan on
    -- every spawn) — and its `2>/dev/null` redirect is POSIX shell syntax that
    -- cmd.exe does not understand, so on Windows it also polluted the result.
    local git_root
    do
      local ok, find_root = pcall(require, "lib.nvim.fs.find_root")
      if ok then
        local ok_find, root = pcall(function()
          return find_root({ markers = { ".git" } }).find(vim.fn.getcwd())
        end)
        if ok_find then git_root = root end
      end
    end

    local candidates = {
      vim.fn.getcwd(), -- project / working directory
      vim.fn.stdpath("config"), -- nvim config (init, lua/, …)
      vim.fn.stdpath("data"), -- plugins (lazy/, …)
      vim.fn.stdpath("cache"), -- runtime/cache files
      git_root, -- git repository root (if in one)
    }
    config.scan_roots = {}
    for _, p in ipairs(candidates) do
      if type(p) == "string" and p ~= "" and vim.fn.isdirectory(p) == 1 then
        table.insert(config.scan_roots, p)
      end
    end
    config.scan_roots = require("lib.lua.tables").dedup_list(config.scan_roots)
  end

  -- The persisted cache file is keyed by the scan roots it indexes (PERF-46):
  -- a single fixed path shared by every project meant that project B's
  -- startup could silently load project A's file list (stale until the next
  -- refresh interval), and that every project's build overwrote every
  -- other's on disk. `load_from_disk` revalidates the `scan_roots` field
  -- against this too, as a second line of defense against a hash collision
  -- or a hand-copied file.
  local previous_file = config.cache_file
  refresh_cache_file()
  -- A verdict on the previous file says nothing about this one.
  state.unusable, state.rebuild_asked = false, false
  -- A second setup() with other roots (a `:cd` under default roots, then
  -- setup() again) must not keep answering from the old roots' index: drop it,
  -- so `search` loads the new file and `needs_refresh` reads its mtime. A
  -- build that is running scans the OLD roots; `_finalize_build` notices the
  -- file it started for is no longer the live one and throws its result away.
  if config.cache_file ~= previous_file and not state.building then
    state.paths, state.norm, state.last_built, state.capped = {}, {}, nil, false
  end

  -- === Apply Other Config Options ===
  if opts.max_depth then config.max_depth = opts.max_depth end

  if type(opts.max_paths) == "number" and opts.max_paths > 0 then
    config.max_paths = opts.max_paths
  end

  if opts.excluded_dirs then config.excluded_dirs = opts.excluded_dirs end
end

---Check if directory should be excluded from scan
---@internal
---@param name string Directory name (basename only)
---@return boolean should_exclude True if directory should be skipped
local function is_excluded(name)
  return vim.tbl_contains(config.excluded_dirs, name)
end

---Scan a set of roots with bounded concurrency (async, non-blocking).
---
--- A work queue of `{ dir, depth }` items is processed by at most
--- `config.max_concurrency` in-flight `fs_scandir` operations. Subdirectories
--- are pushed back onto the queue instead of recursing immediately, so the
--- number of simultaneously open directory handles stays bounded regardless of
--- tree size. This avoids EMFILE / threadpool starvation on very large trees
--- while still keeping the whole scan off the main loop.
---
---@internal
---@param roots string[] Root directories to scan
---@param on_done fun(paths: string[], capped: boolean) Called once with every discovered file path;
---  `capped` is true when the scan stopped at `config.max_paths` before it had seen everything
local function scan_roots_bounded(roots, on_done)
  local queue = {} -- pending { dir=string, depth=integer } items
  local results = {} -- accumulated file paths
  local active = 0 -- in-flight fs_scandir operations
  local qhead = 1 -- queue read cursor (avoids table.remove shifts)
  local capped = false -- `config.max_paths` reached: collect and descend no further
  local max_paths = config.max_paths

  for i = 1, #roots do
    queue[#queue + 1] = { dir = roots[i], depth = 0 }
  end

  local pump -- forward declaration

  ---Scan one directory; push child dirs back onto the queue, collect files.
  ---@internal
  ---@param item { dir:string, depth:integer }
  local function scan_one(item)
    uv.fs_scandir(item.dir, function(err, handle)
      if err or not handle then
        active = active - 1
        pump()
        return
      end

      while true do
        local name, typ = uv.fs_scandir_next(handle)
        if not name then break end

        local full_path = item.dir .. "/" .. name
        if typ == "file" then
          if #results < max_paths then
            results[#results + 1] = full_path
          else
            capped = true
          end
        elseif typ == "directory" and not is_excluded(name) and item.depth < config.max_depth then
          queue[#queue + 1] = { dir = full_path, depth = item.depth + 1 }
        end
      end

      active = active - 1
      pump()
    end)
  end

  ---Fill available concurrency slots from the queue; finish when fully drained.
  ---@internal
  pump = function()
    -- At the cap nothing queued can add a path any more: drop the rest of the
    -- queue instead of listing every remaining directory for nothing.
    if capped then qhead = #queue + 1 end

    while active < config.max_concurrency and qhead <= #queue do
      local item = queue[qhead]
      qhead = qhead + 1
      active = active + 1
      scan_one(item)
    end

    if active == 0 and qhead > #queue then on_done(results, capped) end
  end

  -- Empty input → complete immediately on next tick.
  if #queue == 0 then
    vim.schedule(function()
      on_done(results, false)
    end)
  else
    pump()
  end
end

---Build cache from configured scan roots.
---Non-blocking: runs entirely in the background with bounded concurrency.
---@param callback fun(success: boolean) Called when build completes
function M.build_async(callback)
  if state.building then
    callback(false)
    return
  end

  -- === Initialize Build ===
  state.building = true
  state.paths = {} -- Clear existing paths
  state.norm = {}
  -- The file this build is for. A setup() or add_root() with other roots while
  -- it runs moves `config.cache_file` on; see `_finalize_build`.
  local built_for = config.cache_file

  safe.safe_notify_defer(
    string.format("[gopath] Building cache from %d roots...", #config.scan_roots),
    vim.log.levels.INFO,
    nil,
    50
  )

  -- Keep only roots that actually exist on disk.
  local roots = {}
  for _, root in ipairs(config.scan_roots) do
    if vim.fn.isdirectory(root) == 1 then roots[#roots + 1] = root end
  end

  -- === Single bounded-concurrency scan across all roots ===
  scan_roots_bounded(roots, function(paths, capped)
    state.paths = paths
    state.capped = capped
    reindex()
    M._finalize_build(callback, built_for)
  end)
end

---Whether a build is running. For `gopath.init`'s deferred start build, which
---would otherwise report a refused second build as a failure.
---@return boolean
function M.building()
  return state.building == true
end

---Finalize cache build (save to disk, update state)
---
---Reached from `scan_roots_bounded`'s completion callback, which runs inside a
---libuv `fs_scandir` callback — a fast event context where most Vimscript
---functions are forbidden (`vim.fn.mkdir` raises E5560). Everything below
---therefore runs on the main loop via `vim.schedule`.
---
---**A build for roots that are no longer the configured ones is discarded.**
---It scanned the roots it started with, and saving that under the new roots'
---file (with the new `scan_roots` and a fresh mtime) would make the next
---session trust an index that misses the new root. The index is dropped and
---a build for the current roots starts instead.
---@param callback fun(success: boolean)
---@param built_for? string `config.cache_file` when the build started
---@private
function M._finalize_build(callback, built_for)
  vim.schedule(function()
    if built_for and built_for ~= config.cache_file then
      state.building = false
      state.paths, state.norm, state.last_built, state.capped = {}, {}, nil, false
      -- The caller's callback goes with the replacement build: it asked for "a
      -- build", and that build's result is the honest answer -- not a "failed"
      -- (`:Gopath cache build` and the deferred start build would log one).
      M.build_async(callback)
      return
    end
    state.last_built = os.time()
    state.building = false
    state.unusable = false

    -- Said once per session, not per build: the periodic refresh would repeat it
    -- every few minutes for as long as the roots stay too big.
    if state.capped and not cap_warned then
      cap_warned = true
      LOG.warn(
        string.format(
          "the path cache stopped at %d files (truncated.max_paths) -- deeper levels are left "
            .. "to the live search; narrow truncated.cache_roots to index the project itself",
          config.max_paths
        )
      )
    end

    -- The verdict is settled only by an index that holds something or a file
    -- that was written: a build of nothing (every root gone) that also cannot
    -- write would otherwise leave the unusable file in place, and every later
    -- lookup would read it, reject it and ask for the same useless build again.
    if M._save_to_disk() or #state.paths > 0 then state.rebuild_asked = false end

    -- Build completion is reported by the caller (setup / :GopathCacheBuild);
    -- keep this as a dev-only trace to avoid duplicate notifications.
    LOG.debug(string.format("Cache built: %d files indexed", #state.paths))

    callback(true)
  end)
end

---How long an idle roots set's cache file may sit untouched before it is
---deleted. Every distinct scan-roots set owns its own file (PERF-46), so every
---new working directory, agent worktree or scratch folder used to leave one
---behind for good: 131 files and 564 MB had piled up. A root set that is used
---again just rescans once.
local PRUNE_AFTER_SECONDS = 14 * 24 * 3600

---Delete the per-roots cache files next to the live one that nothing has
---rewritten for `PRUNE_AFTER_SECONDS`. Does nothing unless the live file really
---is on disk, so a faked or failed write never reaches into the directory.
---
---Asynchronous (`uv.fs_scandir` with a callback) and free of Vimscript, since
---the callback runs in a libuv fast context. Only names of the exact shape this
---module writes (`gopath_fs_cache.json`, `gopath_fs_cache_<hex>.json`) are
---candidates, so `.tmp` leftovers and foreign files are never touched.
---@internal
---@return nil
local function prune_stale_cache_files()
  local live = config.cache_file
  local dir, keep = live:match("^(.*)[/\\]([^/\\]+)$")
  if not dir or not uv.fs_stat(live) then return end

  uv.fs_scandir(dir, function(err, handle)
    if err or not handle then return end
    local now = os.time()
    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then break end
      if name ~= keep and name:match("^gopath_fs_cache_?%x*%.json$") then
        local full = dir .. "/" .. name
        local st = uv.fs_stat(full)
        if st and st.type == "file" and now - st.mtime.sec > PRUNE_AFTER_SECONDS then
          uv.fs_unlink(full)
        end
      end
    end
  end)
end

---Save cache to disk for persistence across sessions
---@private
---@return boolean written
function M._save_to_disk()
  -- An index that is the one already on disk is not written again (a rebuild of an unchanged tree used to cost a
  -- full JSON encode and write, ~76 ms, in the editor thread): only the age moves, as the mtime of the file
  -- (`needs_refresh` and `load_from_disk` read it).
  local digest = vim.fn.sha256(
    table.concat(state.paths, "\n") .. "\0" .. table.concat(config.scan_roots or {}, "\n")
  )
  local file = config.cache_file
  if state.saved and state.saved.file == file and state.saved.digest == digest then
    local st = uv.fs_stat(file)
    local now = os.time()
    if st and st.type == "file" and uv.fs_utime(file, now, now) then return true end
  end
  local data = {
    paths = state.paths,
    last_built = state.last_built,
    scan_roots = config.scan_roots,
    version = 1,
  }

  local ok, err = require("lib.nvim.fs.json").write(config.cache_file, data)
  if ok then
    state.saved = { file = file, digest = digest }
    prune_stale_cache_files()
  else
    LOG.error("Failed to write cache file: " .. tostring(err))
  end
  return ok == true
end

---Load cache from disk
---Called by the first `search` of a session (and by the info/health views) to
---restore the previous session's cache; `setup()` does not call it.
---@return boolean success True if cache was loaded
function M.load_from_disk()
  if not require("lib.nvim.fs.is_readable_file")(config.cache_file) then
    return false -- Cache file doesn't exist (first run)
  end

  local data, err = require("lib.nvim.fs.json").read(config.cache_file)
  if not data then
    LOG.warn("Failed to parse cache file: " .. tostring(err))
    -- The file is there, so its mtime would read as a fresh cache in
    -- `needs_refresh`; it has to say "rebuild" instead.
    state.unusable = true
    return false
  end

  -- PERF-46: the cache key must include every parameter that changes the
  -- result. `config.cache_file`'s name already encodes a hash of scan_roots,
  -- but a hash collision or a hand-copied/corrupted file could still land
  -- here with a mismatching set -- reject it rather than populate `state`
  -- with another project's file list.
  local persisted_roots = {}
  if type(data.scan_roots) == "table" then
    for _, r in ipairs(data.scan_roots) do
      if type(r) == "string" then persisted_roots[#persisted_roots + 1] = r end
    end
  end
  if roots_fingerprint(persisted_roots) ~= roots_fingerprint(config.scan_roots) then
    state.unusable = true
    return false
  end

  -- This file is a persisted snapshot (our own, but possibly stale, from a
  -- crashed/interrupted write, or from an older/incompatible plugin version)
  -- — treat it as untrusted and revalidate every field rather than assigning
  -- it straight into live state. An unvalidated `data.paths` (wrong type, or
  -- containing non-string entries) would otherwise blow up later in
  -- `reindex`/`M.search`, which call `:gsub`/`:sub` on each entry assuming it
  -- is a string.
  local paths = {}
  if type(data.paths) == "table" then
    for _, p in ipairs(data.paths) do
      if type(p) == "string" then paths[#paths + 1] = p end
    end
  end
  state.paths = paths
  state.last_built = (type(data.last_built) == "number") and data.last_built or nil
  -- an unchanged index is not rewritten (`_save_to_disk`): the age of the file says when it was last confirmed
  local st = uv.fs_stat(config.cache_file)
  if st and st.mtime and (not state.last_built or st.mtime.sec > state.last_built) then
    state.last_built = st.mtime.sec
  end
  state.unusable, state.rebuild_asked = false, false
  reindex()

  return true
end

---Whether the cache is switched on in the configuration. `tailsearch` asks
---`search` whatever `truncated.enable` says, and a cache set up once and
---switched off by a later `setup()` keeps its roots: only the option tells.
---@return boolean
local function cache_enabled()
  local ok, C = pcall(require, "gopath.config")
  if not ok then return true end
  local t = C.get().truncated
  return not (type(t) == "table" and t.enable == false)
end

---Search in-memory cache for matching paths
---This is the fast path (< 10ms for 10,000 entries)
---
---Matching strategy:
---  1. Exact tail match (path ends with tail)
---  2. Sequential part match (all tail parts appear in order)
---
---@param tail string Tail of truncated path to search for
---@return string[] matches List of matching absolute paths
function M.search(tail)
  if #state.paths == 0 and not state.building then
    -- Try to load from disk (might be from previous session). A file already
    -- rejected is not read again on every lookup -- `tailsearch` asks up to
    -- six suffixes per resolve.
    if not state.unusable then M.load_from_disk() end
    -- Rejected, here or by whoever read it first (`:checkhealth`, `:Gopath
    -- cache info`): since `setup()` never read it, nothing else has noticed
    -- it is useless -- its fresh mtime told `needs_refresh` it was fine. One
    -- rebuild per verdict, and only for a cache that has roots to scan
    -- (`truncated.enable = false` never configured any).
    if
      state.unusable
      and not state.rebuild_asked
      and #config.scan_roots > 0
      and cache_enabled()
    then
      state.rebuild_asked = true
      vim.schedule(function()
        if not state.building then M.build_async(function() end) end
      end)
    end
  end

  if #state.paths == 0 then
    return {} -- Cache is empty
  end

  -- Self-heal if the mirror ever drifts out of sync with `paths`.
  if #state.norm ~= #state.paths then reindex() end

  -- Convert to lowercase and forward slashes for comparison
  local normalized_tail = tail:gsub("\\", "/"):lower()
  local tail_parts = vim.split(normalized_tail, "/", { trimempty = true })

  -- Strategy 1 is a plain suffix comparison, not a pattern match. It used to be
  -- `path:match(vim.pesc(tail) .. "$")` — but `vim.pesc` makes the tail a
  -- *literal*, so the anchored pattern was only ever asking "does this path end
  -- with this exact string". `sub(-n) == tail` answers that with a memcmp
  -- instead of starting the pattern engine 20k times per query. Identical
  -- semantics, measurably cheaper on the hot path.
  local tail_len = #normalized_tail
  -- Non-nil only for multi-segment tails; doubles as the Strategy-2 guard below.
  local last_part = (#tail_parts > 1) and tail_parts[#tail_parts] or nil

  local matches = {}
  local paths, norm = state.paths, state.norm

  for i = 1, #paths do
    local normalized_path = norm[i]

    -- Strategy 1: exact tail match (path ends with the exact tail)
    if #normalized_path >= tail_len and normalized_path:sub(-tail_len) == normalized_tail then
      matches[#matches + 1] = paths[i]

    -- Strategy 2: sequential part match -- all tail parts appear in path in order.
    -- Guarded by a plain-substring pre-check on the tail's LAST segment: the
    -- sequential match requires every tail part to appear as a whole path
    -- segment, so a path that doesn't even contain that segment as a substring
    -- can never match. The check allocates nothing, while the split below
    -- allocates a table per path — this prunes nearly all of them.
    elseif last_part and normalized_path:find(last_part, 1, true) then
      local path_parts = vim.split(normalized_path, "/", { trimempty = true })
      local tail_idx = 1

      for _, part in ipairs(path_parts) do
        if tail_idx <= #tail_parts and part == tail_parts[tail_idx] then tail_idx = tail_idx + 1 end
      end

      -- All tail parts found in sequence
      if tail_idx > #tail_parts then matches[#matches + 1] = paths[i] end
    end
  end

  return matches
end

---Check if cache needs refresh
---
---**Answers without the index loaded.** `setup()` no longer reads the cache
---file (about 30 ms of the `VeryLazy` wave, for an index the first `search()`
---loads anyway), so `state.last_built` is unknown until something loads or
---builds. Until then the age is the cache file's mtime: `_save_to_disk` writes
---it right after every build, so the two agree. No file means never built; a
---file that was read and rejected (`state.unusable`) means rebuild, whatever
---its mtime says.
---@param max_age_seconds integer|nil Maximum age before refresh (default: 3600)
---@return boolean needs_refresh True if cache is stale
function M.needs_refresh(max_age_seconds)
  max_age_seconds = max_age_seconds or 3600 -- Default: 1 hour

  local built = state.last_built
  if not built then
    if state.unusable then return true end
    local st = uv.fs_stat(config.cache_file)
    if not (st and st.type == "file" and st.mtime) then
      return true -- Never built
    end
    built = st.mtime.sec
  end

  local age = os.time() - built
  return age > max_age_seconds
end

---Background refresh timer, tracked at module scope so a second call to
---`M.start_periodic_refresh` (gopath.setup() runs again -- a config reload,
---`:Lazy reload`, or any repeated `require("gopath").setup()`) can stop the
---previous handle instead of orphaning it. Without this, `timer` used to be
---a plain local that vanished the moment the function returned, discarding
---the only reference able to stop it: every reload left the old timer
---running forever alongside the new one, compounding one more background
---rebuild-check (and, once the interval elapsed, one more full filesystem
---scan) per reload for the rest of the session.
---@type uv.uv_timer_t|nil
local refresh_timer = nil

---Start periodic cache refresh in background
---This ensures cache stays reasonably up-to-date during long Neovim sessions
---
---@param interval_seconds integer Refresh interval (default: 600 = 10 minutes)
function M.start_periodic_refresh(interval_seconds)
  interval_seconds = interval_seconds or 600

  if refresh_timer then
    pcall(refresh_timer.stop, refresh_timer)
    pcall(refresh_timer.close, refresh_timer)
    refresh_timer = nil
  end

  local timer = assert(uv.new_timer())
  refresh_timer = timer

  -- Start timer: check every interval, refresh if needed.
  -- The timer callback is a fast event context, but `build_async` calls
  -- Vimscript functions (`vim.fn.isdirectory`, notifications), so hop onto the
  -- main loop first.
  -- Initial delay = one full interval, NOT 0. With a 0 delay the timer fired
  -- immediately on setup() and — since `needs_refresh(interval)` is true for any
  -- cache older than the interval, which at startup it almost always is —
  -- kicked off a full rebuild right away, on top of the deferred build that
  -- `gopath.init._setup_cache` already schedules. That meant two scans (and two
  -- 2 MB cache writes) during startup.
  timer:start(interval_seconds * 1000, interval_seconds * 1000, function()
    if M.needs_refresh(interval_seconds) and not state.building then
      -- Rebuild cache in background
      vim.schedule(function()
        if state.building then return end
        M.build_async(function() end)
      end)
    end
  end)
end

---Add a directory to scan roots and rebuild cache
---Useful for adding project-specific directories on the fly
---
---@param dir string Directory path to add
---@param rebuild boolean|nil Whether to rebuild cache immediately (default: true)
function M.add_root(dir, rebuild)
  rebuild = rebuild ~= false -- Default: true

  -- Validate directory exists
  if vim.fn.isdirectory(dir) ~= 1 then
    LOG.error("Directory does not exist: " .. dir)
    return
  end

  -- Check if already in roots
  if vim.tbl_contains(config.scan_roots, dir) then
    LOG.warn("Directory already in cache roots: " .. dir)
    return
  end

  table.insert(config.scan_roots, dir)

  -- Re-key the persisted filename to the new roots set (PERF-46). Without
  -- this, `_save_to_disk` below would write the augmented `scan_roots` under
  -- the OLD (still hashed-from-the-old-roots) `config.cache_file`, and the
  -- very next `load_from_disk` -- next session or even this one, if a
  -- non-rebuild caller reads before rebuilding -- would reject that file:
  -- its persisted `scan_roots` no longer fingerprint-matches a freshly
  -- recomputed `config.scan_roots` (see `M.setup`'s revalidation), forcing a
  -- full rescan forever even though the cache is a valid superset.
  refresh_cache_file()
  -- As in `setup`: a verdict on the old file says nothing about the new one.
  state.unusable, state.rebuild_asked = false, false

  LOG.info("Added to cache roots: " .. dir)

  -- Rebuild cache to include new directory
  if rebuild then M.build_async(function() end) end
end

---Get cache state (for debugging)
---@return table state Current cache state
---@private
function M._get_state()
  return state
end

---Get cache config (for debugging/tests).
---@return CacheConfig config Current cache config
---@private
function M._get_config()
  return config
end

return M
