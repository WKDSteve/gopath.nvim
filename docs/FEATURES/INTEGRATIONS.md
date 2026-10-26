# Integrations

gopath.nvim is a resolver, and a resolver is useful to more than the keymap
that ships with it. Two plugins in this ecosystem call it directly, and both
go through the same entry point:

```lua
require("gopath.resolve").resolve_at_cursor()  --> { kind, path, exists, … }
```

Both reach it through `pcall`, so gopath stays a soft dependency on their
side: uninstalled, each falls back to `<cfile>` and loses only the cases
`<cfile>` could never have done.

## hover.nvim — the path under the cursor, previewed

[hover.nvim](https://github.com/WKDSteve/hover.nvim) opens a float showing
whatever the cursor rests on. gopath is what makes a *truncated* path hover at
all — `...nvim/init.lua` copied out of `:messages`, a `:line:col` suffix, a
file findable only through `&path` / rtp / a tail search.

Two rules it applies to the answer, both worth knowing when a result
surprises someone:

- **A `kind == "url"` result is declined.** gopath opens URLs in a browser;
  the hover has its own URL preview and reaches it by another route.
- **`exists` must be true.** A result for something not on disk is discarded,
  and whether that absence is worth reporting is then hover's decision, not
  gopath's. A false "no such file" float is therefore **not** a gopath bug —
  it is the single most likely misattribution, because the float looks like a
  resolver verdict and is not one.

**And one measurement that belongs here rather than there — with a correction
made on 2026-09-03.** hover asks gopath first on an explicit request, but on
its automatic `CursorHold` trigger it asks only where gopath could plausibly
help: the token contains `...` or `…`, or it has no slash at all. That gate
was built because a **failing** `resolve_at_cursor` was measured at **13.2 ms**
in the population an ambient trigger produces — mostly prose that is not a
path at all.

Measuring it here found **two** costs where that number saw one, and the
larger had nothing to do with resolving:

- **A 200 ms LSP wait**, on every buffer with no server attached.
  `buf_request_sync` does not return early when nobody is listening. That is
  fixed here now — the provider asks whether a client is attached before
  sending — and it is why the original 13.2 ms could not be reproduced: it was
  measured in a buffer that *had* a server, where the request is answered
  rather than timed out. See [resolution.md](../resolution.md).
- **The tail search**, ~11.5 ms for a token with separators that could be a
  relative path. That one is real resolution work and is unchanged.

So the downstream gate **stays**, and the reason is now sharper than it was:
after the fix a token with no separator costs ~100 µs and one with separators
still costs ~11.5 ms — which is exactly the shape hover's gate already has. It
refuses the slash-bearing tokens and asks for the rest.

- **Consumer module:** hover.nvim `lua/hover/bare_path.lua` (`via_gopath`)
- **Their write-up:** [hover.nvim INTEGRATIONS.md](https://github.com/WKDSteve/hover.nvim/blob/main/docs/INTEGRATIONS.md)

## images.nvim — the picture under the cursor

[images.nvim](https://github.com/WKDSteve/images.nvim) uses gopath as the
third step of its `under_cursor`: markdown links first, a `<figure>` block
second, then gopath, then `<cfile>`. It keeps only results whose path carries
a configured image extension, so an LSP symbol, a `:help` subject or a URL
that gopath resolved for an unrelated reason falls through instead of
hijacking the picture.

- **Consumer module:** images.nvim `lua/images/resolve.lua`
  (`resolve_via_gopath`)
- **Their config:** `display.gopath_fallback`, default `true`

## gopath.integrations.menu — the right-click "Paths" entry (outbound)

The two sections above are gopath as a library *other plugins* call into.
This one is the other direction: gopath itself is a "Pattern-B" contributor
to a host's global right-click context menu (`lib.nvim.contextmenu`/
nvzone-menu-shaped — the same convention
[filetree.nvim](https://github.com/WKDSteve/filetree.nvim) and
[open.nvim](https://github.com/WKDSteve/open.nvim) ship their own menu
integrations through):

```lua
local items = require("gopath.integrations.menu").items()   -- inline entries
-- or:
local sub = require("gopath.integrations.menu").submenu()   -- a single "  Paths" fly-out, or nil
```

Self-gating like the other two: an empty list / `nil` when ui.nvim (soft
dependency, for `ui.contextmenu`) is not installed, or nothing resolves.
What "nothing under the cursor" means here is exactly `resolve_at_cursor`'s
own answer — **except** when the buffer is still in Visual mode at the
moment the host calls `items()` (a right-click while a selection is up,
before any `<Esc>`): then the SELECTED text is resolved instead, via
`gopath.resolve_selection` (a `$VAR/rest` reference or a URL — what lets a
PARTIALLY selected one work here too, not just a fully recognized path).
Tailsearch's filesystem suffix search is deliberately not tried from the
menu — a right-click that silently kicks off a filesystem walk on every
miss would be a bad trade; that is what `:GopathProbe` is for.

`integrations = { ui_menu = false }` keeps ui.nvim's right-click menu (`ui.menu`)
from showing the entry while `items()`/`submenu()` keep working for any other
host. The module also answers `enabled()`, which is what `ui.menu` asks first.

- **Module:** `lua/gopath/integrations/menu.lua`
- **Entries:** "Open" (always, for anything resolved), "Reveal in File
  Manager" / "Reveal in filetree.nvim" (only for `kind == "file"` — a URL or
  a `:help` subject only ever gets "Open")
- **Wiring it up:** a host adds one row to its own contributor table, e.g.
  `config.menu.mappings.CONTRIBUTORS` in a `lib.nvim.contextmenu`-based
  setup — see that host's own docs for the exact shape.

## What this means for changes here

`resolve_at_cursor` is a public entry point with consumers outside this
repository, and its **result shape is the contract**: `kind`, `path`, `exists`,
and a `:line:col` already applied. `kind = "url"` is load-bearing in
particular — both consumers use it to *decline*, not to route, so folding URLs
into another kind would silently turn two hovers into browser launches.
