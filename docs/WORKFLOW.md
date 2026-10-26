# Workflow — using gopath.nvim day to day

Every feature here is documented on its own in `docs/FEATURES/`. This is
the different question: how the pipeline, cache, and picker actually
combine once you're jumping around a real codebase, not reading one
resolver at a time.

## `gP` is the default habit; reach for the others only when it guesses wrong

`gP` (open here) covers the large majority of jumps because the pipeline
tries LSP first, then Treesitter, then the universal resolvers, and stops
at the first confident hit. The other open keymaps (`g|`, `` g\ ``, `g}`)
aren't a different resolution — they're the *same* result opened in a
different window, so reach for them when you already know you want a
split/tab, not as a "try again" action. When `gP` opens the wrong file
(rare, but happens with ambiguous bare identifiers), `g?` prints the full
resolution chain to `:messages` — check it before assuming the plugin is
broken; it usually shows exactly which phase produced the wrong hit and
why (e.g. LSP timed out and a lower-confidence universal resolver won).

## `event = "VeryLazy"` (or equivalent) is not optional

Without a lazy-load trigger in the plugin spec, lazy.nvim never sources
gopath at all — no error, `gP` silently does nothing. This is the single
most common "it's not working" report for this plugin and has nothing to
do with the resolution pipeline; check `:Lazy` / your plugin spec before
debugging resolvers.

## Truncated paths: let the cache warm up once, then trust it

The first `gP`/`gF`-style jump on a truncated stack-trace path in a fresh
Neovim session may hit the cache before it's finished its deferred ~2s
initial build — `:Gopath cache info` shows whether a build has completed.
On a cache miss, resolution falls back to an async live search (shows
"search running", never blocks), so a truncated-path jump right after
opening Neovim can feel slower than the same jump five seconds later once
the index is warm. `:Gopath cache build` forces an immediate rebuild if
you've just added a large new directory the cache wouldn't otherwise pick
up until `cache_refresh_interval` elapses.

## `gC` vs. the passive open keymaps, when the target doesn't exist

`gP`/`g|`/`` g\ ``/`g}` only offer to create a missing file when
`create_on_missing.enable = true` (the default) — if you've turned that
off globally (e.g. to make an unresolved reference a hard error instead of
a prompt) and still want the create-or-open-in-filetree dialog for one
specific case, `gC` (`:GopathCheck`) always offers it regardless of that
setting, since it's an explicit user action rather than a side effect of
navigation.

## Fuzzy alternates vs. create-on-missing — the alternate always gets first refusal

When a resolved path doesn't exist, gopath tries the fuzzy-alternate
matcher *before* offering to create anything — so renaming/moving a file
slightly (typo fixed, extension changed) usually surfaces the real file as
a suggestion rather than prompting you to create a duplicate. The trap:
if the alternate matcher's `similarity_threshold` (default 75) is set too
low for a codebase with many similarly-named files, you may get offered an
unrelated file instead of the create-file prompt you expected — raise the
threshold rather than fighting the picker if that keeps happening.

**The threshold decides *what* is offered; frecency decides the order.** A
candidate you have picked from this dialog before rises within its similarity
band, capped so it can never lift something below the threshold or invert a
clear winner. If the *wrong* file keeps appearing at all, that is the
threshold; if the right one keeps appearing second, pick it once and it will
be first from then on.

## Suffix search vs. exact resolution: `<leader>pp` is for when you already suspect a truncation

Visual/normal-mode `<leader>pp` (probe) exists specifically for spans the
whole-line extractor didn't pick up automatically — for example a bare
filename embedded mid-sentence in a log line with no path separators
around it that would let the extractor recognize it as a path at all.
Select exactly the fragment you believe is the tail of a real path; probe
runs the same suffix-candidate search the cache-backed resolver uses, so
an overly broad selection (extra words around the filename) produces worse
candidates than a tight one.

## A URL under the cursor opens as a URL now, not as a path to create

`gP` (and anything bound to it — `gF`, `<2-LeftMouse>`) used to turn a URL
into a local path and then offer to create it: `<cwd>/https:/example.com/…`.
Two things were wrong and both are fixed: the token character class had no
`?`, `&` or `#`, so every URL with a query string or fragment was silently
truncated first, and nothing recognised the result as a URL afterwards.

So the habit stays one key: put the cursor on it and press `gP`, whatever "it"
turns out to be.

## Links in a document are document-relative

Markdown links resolve with the cursor on the **label**, not only on the path,
and the path is tried relative to the buffer's own directory rather than only
against the working directory — which is what a link in a document actually
means.

The line extractor sources its openable extensions from `gopath.external`,
including your own `external.extensions`, so "can open this" and "can find this
in a line" cannot drift apart — a `.pdf` link used to produce no candidate at
all. Unbalanced trailing brackets are dropped while balanced ones are kept, so
`C:/Program Files (x86)/x.pdf` survives and a link's closing `)` does not come
along.

## `gM`/`gT` reveal instead of opening

Every other open mode turns the resolved target into a buffer. `gM`
(`:Gopath open explorer`) hands it to the OS file manager instead — selecting
a file inside its parent directory, navigating into a directory. `gT`
(`:Gopath open filetree`) does the in-editor equivalent: focuses the path in
[filetree.nvim](https://github.com/WKDSteve/filetree.nvim)'s own sidebar
instead (soft dependency — warns if filetree.nvim isn't installed or set
up).

Reach for either when the next step is not reading the file but doing
something to it: attaching it, renaming it, looking at what else is in that
folder — `gM` for the OS's own tools, `gT` to stay inside Neovim's tree.
Both take priority over the external-app heuristic, so they reveal even a
file that would otherwise have been opened in another application.

## Language resolvers vs. universal resolvers don't fight over precedence — order matters per filetype

Disabling `opts.languages.lua.enable` doesn't disable navigation on `.lua`
files; it disables gopath's Lua-aware resolvers (`require()` parsing,
value-origin tracing) for that filetype and falls through to the
universal resolvers (file paths, help tags) instead. This is the knob to
reach for if a `custom_resolvers` entry you've written for Lua should be
the *only* thing running — set `enable = false` and only your custom
resolvers plus the universal ones remain in the chain, rather than trying
to out-prioritize the built-in Lua resolvers.
