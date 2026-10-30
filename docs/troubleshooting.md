# Health Check & Troubleshooting

Diagnostics and fixes for common gopath.nvim issues.

## Contents

- [Health Check](#health-check)
- [Troubleshooting](#troubleshooting)

---

## Health Check

```vim
:checkhealth gopath
```

Checks:
- Neovim version compatibility
- External tools: `fd`/`fdfind`, `rg`, `git`
- Active LSP clients
- Tree-sitter: whether a parser is available for the filetype of the buffer
  you ran `:checkhealth gopath` from (asked of Neovim's built-in
  `vim.treesitter`; nvim-treesitter is not required)
- which-key.nvim availability
- Configuration (linepath, tailsearch, alternate, keymaps)
- `setup()` options: unrecognized keys (with a "did you mean" hint) and
  values that did not fit their option — each falls back to its default
  instead of being silently ignored or breaking gopath at some later call
- Truncated path cache status

---

## Troubleshooting

### `gP` does nothing (and `:checkhealth gopath` / `:Gopath` don't even exist)
This means gopath.nvim was never loaded at all — with lazy.nvim, an `opts =
{...}` table with no `event`/`cmd`/`keys`/`ft` trigger and no `lazy = false`
is never sourced. There is no error: the plugin manager simply never calls
`require("gopath").setup(...)`, so no keymaps, no commands, nothing.
**A lazy-load trigger (`event = "VeryLazy"` is the simplest one) or `lazy =
false` in the plugin spec is required**, not optional — see
[docs/installation.md](./installation.md).

### `gP` does nothing (but `:Gopath debug` / `:checkhealth gopath` work)
1. `:Gopath debug` — shows what the resolver found (or why it failed)
2. `:checkhealth gopath` — verify external tools and config
3. Ensure Neovim ≥ 0.10

### Path not found
- Try `<leader>pp` (probe) — uses suffix search across more roots
- Run `:Gopath probe` to see if tailsearch finds it
- Add an explicit root: `:Gopath cache add-root <dir>`

### Truncated path (`...`) not resolving
- Check cache: `:Gopath cache info`
- Rebuild: `:Gopath cache build`
- Ensure `fd` or `rg` is installed (`:checkhealth gopath`)

### Multiple matches / wrong file opened
- `tailsearch.ask_on_ambiguous = true` (default) shows `vim.ui.select`
- Set `tailsearch.roots` explicitly to narrow the search scope
