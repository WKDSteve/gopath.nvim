# External files

## External file opening

Images, PDFs, and other media files resolved by gopath open automatically
in the system default application instead of as a text buffer.
`opts.external.extensions` extends the built-in extension list (does not
replace it).

- **Module:** `external/init.lua`, `external/helpers/detector.lua`
- **Config:** `opts.external.enable` (default `true`),
  `opts.external.extensions` (default `nil`, extends the built-in list)

## URLs

A URL under the cursor is opened in the browser instead of being turned into a
file path. This is what makes `gP` (and any keymap bound to it, e.g. `gF` or
`<2-LeftMouse>`) work on links in `:messages`, notification buffers, comments,
markdown docs and terminal output.

Two recognition strengths, deliberately placed at different points of the
resolve pipeline:

| Strength | Matches | Runs |
|---|---|---|
| strict | explicit scheme (`https://`, `ftp://`, `file://`, `mailto:`) or a `www.` prefix | before every file resolver — no local path can be spelled this way |
| loose | bare host with a known TLD (`github.com/neovim/neovim`), scp-style git remote (`git@github.com:foo/bar.git`) | after every file resolver missed — a real `notes.info` on disk still wins |

The URL is read from the raw buffer line, not from `<cfile>`: `'isfname'` stops
at `?`, `&` and `#`, which would silently truncate every URL carrying a query
string or fragment. Wrapping delimiters and trailing sentence punctuation are
stripped (`(https://x).` → `https://x`), balanced pairs inside the URL are kept.
Scheme-less targets are normalized (`www.google.com` → `https://www.google.com`,
`git@github.com:foo/bar.git` → `https://github.com/foo/bar`).

Results carry `kind = "url"` and `exists = true`, so they never enter the
create-on-missing flow — this is the fix for `gF` on a link offering to create
`<cwd>/https:/example.com/...`.

- **Module:** `resolvers/common/url.lua`, `util/url.lua`
- **Config:** `opts.url.enable` (default `true`),
  `opts.url.bare_hosts` (default `true`, set `false` to require an explicit
  scheme), `opts.url.schemes` / `opts.url.tlds` (default `nil`, both extend the
  built-in lists)

## Reveal in file manager

`gM` (config key `mappings.open_explorer`, also `:Gopath open explorer` /
`:GopathOpen explorer`) resolves the path under the cursor like the other
open keymaps, but instead of opening it in a buffer/window, reveals it in the
OS file manager — Explorer on Windows, Finder on macOS, the first
select-capable manager found on Linux (`nautilus`, `nemo`, `dolphin --select`,
`thunar`, `caja`; falls back to opening the parent directory when none is
select-capable). A file is selected inside its parent directory; a directory
is navigated into.

This is a distinct intent from external opening above: external opening hands
a path to whatever application is registered for its extension (an image
viewer, a PDF reader); `gM` shows *where* the file lives instead of launching
anything. It takes priority over the external-app heuristic, so `gM` on an
image reveals it in Explorer/Finder rather than launching an image viewer.
A resolved-but-missing path is not offered through create-on-missing here —
`gM` warns instead, since there is nothing on disk yet to reveal.

- **Module:** `external/helpers/revealer.lua`, backed by
  [lib.nvim's `cross.reveal_in_fm`](https://github.com/WKDSteve/lib.nvim)
  (falls back to a minimal built-in per-OS reveal when lib.nvim is absent)
- **Config:** `mappings.open_explorer` (default `"gM"`, set `false` to disable)

## Reveal in filetree.nvim

`gT` (config key `mappings.open_filetree`, also `:Gopath open filetree` /
`:GopathOpen filetree`) is the in-editor analogue of `gM` above: resolves the
path under the cursor the same way, but focuses it in
[filetree.nvim](https://github.com/WKDSteve/filetree.nvim)'s own sidebar
instead of the OS file manager — for navigating a project through Neovim's
own tree rather than switching to a separate window. Same priority reasoning
as `gM`: it takes precedence over the external-app heuristic, and a
resolved-but-missing path just warns rather than offering to create it.

Soft dependency, no fallback: unlike `gM` (which degrades to a minimal
built-in reveal when lib.nvim is absent), `gT` simply warns when
filetree.nvim isn't installed or hasn't completed `setup()` yet — there is
no non-filetree.nvim way to reveal a path *inside Neovim's own tree*.

- **Module:** `util/filetree.lua` (the shared soft-dependency seam this and
  the create-on-missing dialog's "Open in filetree" button both use), calling
  filetree.nvim's own `adapter.open_reveal()`
- **Config:** `mappings.open_filetree` (default `"gT"`, set `false` to disable)

## Opener fallback chain

Three-stage fallback for actually launching the external application, each
stage falling through to the next on dispatch failure rather than only
when the stage is merely unavailable:
[open.nvim](https://github.com/WKDSteve/open.nvim)'s `default` handler
(if installed) → lib.nvim's cross-platform system opener → a minimal
built-in per-OS opener (`open`/`xdg-open`/`explorer.exe`).

- **Module:** `external/helpers/opener.lua`
