> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# gopath.nvim

```
 ██████╗  ██████╗ ██████╗  █████╗ ████████╗██╗  ██╗
██╔════╝ ██╔═══██╗██╔══██╗██╔══██╗╚══██╔══╝██║  ██║
██║  ███╗██║   ██║██████╔╝███████║   ██║   ███████║
██║   ██║██║   ██║██╔═══╝ ██╔══██║   ██║   ██╔══██║
╚██████╔╝╚██████╔╝██║     ██║  ██║   ██║   ██║  ██║
 ╚═════╝  ╚═════╝ ╚═╝     ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝
                                               .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-beta-orange)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)
[![CI](https://github.com/WKDSteve/gopath.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/WKDSteve/gopath.nvim/actions/workflows/ci.yml)
[![wkd](https://img.shields.io/badge/wkd-family-c6ff3d)](https://wkdsteve.github.io/wkd/p/gopath/)

> Part of the [wkd](https://wkdsteve.github.io/wkd/) family — see this plugin's [page](https://wkdsteve.github.io/wkd/p/gopath/) on the site.

One key, and you are at the file the cursor is pointing at — however that
reference happens to be written. gopath.nvim resolves symbols, `require()`
paths and arbitrary file references under the cursor through a multi-phase
pipeline, so a `require("a.b")`, a bare path, a `:help` tag and a
stack-trace line all end in the same place: the right file, at the right line.

---

> **[buffer-ctx.nvim](https://github.com/WKDSteve/buffer-ctx.nvim)** — the
> other direction: it *writes* a `require("foo.bar")` or `path:line` reference,
> gopath jumps back to one.
>
> **[hover.nvim](https://github.com/WKDSteve/hover.nvim)** and
> **[images.nvim](https://github.com/WKDSteve/images.nvim)** — both call
> `resolve_at_cursor()` from outside, through `pcall`, so gopath stays a soft
> dependency on their side. What they rely on is
> [docs/FEATURES/INTEGRATIONS.md](docs/FEATURES/INTEGRATIONS.md).
>
> **[open.nvim](https://github.com/WKDSteve/open.nvim)** — takes over where
> the target is not a file at all: a URL, a directory, an application.
>
> **[tasks.nvim](https://github.com/WKDSteve/tasks.nvim)** — a task id
> (`lib.nvim/my-task`) in a to-do list, a commit message or a comment opens its
> task file, open or finished; with gF and `:Gopath open`, several matches are
> offered to pick from (other entry points take the first). Only an id a vault
> knows counts, so a relative path is never taken for one
> (`tasks = { enable, vaults }` or `tasks = false`, see
> [All options](docs/configuration.md)).
>
> All of the above are soft: without them everything else works unchanged.
> [lib.nvim](https://github.com/WKDSteve/lib.nvim) is the one real
> dependency — see [Requirements](docs/installation.md#requirements).

---

## Documentation

Start at [docs/README.md](docs/README.md) — what's where, and which question
each page answers.

### The Basics

- [Requirements](docs/installation.md#requirements) — Neovim version, required plugins and CLI tools.
- [Installation](docs/installation.md) — plugin managers and load-trigger variants.
- [Quickstart](docs/quickstart.md) — the first thing to run after installing.

### Configuration

- [What you get with the defaults](docs/what-you-get.md) — the keymap table that matters on day one.
- [All options](docs/configuration.md) — every `setup()` option and its default.
- [Commands / bindings cheatsheet](docs/BINDINGS.md) — the whole `:Gopath` subcommand tree.

### The Rest

- [What it does and what not](docs/scope.md) — the resolution phases, at a glance.
- [Why it does it that way](docs/Developer-Notes/DEV-README.md) — architecture, providers, resolvers.
- [Health check](docs/troubleshooting.md#health-check) — what `:checkhealth gopath` reports.
- [Troubleshooting](docs/troubleshooting.md#troubleshooting) — common failures and fixes.
- [Contributing](docs/CONTRIBUTING.md) — ground rules, project layout, and how to add a resolver.
- [Feedback](https://github.com/WKDSteve/gopath.nvim/issues)

`:help gopath` is the same reference inside the editor.

---

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

gopath.nvim is released under the [MIT License](https://opensource.org/licenses/MIT).
