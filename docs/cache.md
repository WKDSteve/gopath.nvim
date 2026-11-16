# Filesystem Cache & Truncated-Path Resolution

This document describes the **filesystem cache** that powers fast resolution of
*truncated* and *partial* paths — the kind you get from error messages, stack
traces and logs:

```
...a/Local/nvim/lua/config/neotree/open/filemanager/win.lua:62
…/lua/config/init.lua
neo-tree/ui/renderer.lua
```

The cache lets gopath answer "which real file on disk does this fragment refer
to?" **without freezing the editor**, by scanning the filesystem once in the
background and reconstructing the full absolute path from the visible tail.

- Code: [`lua/gopath/truncated/cache.lua`](../lua/gopath/truncated/cache.lua),
  [`lua/gopath/truncated/finder.lua`](../lua/gopath/truncated/finder.lua)
- Lookup glue: [`lua/gopath/resolvers/common/tailsearch.lua`](../lua/gopath/resolvers/common/tailsearch.lua)

---

## Contents

- [Why a cache?](#why-a-cache)
- [The big picture](#the-big-picture)
- [What gets scanned, and when](#what-gets-scanned-and-when)
- [How the scan works (non-blocking)](#how-the-scan-works-non-blocking)
- [Storage: in-memory + on-disk](#storage-in-memory--on-disk)
- [Matching: reconstructing the full path from a tail](#matching-reconstructing-the-full-path-from-a-tail)
- [Live fallback search](#live-fallback-search)
- [Refresh lifecycle](#refresh-lifecycle)
- [Configuration](#configuration)
- [Commands](#commands)
- [Tuning & troubleshooting](#tuning--troubleshooting)
- [Design notes](#design-notes)

---

## Why a cache?

Resolving a truncated path means searching the filesystem for a file whose path
*ends with* the visible fragment. Doing that search live, on the main thread
(e.g. with `vim.fs.find`), walks large directory trees synchronously and **locks
up the UI for several seconds** on a real machine (a populated `nvim-data`
directory on Windows is enough to cause a multi-second freeze).

The cache solves this by paying the traversal cost **once, in the background**,
and then answering every subsequent lookup from memory in well under 10 ms.

---

## The big picture

```
                         ┌──────────────────────────────┐
   setup() ───────────▶  │  build_async()  (background)  │
                         │  bounded libuv scandir walk   │
                         └───────────────┬──────────────┘
                                         │ file paths
                                         ▼
   on-disk JSON  ◀────────────  in-memory index  (state.paths)
   (stdpath cache)                       ▲
                                         │ M.search(tail)
   cursor on a truncated path ──▶ cache_lookup(tail)  ──▶ full absolute path
                                         │ (miss)
                                         ▼
                              async live finder walk
                              ("Dateisuche läuft…")
```

1. At startup the cache file is **not read**: its modification time says
   whether it is stale, and a stale or missing cache is **rebuilt in the
   background**. The index itself is read by the first lookup that needs it
   (about 23 ms on 20.5k paths in the table below, 40–60 ms on 26.4k paths
   measured 2026-10-22) — that cost moved out of the `VeryLazy` wave and onto
   the first `gF` of a session. A file that lookup rejects (unparseable, built
   for other roots) is not read again; it starts one background rebuild
   instead.
2. When the cursor lands on a truncated/partial path, the resolver first asks
   the **in-memory cache** (instant).
3. On a cache miss it falls back to an **asynchronous live search** that shows a
   progress message and opens the file once found.

---

## What gets scanned, and when

Scan roots are chosen in [`cache.setup()`](../lua/gopath/truncated/cache.lua).
If you do not set `truncated.cache_roots`, they are auto-detected (deliberately
conservative — we do **not** index a whole drive by default):

| Root | Source |
|------|--------|
| Working directory | `vim.fn.getcwd()` |
| Neovim config | `vim.fn.stdpath("config")` |
| Neovim data (plugins) | `vim.fn.stdpath("data")` |
| Neovim cache | `vim.fn.stdpath("cache")` |
| Git repository root | nearest ancestor holding a `.git` marker, via `lib.nvim.fs.find_root` (if inside a repo) |

A candidate that is the **home folder or a folder above it** (a drive, `C:\Users`) is left out: a session started in
the home folder used to index the whole profile up to the cap (300,000 paths, a 28 MB file rewritten in about a
second on every refresh). It then indexes only the editor's own folders. `truncated.index_home = true` takes such
a folder as a default root again; `truncated.cache_roots` indexes whatever it lists.

Single folders can be named on top of that: `truncated.extra_roots` are indexed in addition to the roots
(auto-detected or `cache_roots`), `truncated.excluded_paths` are never indexed — neither as a root nor anywhere below
one. Unlike `excluded_dirs`, which matches a folder *name* anywhere, both take full paths (`~` and `$VAR` are
expanded). The excluded folders are part of the cache file's key, so changing them never serves the old index.

Each root is walked up to `truncated.max_depth` levels deep (default **6**),
skipping `truncated.excluded_dirs` (`.git`, `.github`, `node_modules`, `target`,
`build`, `.cache`, `venv`). One build indexes at most `truncated.max_paths` files (default
**300000**). The walk is breadth-first, so when a root is huge — a session
started in `%TEMP%`, say — the shallow levels of
every root survive the cut, the deeper ones are left to the live search, and a
one-time warning names the cap. For scale: a normal session indexes ~35,000
paths, a working directory of the profile directory ~207,000, and an unbounded
walk of a `%TEMP%` full of agent worktrees reached 727,000 paths (a 122 MB file
whose load blocked startup for ~3 s).

A build is triggered:

- **Once on setup**, deferred ~2 s, only when the cache is missing or stale
  (see [Refresh lifecycle](#refresh-lifecycle)).
- **Periodically**, every `cache_refresh_interval` seconds, when stale.
- **On save** (optional), if `auto_rebuild_on_save = true`, debounced.
- **Manually**, via `:Gopath cache build`.

> The build is wired up in [`lua/gopath/init.lua`](../lua/gopath/init.lua)
> via `cache.setup{…}`. Without that call the scan roots are empty and the cache
> indexes nothing — so the cache is only active when `truncated.enable = true`
> (the default).

---

## How the scan works (non-blocking)

The traversal is a **bounded-concurrency work queue** over libuv's async
`fs_scandir` (`scan_roots_bounded` in `cache.lua`):

- A queue holds `{ dir, depth }` items; at most `max_concurrency` (default
  **16**) `fs_scandir` operations are in flight at once.
- Subdirectories are pushed back onto the queue instead of recursing
  immediately, so the number of open directory handles stays bounded regardless
  of tree size. This avoids `EMFILE` / threadpool starvation on huge trees.
- The whole walk runs off the main loop — Neovim stays responsive while it
  builds.

The live fallback finder uses the **same** bounded libuv walk
(`finder.find_async`), with early-exit once enough matches are found, so it
needs no external tools (`fd`/`rg` are used only by the synchronous
`finder.find`).

---

## Storage: in-memory + on-disk

- **In-memory:** `state.paths` — a flat array of every discovered absolute file
  path. This is what lookups search.
- **On-disk:** a versioned JSON file at
  `stdpath("cache") .. "/gopath_fs_cache_<hash>.json"` containing `paths`,
  `last_built`, `scan_roots` and a `version`. `<hash>` is derived from the
  configured scan roots, so two projects with a different root set never
  share a file on disk, and loading one back also revalidates its
  `scan_roots` field against the current configuration — a cache built for a
  different project is never adopted, even on a hash collision or a
  hand-copied file. It is written after a build that found another index
  than the one on disk, and read by the first lookup of a session, not by
  `setup()`. A build that finds the same index (same paths in the same order;
  the scan lists them directory by directory, the directories sorted, so the
  same tree always gives the same list) only touches the file: its mtime is
  the build time. Until it has been read, `needs_refresh` takes that mtime as
  the build time; no file means never built, and a file that was read and
  rejected (unparseable, other roots) means rebuild.
- **Pruning:** every distinct root set owns a file, so every new working
  directory would leave one behind. After each successful write, the
  `gopath_fs_cache*.json` files next to the live one that nobody has rewritten
  for **14 days** are deleted (asynchronously; files of any other name are never
  touched, and nothing is deleted unless the live file really landed on disk).
  A root set that is used again after that simply rescans once.

---

## Matching: reconstructing the full path from a tail

This is the heart of the system, and it directly implements the idea of *"find
where enough of the path overlaps and rebuild the missing left part."*

A truncated token is first reduced to a clean **tail** (ellipsis/quotes/`:line`
stripped, separators normalized to `/`). The lookup then tries progressively
shorter **suffix candidates**, longest first
(`tailsearch.cache_lookup` → `suffix_candidates`):

```
tail = "...a/Local/nvim/lua/config/neotree/open/filemanager/win.lua"

candidates (longest → shortest, up to max_components):
  lua/config/neotree/open/filemanager/win.lua
  config/neotree/open/filemanager/win.lua
  neotree/open/filemanager/win.lua
  open/filemanager/win.lua
  filemanager/win.lua
  win.lua
```

For each candidate, `cache.search` matches every indexed path with two
strategies (case-insensitive, `\`→`/` normalized — the normalized form is
precomputed once per index in `state.norm`, not derived per lookup):

1. **Exact tail (suffix) match** — the indexed path *ends with* the candidate
   (a plain `sub`/compare, not a pattern match: the candidate is a literal, so
   the pattern engine bought nothing and cost ~3× on the hot path).
   This is what reconstructs the absolute left part: the full hit
   `C:/Users/me/AppData/Local/nvim/lua/config/.../win.lua` ends with
   `lua/config/.../win.lua`, so the missing `C:/Users/me/AppData/Local/nvim`
   prefix is recovered.
2. **Sequential part match** — every segment of the candidate appears **in
   order** inside the indexed path (not necessarily contiguous). This is the
   "≥ N matching folders in sequence" heuristic: it tolerates a partial leading
   segment (e.g. the `...a` fragment left of `AppData`).

The **longest** candidate that produces any hit wins, so the result is as
specific as possible and we never fall through to a bare `win.lua` that matches
half the disk. If several files match the winning candidate, the **shortest**
absolute path is preferred (`pick_best`), and commands may present a
`vim.ui.select` picker (`ask_on_ambiguous`).

For interactive selection, candidates are additionally ranked by filename
similarity (Levenshtein, `truncated.similarity_threshold`) — see
[`alternate/helpers/matcher.lua`](../lua/gopath/alternate/helpers/matcher.lua).

---

## Live fallback search

When the cache misses (cold start, file outside the scanned roots, or deeper
than `max_depth`), resolution does **not** block. The command layer:

1. shows `"[gopath] Dateisuche läuft…"`,
2. runs `finder.find_async` (async libuv walk, off the main loop),
3. opens the buffer once a match is found, or reports no match.

See [resolution.md](./resolution.md) for how this fits into the full pipeline.

---

## Refresh lifecycle

| State | Check | Action |
|-------|-------|--------|
| Never built | `last_built == nil` | build on setup (deferred ~2 s) |
| Stale | `os.time() - last_built > max_cache_age` | background rebuild |
| Periodic | every `cache_refresh_interval` s | rebuild if stale |
| On save | `auto_rebuild_on_save` | debounced rebuild |

`needs_refresh(max_age)` and `start_periodic_refresh(interval)` implement this.
Concurrent builds are prevented by a `state.building` guard.

The periodic timer's **first** tick is one full interval out, not immediate. A
zero initial delay made it fire during `setup()`, where `needs_refresh(interval)`
is true for any cache older than the interval — i.e. almost always at startup —
so it kicked off a full rebuild on top of the deferred one above: two scans and
two cache writes while Neovim was still starting.

> **Where the time actually goes.** Measured on a 20.5k-path / 2.1 MB index:
>
> | Step | Cost |
> |------|------|
> | raw file read | ~2 ms |
> | `vim.json.decode` | ~6 ms |
> | full `load_from_disk` (read + decode + normalize) | ~23 ms |
> | `vim.json.encode` (save) | ~5 ms |
> | one `cache.search` query | ~5 ms |
>
> Two things worth knowing before optimizing here. **JSON is not the
> bottleneck** — `vim.json` is C, and a hand-rolled newline-delimited format
> measured *slower* (~8 ms) than `decode` because the split happens in Lua. And
> **the persisted-file I/O is ~25 ms total**, so it cannot explain a
> multi-second startup stall.
>
> If you are chasing such a stall, the candidate is the scan's *callback*
> volume: the walk uses non-blocking `fs_scandir`, but its callbacks still run
> on the main loop, and tens of thousands of entries' worth of them add up
> even though no single call blocks. That is the one thing an out-of-process
> indexer would genuinely fix. Measure with `nvim --startuptime` before
> assuming.

---

## Configuration

```lua
require("gopath").setup({
  truncated = {
    enable                 = true,   -- master switch for cache + truncated resolution
    use_cache              = true,   -- consult the in-memory cache before live search
    cache_refresh_interval = 600,    -- seconds between periodic refresh checks
    max_cache_age          = 3600,   -- seconds before the cache is considered stale
    live_search_fallback   = true,   -- fall back to a live search on cache miss
    similarity_threshold   = 75,     -- 0–100; filename similarity for disambiguation
    cache_roots            = nil,    -- nil = auto-detect (cwd, stdpaths, git root)
    index_home             = false,  -- auto-detect may take the home folder (or one above it) as a root
    extra_roots            = nil,    -- folders indexed on top of the roots, e.g. { "~/notes" }
    excluded_paths         = nil,    -- folders never indexed (full paths), e.g. { "~/Downloads" }
    max_depth              = 6,      -- max directory depth per root
    max_paths              = 300000, -- most files one build indexes (shallow levels first)
    excluded_dirs          = { ".git", ".github", "node_modules", "target", "build", ".cache", "venv" },
    auto_rebuild_on_save   = false,  -- rebuild (debounced) on BufWritePost
  },
})
```

Related knobs live under `tailsearch` (suffix length, ambiguity prompt, result
limit) — see the [configuration.md](configuration.md).

---

## Commands

| Command | Alias | Effect |
|---------|-------|--------|
| `:Gopath cache build` | `:GopathCacheBuild` | Rebuild the cache now (background) |
| `:Gopath cache info` | `:GopathCacheInfo` | Show indexed file count, last-built time, staleness |
| `:Gopath cache add-root <dir>` | `:GopathCacheAddRoot <dir>` | Add a scan root and rebuild |

`g?` (`:GopathDebug`) also prints cache stats for the path under the cursor.

---

## Tuning & troubleshooting

- **Truncated path won't resolve.** Run `:Gopath cache info`. If the file count
  is 0, the cache hasn't built yet (wait a moment after startup, or run
  `:Gopath cache build`). If the file lives outside the default roots, add it
  with `:Gopath cache add-root <dir>` or set `truncated.cache_roots`.
- **Resolution finds the wrong file.** Increase `tailsearch.max_components` so a
  longer, more specific suffix is tried first, and/or raise
  `similarity_threshold`.
- **Build feels heavy.** Lower `max_depth`, extend `excluded_dirs`, or pin
  `cache_roots` to just the directories you care about.
- **"The path cache stopped at … files".** A scan root is huge (usually the
  working directory, e.g. `%TEMP%`). Pin `cache_roots` to the
  project instead, or raise `max_paths` if you really want the whole tree
  indexed — at the price of a bigger JSON file and a slower first lookup.
- **Want a wider net.** Set `cache_roots` explicitly (e.g. a whole project
  drive) — but note a bigger index means slower builds and a larger JSON file.

---

## Performance characteristics

Approximate, order-of-magnitude figures (hardware- and tree-dependent):

| Operation | Cost |
|-----------|------|
| Cache build, ~1 000 files | ~0.5 s (background) |
| Cache build, ~10 000 files | ~3 s (background) |
| Cache build, ~50 000 files | ~15 s (background) |
| **Cache lookup** | **< 10 ms** |
| Live search (async libuv walk) | ~100 ms – a few seconds, off the main loop |
| On-disk cache size | ~1 MB per 10 000 files |
| Saving after a build, ~22 000 files (2 MB) | ~50–90 ms; ~0 ms when the index did not change |
| Saving after a build, 300 000 files (28 MB, the `max_paths` cap) | ~0.8–1 s |

The point of the design: builds are slow but **never block** the UI, while the
lookups you actually do interactively are effectively instant.

---

## Design notes

- The cache is intentionally a **flat path list** with string matching rather
  than a trie/DB: it is trivial to serialize, fast enough for tens of thousands
  of entries, and easy to reason about.
- The two-strategy matcher already realizes the "enough overlap → rebuild the
  left part" idea, and the suffix + sequential strategies are the current
  approximation of an explicit overlap score. A configurable minimum
  (`truncated.min_overlap`) would make it a number rather than an
  approximation. **Not built** — there is no such option today.
