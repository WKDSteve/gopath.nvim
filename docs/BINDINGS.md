# gopath.nvim — Binding Cheatsheet

Every keymap, user command, and autocommand `gopath.nvim` defines. Kept in
sync with `lua/gopath/bindings/`.

All keymaps and commands are individually configurable (or fully disabled)
via `require("gopath").setup({ mappings = ..., commands = ... })`. See
[configuration.md](configuration.md) for the exact option shapes.

## Table of content

  - [Keymaps](#keymaps)
  - [User Commands](#user-commands)
    - [`:Gopath` subcommand tree](#gopath-subcommand-tree)
    - [Individual aliases](#individual-aliases)
  - [Autocommands](#autocommands)

---

## Keymaps

| lhs | mode | config key | action |
| --- | --- | --- | --- |
| `gP` | n | `open_here` | Resolve and open in current window |
| `g\|` | n | `open_split` | Resolve and open in horizontal split |
| `g\` | n | `open_vsplit` | Resolve and open in vertical split |
| `g}` | n | `open_tab` | Resolve and open in new tab |
| `gM` | n | `open_explorer` | Reveal target in the system file manager (Explorer/Finder/…) instead of opening it |
| `gT` | n | `open_filetree` | Reveal target in filetree.nvim's own tree instead of opening it (soft dependency) |
| `gY` | n | `copy_location` | Copy `path:line:col` to clipboard |
| `g?` | n | `debug` | Print resolution chain to `:messages` |
| `gC` | n | `check` | Check path under cursor exists; offer to create if missing (does not open on hit) |
| `<leader>pp` | n | `probe` | Probe path under cursor (suffix search, vsplit) |
| `<leader>pp` | v | `probe` | Probe selected text (suffix search, vsplit) |

Set any config key to `false` to disable that single mapping, or
`mappings = false` to disable all of them. Values may be a single lhs string
or a list of lhs strings (`{ "gP", "<leader>gp" }`).

`open_explorer` (`gM`) and `open_filetree` (`gT`) are the odd ones out:
neither opens a buffer, so neither goes through create-on-missing or the
external-opener heuristic below — both warn instead of prompting when the
resolved path does not exist. `open_explorer` is backed by
[lib.nvim's `cross.reveal_in_fm`](https://github.com/WKDSteve/lib.nvim),
falling back to a minimal built-in per-OS reveal
(`explorer.exe /select,`/`open -R`/`xdg-open`) when lib.nvim is absent.
`open_filetree` is backed by
[filetree.nvim](https://github.com/WKDSteve/filetree.nvim)'s
`adapter.open_reveal()` — a soft dependency with no fallback: it warns
(rather than erroring) when filetree.nvim isn't installed or hasn't
completed `setup()` yet.

### Create-on-missing

When `open_here`/`open_split`/`open_vsplit`/`open_tab` resolve to a path that
does not exist (and the fuzzy-alternate fallback in
`gopath.commands.finish_open` also comes up empty), `gopath.open` calls
`gopath.create.offer()`: a button dialog (ui.nvim's `ui.kit.confirm`,
falling back to `vim.ui.select` when ui.nvim is absent) asking to create the
file. "Create file" creates it (+ parent dirs via `mkdir -p`) and re-opens it
in the originally requested window mode, jumping to `res.range` if present.

There is **no** automatic "open nearest existing folder" fallback — a
directory can't be opened in a buffer the way a file can. Instead, when the
unresolved path has an existing ancestor directory *and*
[filetree.nvim](https://github.com/WKDSteve/filetree.nvim) is installed
and set up, the dialog offers a second button, **"Open in filetree"**: sets
cwd to that directory and roots/focuses filetree.nvim's tree there.

Config: `create_on_missing = { enable = true, confirm = true }`.
- `enable = false` restores the old "File not found" error for the passive
  open keymaps only. The `check` keymap/command still offers to create
  (explicit user action, bypasses the opt-out).
- `confirm = false` skips the dialog and creates the file silently whenever
  offered (no "Open in filetree" choice in this mode).

---

## User Commands

### `:Gopath` subcommand tree

`:Gopath <subcommand> [args…]` — built via
[`lib.nvim.bindings.usercmd.composer`](https://github.com/WKDSteve/lib.nvim),
tab-completion works at every level. `cache *` subcommands only appear when
`truncated.enable = true` in config.

| Subcommand | Args | Action |
| --- | --- | --- |
| `open` | `[edit\|split\|vsplit\|tab\|explorer]` | Resolve and open (`explorer` reveals in the file manager instead) |
| `copy` | — | Copy `path:line:col` to clipboard |
| `debug` | — | Print resolution chain to `:messages` |
| `probe` | `[edit\|split\|vsplit\|explorer\|filetree]` | Probe path under cursor / selection (partial or whole; `explorer`/`filetree` reveal instead of opening) |
| `check` | — | Check path under cursor exists; offer to create if missing |
| `cache build` | — | Rebuild filesystem index |
| `cache info` | — | Show cache statistics |
| `cache add-root` | `<dir>` | Add directory to cache search roots |
| `to-repos-dir` | — | Rewrite a repos-root path (any drive/OS) on the current line — or, with a visual range (`:'<,'>Gopath to-repos-dir`), just the selection — back to `$VAR` (reverse of `env_variable_resolution.shorten_dirs`). Also recognises a relative Markdown-link path that resolves under that root once joined to the buffer's own directory. And a *bare* relative path abbreviated from the middle (`team-notes/project.nvim/ROADMAP/ROADMAP.md`) is looked up a few levels below `$REPOS_DIR` and prefixed with the directory it was found in (`$REPOS_DIR/Notes/team-notes/…`) — only when the whole path exists; see `env_variable_resolution.root_search`. |
| `to-nvim-dir` | — | Same as `to-repos-dir`, for a "well-known" directory (default: `vim.fn.stdpath('config')`) matched literally (reverse of `env_variable_resolution.shorten_known_dirs`); also prefixes a bare relative path found below that directory, like `to-repos-dir` does for `$REPOS_DIR` |

`<Tab>` completes subcommands throughout, and `cache add-root`'s `<dir>`
completes directories — it is declared as a `DIR` argument, so the composer
derives both its completion and its validation from that one declaration. The
`:GopathCacheAddRoot` alias below completes the same way.

### Individual aliases

Kept for backward compatibility; each is a thin wrapper around the
`:Gopath` dispatcher above and can be disabled independently via
`config.commands`.

| Alias | Equivalent | Config key |
| --- | --- | --- |
| `:GopathResolve` | `:Gopath debug` | `resolve` |
| `:GopathOpen [mode]` | `:Gopath open [mode]` | `open` |
| `:GopathCopy` | `:Gopath copy` | `copy` |
| `:GopathDebug` | `:Gopath debug` | `debug` |
| `:GopathCheck` | `:Gopath check` | `check` |
| `:GopathProbe[!]` | `:Gopath probe` (`!` = split) | always on |
| `:GopathCacheBuild` | `:Gopath cache build` | requires `truncated.enable` |
| `:GopathCacheInfo` | `:Gopath cache info` | requires `truncated.enable` |
| `:GopathCacheAddRoot <dir>` | `:Gopath cache add-root <dir>` | requires `truncated.enable` |
| `:GopathToReposDir` | `:Gopath to-repos-dir` | `to_repos_dir` |
| `:GopathToNvimDir` | `:Gopath to-nvim-dir` | `to_nvim_dir` |

`commands = false` disables every user command, including the `:Gopath`
dispatcher itself.

---

## Autocommands

Four autocommands. The first two are registered from `lua/gopath/bindings/autocmds.lua`, the last two by the Lua resolvers when they load:

| Event | Group | Enabled when | Action |
| --- | --- | --- | --- |
| `BufWritePost` | `GopathPathCacheInvalidate` | always | Drop the path-lookup directory caches (`path.invalidate_caches`) |
| `BufWritePost` | `GopathCacheAutoRebuild` | `truncated.auto_rebuild_on_save = true` | Debounced (≤ once/5min) filesystem cache rebuild, matching `truncated.watch_patterns` (default `*.lua`, `*.vim`) |
| `BufDelete`, `BufWipeout` | `GopathAliasIndexCleanup` | always | Drop the cached alias map of the deleted buffer (`resolvers.lua.alias_index`) |
| `BufDelete`, `BufWipeout` | `GopathBindingIndexCleanup` | always | Drop the cached binding map of the deleted buffer (`resolvers.lua.binding_index`) |

The second is disabled by default (`auto_rebuild_on_save = false`).

The first is always on and deliberately cheap — it only clears three variables.
`gopath.util.path` caches a directory listing per search root so that `gF` does
not stat the filesystem on every keypress; writing a buffer is the usual way a
new file appears mid-session, so a write invalidates those listings. Files
created by gopath's own create-on-missing invalidate directly from
`gopath.create`, and installing a plugin moves the runtimepath, which the caches
key on. See [Resolution](resolution.md#path-lookup-caching).

