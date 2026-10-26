# Resolution Pipeline

This document explains how gopath turns *the thing under your cursor* into *an
opened file at the right line* — the ordered chain of resolvers, the
asynchronous open flow, and the fallbacks. It complements
[cache.md](./cache.md), which covers the truncated-path cache that the pipeline
relies on.

- Orchestrator: [`lua/gopath/resolve.lua`](../lua/gopath/resolve.lua)
- Command/open flow: [`lua/gopath/commands.lua`](../lua/gopath/commands.lua),
  [`lua/gopath/open/init.lua`](../lua/gopath/open/init.lua)
- Token extraction: [`lua/gopath/providers/token.lua`](../lua/gopath/providers/token.lua)
- Separator handling: [`lua/gopath/util/cross.lua`](../lua/gopath/util/cross.lua)

---

## Contents

- [The result type](#the-result-type)
- [Phase order](#phase-order)
- [Token extraction & path normalization](#token-extraction--path-normalization)
- [Synchronous fast path vs. async search](#synchronous-fast-path-vs-async-search)
- [Path lookup caching](#path-lookup-caching)
- [Opening: window placement, jump, externals](#opening-window-placement-jump-externals)
- [Not-found fallbacks](#not-found-fallbacks)
- [Configuration & entry points](#configuration--entry-points)

---

## The result type

Every resolver returns a `GopathResult` (or `nil`):

| Field | Meaning |
|-------|---------|
| `path` | Absolute path, **forward-slash canonical** internally |
| `range` | `{ line, col }` to jump to, or `nil` |
| `kind` | `"file"` / `"module"` / `"help"` |
| `source` | Which resolver produced it (debugging) |
| `confidence` | `0–1`; higher wins earlier |
| `exists` | Whether the path was confirmed on disk |

`confidence` and `exists` drive the orchestration: a confident, existing hit is
returned immediately; a low-confidence or non-existent result is held as a
fallback so later phases can improve on it.

---

## Phase order

`resolve_at_cursor` ([`resolve.lua`](../lua/gopath/resolve.lua)) tries resolvers
in order and returns the first success:

| Phase | Resolver | Trigger |
|-------|----------|---------|
| 1 | `:help` subject | token looks like a Vim help tag |
| 2 | `$VAR` env path | token starts with `$` or `${` |
| 2.5 | **task id** | `<area>/<slug>` under the cursor, resolved by [tasks.nvim](https://github.com/WKDSteve/tasks.nvim) (`tasks_nvim.resolve`) — only when tasks.nvim is installed and a vault has that area and task; an open task and a finished one, or the id in two `tasks.vaults`, are offered to pick from |
| 3 | **filetoken** | `<cfile>` under cursor; searches `&path` (honouring `suffixesadd`), rtp, then the **cache** |
| 3.5 | **linepath** | scans the whole current line (stacktraces, extension-driven, absolute); resolves absolute → cwd-relative → **buffer-relative** → cache tail |
| 4 | Language pipeline | LSP → Treesitter → builtin (per filetype, e.g. Lua `require`). The LSP step returns immediately when no client is attached — see below |
| 5 | filetoken fallback | the low-confidence/non-existent result held from phase 3 |
| 6 | raw `<cfile>` | last resort |

Phase 3 returns immediately **only** when it finds a confirmed file
(`exists and confidence ≥ 0.6`); otherwise it stashes the speculative result and
lets phases 3.5–4 try first.

> **Important:** phases 3 and 3.5 consult the truncated-path cache via
> `tailsearch.resolve_cached` — a **cache-only, non-blocking** lookup. They never
> run a live filesystem walk inside this synchronous pipeline. That keeps the
> pipeline instant; the (potentially slow) live search is deferred to the
> command layer (next section).

---

## Token extraction & path normalization

The token under the cursor comes from
[`providers/token.lua`](../lua/gopath/providers/token.lua), which is smarter than
plain `<cfile>`: it walks outward over path-like characters and preserves a
trailing `:line:col` / `(line)` location suffix.

Cleanup that matters cross-platform:

- A **leading `(`** pulled in from a markdown link `](path)` is stripped (it is
  part of the accepted character set so `path(10)` works, so a leading one must
  be removed explicitly).
- A leading **chain dot** (`.foo` → `foo`) is removed, but `./`, `.\` (relative)
  and `...` (truncated) prefixes are **preserved**.
- Separators are normalized to **forward slashes** for all internal matching via
  [`util/cross.lua`](../lua/gopath/util/cross.lua), and the final openable path
  is converted back to **OS-native** separators (backslashes on Windows) right
  before `:edit`. Both directions are backed by **lib.nvim**
  (`lib.nvim.cross.separators`), with built-in fallbacks if lib.nvim is absent.

This is why a markdown link like `[x](.\spickzettel/Learn.md)` — mixed
separators, a leading paren, a `.\` prefix — resolves correctly.

Two things make a link work even with the cursor on its **label** rather than on
the path, where `<cfile>` yields a plain word and phase 3 bails out:

- The line extractor scans for **externally-openable extensions too** (`.pdf`,
  `.png`, `.docx`, … from `gopath.external`, plus your own
  `external.extensions`), not just source/text extensions. Without this a
  `[report](docs/report.pdf)` link produced no candidate at all.
- An **unbalanced trailing bracket** is dropped: expanding left from
  `docs/report.pdf` in `[report](docs/report.pdf)` stops at `(`, leaving a `)`
  on the right with no opener. A bracket whose opener *is* present is kept, so
  `C:/Program Files (x86)/x.pdf` survives intact.

Because a link inside a document is **document-relative**, linepath also tries
the path relative to the **buffer's own directory** (after cwd, so no existing
resolution changes). Previously such a link only resolved when the cwd happened
to match, or when the fuzzy tail search found it.

---

## Synchronous fast path vs. async search

`commands.goto_at_cursor(kind)` ([`commands.lua`](../lua/gopath/commands.lua))
orchestrates the user-facing open:

```
resolve_at_cursor()            -- fast: help/env/rtp/&path/cache only
   │
   ├─ exists ≠ false ─────────▶ open immediately            (fast path)
   │
   └─ no confirmed file
          │ derive a search tail (from the speculative path or <cfile>)
          ▼
      vim.notify("Dateisuche läuft…")
      tailsearch.resolve_async(tail, …)   -- async libuv walk, off main loop
          │
          ├─ found ──────────▶ open
          └─ miss ───────────▶ not-found fallbacks
```

- The **fast path** covers the overwhelming majority of jumps (existing files,
  rtp/`&path` hits, warm cache) and opens with **zero latency and no message**.
- Only when nothing is confirmed does the **asynchronous live search** kick in.
  It shows a single progress message *only when the slow walk actually starts*
  (an `on_live_start` hook — a warm cache hit skips it), then opens the buffer
  when a match arrives. The UI never freezes.

`tailsearch.resolve_async` itself is cache-first (instant) and only walks the
filesystem on a miss — see [cache.md](./cache.md#live-fallback-search).

The visual-selection / cursor **probe** (`:GopathProbe`, `<leader>pp`) first
tries `gopath.resolve_selection` — a `$VAR/rest` reference or a URL, resolved
directly against the selected text (this is what makes a PARTIAL selection of
one of those resolve, not just a partial selection of a plain file path).
Only when that finds nothing does it fall through to the same async
tailsearch machinery as above, with a `vim.ui.select` picker on ambiguity.

---

## Path lookup caching

`gF` is a keypress, so [`util/path.lua`](../lua/gopath/util/path.lua) is built to
stay off the filesystem. The naive search — stat every candidate under every
runtimepath entry — costs ~200 `fs_stat` calls per lookup, which on Windows
(especially with AV/EDR scanning) measured **~9.7 ms per miss** against a
50-entry runtimepath.

Misses are the common case: any dotted token under the cursor is fed into the
chain, so most invocations resolve nothing and would pay that walk in full.

Instead each search root is read **once** with a single `fs_scandir`, indexed by
the names directly inside it. A candidate is only stat'ed in a root whose index
actually contains its first path segment, so an unknown token is rejected by
hash lookup alone:

| Lookup | Uncached | Indexed |
| --- | --- | --- |
| module miss (2 candidates) | 9.7 ms | 0.09 ms |
| file-token miss | 5.3 ms | 0.05 ms |
| full `search_module` chain, miss | 11.3 ms | 0.31 ms |

Search **order is unchanged** — the index only skips probes that could not have
matched, so results are identical to the uncached walk.

Because only the *first* segment is indexed, adding a file inside an
already-known directory needs no invalidation at all. Only a brand-new
top-level entry can be hidden by a stale index, and four signals cover that:

- installing/loading a plugin moves the runtimepath, which the caches key on
- gopath's create-on-missing calls `path.invalidate_caches()` directly
- a `BufWritePost` autocmd does the same for buffers written in this session
  (see [BINDINGS.md](./BINDINGS.md#autocommands))
- a 30 s TTL backstops changes made entirely outside Neovim

---

## Opening: window placement, jump, externals

[`open/init.lua`](../lua/gopath/open/init.lua) handles the actual open:

1. **External files** (images, PDFs, …) are handed to the system opener via
   `gopath.external`. A missing external file is reported as `File not found`
   *before* the opener runs — handing the OS a non-existent path only produces a
   cryptic `Start-Process`/shell error, and there is no create-offer here either
   (an empty `.pdf` is not a useful thing to conjure up).
   **PDFs** additionally route through
   [`gopath.external.pdf`](../lua/gopath/external/pdf.lua): with
   [pdfport.nvim](https://github.com/WKDSteve/pdfport.nvim) installed you get
   a chooser — *System app* (first; it's the exception, so it stays one
   keystroke away), *Buffer*, *Float*, *Terminal*. "System app" goes through
   gopath's own opener, so it behaves identically with or without pdfport.
   Without pdfport, nothing changes: straight to the system viewer, no dialog.
   Configure via `external.pdf = { picker = true, default = "system" }`.
2. A non-existent path is offered for creation via
   [`gopath.create`](../lua/gopath/create.lua) (`create_on_missing`, see
   below) instead of just reporting `File not found`. On confirmation the
   file (+ parent dirs) is created and `M.open` re-enters with `exists = true`.
3. Window placement runs first — `edit` / `split` / `vsplit` / `tabnew` —
   then the file is opened with an **OS-native** path (lib.nvim).
4. If the result carries a `range`, the cursor jumps to `line:col` and centers
   (`normal! zz`).

---

## Not-found fallbacks

When resolution yields a path that does not exist, `commands` tries, in order:

1. **Fuzzy alternate** — Levenshtein similarity against files in the same
   directory ([`alternate/`](../lua/gopath/alternate)), gated by
   `alternate.similarity_threshold`, then reordered by what you have chosen
   from this dialog before (capped, so it breaks near-ties without inverting a
   clear winner — see [NAVIGATION.md](FEATURES/NAVIGATION.md#fuzzy-alternate-resolution)).
   The picker reports back through a
   **callback**, so an asynchronous backend (telescope-ui-select, dressing,
   kit's chooser) can't make the caller fall through while the list is still on
   screen — that used to open the missing file *and* stack a create dialog on
   top of the open picker. Dismissing the picker (its list closes with nothing
   chosen) means "none of these", not "give up entirely": the chain still
   falls through to **Create on missing** below, offering to create the path
   you originally typed — the picker is already fully closed by then, so
   there is no dialog left to stack a second one onto. The chosen candidate,
   when there is one, is opened through `gopath.open`, so it honours the
   window mode you actually pressed (`gP`/`g|`/`g\`/`g}`) and the
   `:line:col` jump — both were previously lost: the mode was passed under a
   key the callee never read, and even when read it was concatenated into an
   Ex command line, where a gopath mode like `window` or `tab` is not a valid
   command (`E492`).
2. **Create on missing** — if that fails too, `gopath.open` asks (button
   dialog via ui.nvim's `ui.kit.confirm`, falling back to `vim.ui.select`
   when ui.nvim is absent) whether to create the file. See
   [`gopath.create`](../lua/gopath/create.lua) and the `create_on_missing`
   config block. Opt-out with `create_on_missing.enable = false`, or skip the
   prompt with `confirm = false`. The dedicated `gC` / `:GopathCheck`
   keymap/command checks existence directly (no open attempt first) and
   always offers to create, bypassing the `enable` opt-out.

There used to be a third fallback that opened the nearest existing ancestor
*directory* of the unresolved path as a buffer — removed, because a directory
can't be opened in a Neovim buffer the way a file can (it just handed you to
netrw with no warning). When the resolved path has an existing ancestor
directory and [filetree.nvim](https://github.com/WKDSteve/filetree.nvim)
is installed and set up, the create-on-missing dialog offers a second
button, **"Open in filetree"**, instead: it sets Neovim's cwd to that
directory and roots/focuses filetree.nvim's tree there. The button is only
shown when both conditions hold; otherwise the dialog is just
Create/Cancel.

When the resolved path itself already exists **as a directory** (not an
ancestor of a missing path — the path gopath resolved to actually is one),
`gopath.create` asks a different question up front, independent of
`create_on_missing.enable`/`confirm`: "Create file in this folder" (prompts
for a filename, then creates it there) or, when filetree.nvim is set up,
"Open in filetree" for that directory.

---

## Configuration & entry points

- Public API: `require("gopath").resolve_text(text)` resolves a piece of text (a
  `$VAR/...` reference, `$NVIM_CONFIG_DIR` included, or a URL) the same way, for
  callers that already hold the text -- lsp.nvim uses it for Markdown link
  targets. `require("gopath").shorten_path(abs)` is the reverse for one absolute
  path: `$NVIM_CONFIG_DIR/...` / `$REPOS_DIR/...` (the same logic as `:Gopath
  to-nvim-dir` / `to-repos-dir`, driven by `shorten_known_dirs` / `shorten_dirs`),
  or `nil` when no configured root contains it -- images.nvim's `:Image paste env`
  uses it. `require("gopath").resolve(opts)` returns a `GopathResult` without
  opening anything; `require("gopath").commands` exposes the open/copy/debug
  actions for custom keymaps.
- Mode selection (`mode = "hybrid" | "lsp" | "treesitter" | "builtin"`) and the
  resolver `order` are documented in the [configuration.md](configuration.md).
- Per-phase switches: `linepath.enable`, `tailsearch.enable`,
  `env_variable_resolution.enable`, `alternate.enable`, and the `languages`
  table.

See [cache.md](./cache.md) for the cache that backs phases 3/3.5 and the async
fallback.

## The LSP step does not wait for a server that is not there

`vim.lsp.buf_request_sync` does **not** return early when nothing is attached
to the buffer. Measured on 2026-09-03, zero clients, the 200 ms default: it
blocked for the whole timeout and then answered `nil, "timeout"` — 219 ms.

That cost landed on every resolve which reached stage 4 in a buffer with no
server: a `.txt`, a `gitcommit`, a scratch buffer, any filetype without one,
and every machine that runs no language server at all. Measured through
`resolve_at_cursor` with the cursor on prose:

| Token under the cursor | Before | After |
| --- | --- | --- |
| a bare word | 216 ms | **129 µs** |
| a long word with no separator | 216 ms | 91 µs |
| a dotted name | 216 ms | 520 µs |
| `read/write/execute` | 231 ms | 11.5 ms |
| an existing relative path | 1.6 ms | 1.6 ms |

The last row never reached stage 4 — `filetoken` answers it — which is why it
does not move. The fourth is the **tail search**, not the LSP wait: a token
with separators that could be a relative path is searched for across the tree,
and that is a different cost with a different answer (see
[cache.md](cache.md)).

So `providers/lsp.lua` asks whether any client is attached before sending. It
deliberately does **not** ask whether an attached client supports
`textDocument/definition`: the capability call changed shape across 0.9, 0.10
and 0.11, and getting that wrong would silently reintroduce exactly the wait
it removes. "Nobody is attached" is version-proof and is the case that was
measured.
