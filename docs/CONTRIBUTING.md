# Contributing to gopath.nvim

Thank you for your interest! Bugs, ideas and questions are welcome in the
[issue tracker](https://github.com/WKDSteve/gopath.nvim/issues); pull requests
very welcome.

The architecture — providers, resolvers, and how a cursor token becomes an
opened file — is [`Developer-Notes/DEV-README.md`](Developer-Notes/DEV-README.md)
and [`resolution.md`](resolution.md). Read those before adding a phase.

## Getting the repository into a session

Clone it and either symlink the checkout into your plugin directory or add it to
the runtime path directly:

```lua
vim.opt.rtp:prepend("/path/to/gopath.nvim")
require("gopath").setup({ mode = "hybrid" })
```

## Ground rules

- Lua only, idiomatic Neovim Lua. 2-space indentation.
- **The pipeline is ordered by certainty, and it stops at the first answer.** LSP
  before Treesitter before line extraction before suffix search before fuzzy
  alternate. A new phase has to say where it sits in that order and why — a
  cheap guess placed above an expensive certainty is how a jump ends up in the
  wrong file.
- **A resolver returns a candidate, it does not open anything.** Opening,
  splitting, revealing in the file manager and create-on-missing all happen in
  one place above the resolvers, which is why every phase gets those behaviours
  for free.
- **Fuzzy results are offered, never taken.** The last phase is a guess and is
  presented as one.
- **`resolve_at_cursor()` is public API.** hover.nvim and images.nvim call it
  from outside, through `pcall`. Changing its signature or its return shape
  breaks them silently — see
  [`FEATURES/INTEGRATIONS.md`](FEATURES/INTEGRATIONS.md).
- External tools (`fd`, `fdfind`, `rg`) are optional and detected; the walk
  fallback must stay correct, only slower.
- Commands are registered through `lib.nvim.bindings.usercmd.composer`.
- Descriptive commit messages.

## Project layout

| Path | Contains |
| --- | --- |
| `lua/gopath/providers/` | Sources of a candidate: LSP, Treesitter, line extraction |
| `lua/gopath/resolvers/` | Turning a candidate into a real path |
| `lua/gopath/truncated/` | The filesystem cache and suffix search for truncated tails |
| `lua/gopath/alternate/` | The fuzzy last phase |
| `lua/gopath/open/` | Opening: window targets, create-on-missing, the file manager |
| `lua/gopath/external/` | Non-text targets handed to the system application |
| `lua/gopath/bindings/` | The `:Gopath` route tree, the aliases and the keymaps |
| `lua/gopath/config/` | Defaults and `setup()` validation |
| `lua/gopath/util/` | Shared path helpers |
| `lua/gopath/health.lua` | `:checkhealth gopath` |
| `docs/` | Everything the README links to |
| `TESTS/` | Manual test guides: fixture lines to put the cursor on |
| `scripts/ci/` | The automated suites CI runs — see [`TESTS/README.md`](../TESTS/README.md) |

## Adding a resolver or a language

1. Decide which phase it belongs to, and justify its position in the order.
2. Implement it as a pure function from a cursor context to a candidate. It must
   not open, notify, or touch a window.
3. Add a spec under `scripts/ci/specs/` with real reference shapes — the ones
   that break resolvers are the ambiguous ones, not the clean ones. A manual
   guide under `TESTS/` on top of that is welcome, not a substitute.
4. Teach `g?` / `:Gopath debug` to name your phase in the resolution chain. A
   phase that does not show up there is undebuggable in the field.
5. Document it in [`resolution.md`](resolution.md) and the matching page under
   [`FEATURES/`](FEATURES/README.md).

## Tests

The suites run on [testing.nvim](https://github.com/WKDSteve/testing.nvim)
(`bash scripts/test.sh`, configured by `.testing.lua`); there is no
plenary/busted dependency. The specs are plain Lua with their own `check()` +
assertion helpers (`scripts/ci/harness.lua`). Nothing they do needs an LSP
server, a build tool, a subprocess or the network.

| Suite | What it covers |
| --- | --- |
| `scripts/ci/headless_tests.lua` | The plugin loads, `setup({})` runs, and every guide under `TESTS/` is still valid Lua |
| `scripts/ci/functional_tests.lua` | End-to-end resolution: the Lua resolvers, URLs, alternate frecency, the config merge |
| `scripts/ci/specs/*_spec.lua` | Per-module behaviour for the rest of the plugin |

[GitHub Actions](../.github/workflows/ci.yml) runs all three on every push and
PR to `main`. [`TESTS/README.md`](../TESTS/README.md) documents how to run them
locally, what is covered and what is deliberately left out.

## Workflow

1. Fork the repository.
2. Branch as `feature/<name>`.
3. Make the change, add a spec, update the affected pages under `docs/`.
4. Open a PR with a clear description of what changed and why.
