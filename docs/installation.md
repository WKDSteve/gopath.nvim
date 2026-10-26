# Installation

Full installation reference for gopath.nvim: requirements, plugin-manager
snippets, and optional integrations. For a minimal quickstart, see
[quickstart.md](quickstart.md).

## Contents

- [Requirements](#requirements)
- [lazy.nvim](#lazynvim)
- [packer](#packer)
- [Optional integrations](#optional-integrations)

---

## Requirements

| | |
| --- | --- |
| Neovim | **0.10+** |
| [lib.nvim](https://github.com/WKDSteve/lib.nvim) | required — the `:Gopath` command tree, the keymaps, the autocommands and the path helpers |

Optional, each detected at runtime and degrading to nothing when absent:

| | |
| --- | --- |
| [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) | Strongly recommended — the Treesitter phase reads the node under the cursor instead of guessing at the line |
| An LSP client | The first and most certain phase of the pipeline |
| `fd` / `fdfind` / `rg` | Speed up resolving a truncated path tail; without them the cache is built by walking |
| [ui.nvim](https://github.com/WKDSteve/ui.nvim) | `ui.kit.confirm`/`ui.kit.select` back the create-on-missing dialog and the fuzzy-alternate/multi-match pickers -- falling back to `vim.ui.select` when absent |

The CLI tools are declared in [docs/install.json](install.json) and read
by lib.nvim's
[deps module](https://github.com/WKDSteve/lib.nvim/blob/main/lua/lib/nvim/deps/README.md).
A popup explains what is missing the first time `setup()` runs after installing;
`:Lib deps show gopath.nvim` repeats it any time. Turn the popup off in this
plugin's own spec with `deps_popup = false`, or globally with
`vim.g.lib_nvim_deps_disable_first_run = true`.

## lazy.nvim

```lua
{
  "WKDSteve/gopath.nvim",
  event = "VeryLazy",
  dependencies = {
    "WKDSteve/lib.nvim",             -- cross-platform path helpers
    "nvim-treesitter/nvim-treesitter",  -- optional but recommended
  },
  opts = {
    mode = "hybrid",
  },
}
```

> **A lazy-load trigger is required, not optional.** `event = "VeryLazy"`
> above is the simplest one, but `cmd`, `keys`, `ft`, or `lazy = false` all
> work equally well. With an `opts = {...}` table and no trigger at all,
> lazy.nvim never sources the plugin — `setup()` is simply never called, no
> keymaps or commands are registered, and **no error is shown**: `gP` does
> nothing and even `:checkhealth gopath` is "not found" because the plugin
> was never loaded in the first place. If you use a `config = function()
> require("gopath").setup({...}) end` form instead of `opts`, the same rule
> applies — a trigger is still required for lazy.nvim to ever call it.

> **`lib.nvim`** is now **required**: the `:Gopath` command layer is built on
> `lib.nvim.bindings.usercmd.composer`, which registers unconditionally. It also
> provides cross-platform separator handling (forward-slash canonicalization
> internally, OS-native paths when opening files) — that integration still
> degrades to built-in fallbacks if lib.nvim is somehow missing, but
> `:Gopath` itself will fail to register without it. The `ui.kit.confirm`
> create-on-missing dialog and the fuzzy-alternate/multi-match pickers are a
> separate, optional dependency on [ui.nvim](https://github.com/WKDSteve/ui.nvim),
> falling back to `vim.ui.select` when it is absent.

## packer

```lua
use {
  "WKDSteve/gopath.nvim",
  requires = {
    "WKDSteve/lib.nvim",             -- required: :Gopath command layer + path helpers
    "nvim-treesitter/nvim-treesitter",  -- optional but recommended
  },
  config = function()
    require("gopath").setup({
      mode = "hybrid",
    })
  end,
}
```

## Optional integrations

`lib.nvim` is also used for cross-platform path separators and notify
styling — those integrations fall back to built-ins if lib.nvim is somehow
missing, even though the `:Gopath` command layer itself will not register
without it (see [Requirements](#requirements)). The `ui.kit.confirm`
create-on-missing dialog and the fuzzy-alternate/multi-match pickers come
from [ui.nvim](https://github.com/WKDSteve/ui.nvim) instead, falling
back to `vim.ui.select` when it is absent.

- *(optional)* [open.nvim](https://github.com/WKDSteve/open.nvim) — external
  files (images, PDFs, URLs, …) are routed through its `default` handler
  (WSL-aware); falls back to gopath's built-in per-OS opener when absent
- *(optional)* [which-key.nvim](https://github.com/folke/which-key.nvim) — labels
  the `probe` keymap when installed
- *(optional)* [filetree.nvim](https://github.com/WKDSteve/filetree.nvim) —
  adds an "Open in filetree" button to the create-on-missing dialog when the
  unresolved path has an existing ancestor directory
- *(optional)* [pdfport.nvim](https://github.com/WKDSteve/pdfport.nvim) —
  opening a PDF offers a chooser (System app / Buffer / Float / Terminal)
  instead of always handing it to the system viewer; see
  `external.pdf` in [configuration.md](./configuration.md)
- *(optional)* `git` — git-root detection for tailsearch search roots; skipped
  without it, no other behaviour changes
