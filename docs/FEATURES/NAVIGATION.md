# Navigation

## Multi-provider resolution pipeline

Resolves the token under the cursor by trying providers in order — LSP,
Treesitter, then a builtin `<cfile>`-style resolver — configurable per
`opts.order`, with each language's own resolvers layered on top (see
[Language support](LANGUAGES.md)). Honors `&path`/`suffixesadd` the same
way `gf` does; `includeexpr` is deliberately not consulted, since gopath's
own per-filetype resolvers already cover what that would typically be
configured for.

- **Module:** `resolve.lua`, `providers/lsp.lua`, `providers/treesitter.lua`,
  `providers/builtin.lua`, `providers/token.lua`
- **Keymaps:** `gP` open here, `g\|` split, `` g\ `` vsplit, `g}` tab,
  `gY` copy `path:line:col`, `g?` debug (print resolution chain)
- **Usercmds:** `:Gopath open [edit|split|vsplit|tab]`, `:GopathOpen`,
  `:Gopath copy`, `:GopathCopy`, `:Gopath debug`, `:GopathDebug`,
  `:GopathResolve`
- **Config:** `opts.mode` (default `"hybrid"`), `opts.order` (default
  `{ "lsp", "treesitter", "builtin" }`), `opts.lsp_timeout_ms` (default
  `200`)

## Whole-line extraction

Scans the entire current line — not just the token under the cursor — for
path-like strings, using stacktrace patterns (`path:line:col`,
`path:line`), extension-driven expansion (150+ known extensions), and
absolute-path patterns (`/unix/path`, `C:\windows\path`, `\\unc\path`).
Works even when the cursor sits on an unrelated word in the same line as
the path, e.g. a log message.

- **Module:** `resolvers/common/linepath.lua`,
  `resolvers/common/extractor/{common_extensions,find,helpers,terminators}.lua`
- **Config:** `opts.linepath.enable` (default `true`),
  `opts.linepath.cascade` (default `true`)

## Suffix-based search

Resolves partial, truncated, and relative paths — the kind produced by log
output or stack traces — by matching path tails against multiple search
roots (buffer dir → cwd → git root → stdpath config/data/cache), backed by
the [filesystem cache](CACHE.md).

```
...nvim-data/lazy/gopath.nvim/lua/gopath/init.lua:42
gopath/resolvers/common/tailsearch.lua
health.lua
```

- **Module:** `resolvers/common/tailsearch.lua`, `truncated/finder.lua`
- **Config:** `opts.tailsearch.enable` (default `true`),
  `opts.tailsearch.max_components` (default `6`),
  `opts.tailsearch.ask_on_ambiguous` (default `true`),
  `opts.tailsearch.roots`, `opts.tailsearch.limit` (default `100`)

## Visual selection probe

Resolves a manually-selected span of text as a path, for cases where the
automatic token/line extraction picks the wrong span — including a span
that covers only PART of a longer recognizable reference (e.g. selecting
just `sub/file.lua` out of a longer `$REPOS_DIR/sub/file.lua`, or just
`github.com/x/y` out of a URL with surrounding text).

Tries two things in order:
1. Direct recognizers (`gopath.resolve_selection`): a `$VAR/rest` reference
   or a URL, resolved the same way the main pipeline would — tailsearch's
   filesystem suffix search has no way to recognize either of those on its
   own, so without this step a partial selection of one never resolved.
2. Falls back to tailsearch (suffix-based filesystem search, `vim.ui.select`
   when several files match) for everything else, e.g. a partial plain file
   path.

`:Gopath probe [edit|split|vsplit|explorer|filetree]` / `:GopathProbe
[mode]`: the same modes `gopath.open` supports for the cursor-based `gM`/`gT`
keymaps are available here too, so a whole OR partially selected path can be
**revealed in the OS file manager or in filetree.nvim** instead of opened as
a buffer — not just resolved.

- **Module:** `resolve_selection.lua`, `alternate/init.lua`,
  `resolvers/common/tailsearch.lua`, `resolvers/common/env_path.lua`
  (`resolve_text`), `util/url.lua`
- **Keymaps:** `<leader>pp` in normal mode (path under cursor) and visual
  mode (selected text) — both open in a vertical split
- **Usercmds:** `:Gopath probe [edit|split|vsplit]`, `:GopathProbe[!]`
  (`!` = split)

## Fuzzy alternate resolution

When the exact file doesn't exist, suggests similar files by Levenshtein
distance with a prefix bonus, so a truncated/abbreviated name sharing a
long common prefix with the target (`confi` vs `config.lua`) scores at
least as high as its prefix-length ratio. Each candidate in the picker
shows size and modification recency (`filename (85%) — 2.3 KB, modified
5m ago`); the picker itself defers to your configured `vim.ui.select`
backend via ui.nvim's `ui.kit.select`.

Candidates you have picked from this dialog before rise within their
similarity band, so the second time `config.lua` / `configs.lua` /
`config.local.lua` come up together, the one you meant last time is on top.
Which of three near-identical names you want is not a property of the string —
it is a property of your history, and after the first time it is known.

**A tiebreak, never an override.** The bonus saturates and is capped at
`max_bonus` similarity points (default 10, on the same 0–100 scale whose
threshold admits everything from 75 up): it reorders within a band and can
never push a 95% match below a 76% one. The store is
[`lib.nvim.frecency`](https://github.com/WKDSteve/lib.nvim/blob/main/lua/lib/nvim/frecency/README.md)
on its own namespace — the same implementation `pickers.nvim` ranks files
with, deliberately not the same store: a path opened often in a picker says
nothing about which alternate was meant here.

- **Module:** `alternate/init.lua`, `alternate/helpers/matcher.lua`,
  `alternate/helpers/directory.lua`, `alternate/ui.lua`,
  `alternate/frecency.lua`
- **Config:** `opts.alternate.enable` (default `true`),
  `opts.alternate.similarity_threshold` (default `75`),
  `opts.alternate.frecency = { enable = true, max_bonus = 10, dir = nil }`

## Create on missing

If no exact file and no fuzzy alternate is found, offers to create the
file (a button dialog via ui.nvim's `ui.kit.confirm`, falling back to
`vim.ui.select`) and jumps straight into it, creating parent directories as
needed. If the unresolved path has an existing ancestor directory and
[filetree.nvim](https://github.com/WKDSteve/filetree.nvim) is installed,
the dialog offers a second option to open that directory there instead of
creating a file. The `gC`/`:GopathCheck` keymap and command always offer
creation explicitly, even when `create_on_missing.enable = false` disables
it for the passive open keymaps.

When the resolved path is itself an existing **directory** (gopath can't
`:edit` a directory as a file), a different dialog appears instead: "Create
file in this folder" (asks for a name via `ui.kit.input`/`vim.ui.input`,
then creates `<dir>/<name>`) and, when filetree.nvim is installed, "Open in
filetree" for that same directory. This dialog always asks — it is not
gated on `create_on_missing.enable`/`confirm`, since a directory is not a
"missing" path.

- **Module:** `create.lua`
- **Keymaps:** `gC` check path under cursor
- **Usercmds:** `:Gopath check`, `:GopathCheck`
- **Config:** `opts.create_on_missing.enable` (default `true`),
  `opts.create_on_missing.confirm` (default `true`)
