# Language support

## Lua (full support)

The deepest language-specific resolution, since Lua/Neovim configs are
gopath's primary use case.

- `require("a.b.c")` → resolves to `lua/a/b/c.lua`
- Bare identifier (`local resolver = require("gopath.resolve")`, cursor on
  `resolver` alone) → opens `resolve.lua` via the Treesitter-provider
  `identifier_locator` pass, which runs before the chain resolver
- `local x = require("mod"); x.func()`, cursor on `x` → opens `mod.lua`
- Table chain (`config.get()`) → opens the definition of `get` inside the
  `config` module, with or without a language server: without one the
  Treesitter pass finds `function M.get()` or `M.get = ...` (a key the
  module's table constructor holds is its value and opens at that line)
- LSP-first by default (`order = { "lsp", "treesitter", "builtin" }`): a
  chain like `config.setup()` first tries `symbol_locator.via_lsp`, which
  jumps straight to the exact definition line/column; the Treesitter chain
  walk only runs as a fallback when LSP has no client or times out
  (`opts.lsp_timeout_ms`)
- `local_to_module`: LSP results pointing at a `require()` line get
  resolved onward to that module's own file
- Value origin: follows config-table values back to their source module —
  `local cfg = require("plugin.config"); cfg.highlight.enable_x`, cursor on
  `enable_x`, opens `config.lua` at the `enable_x = ...` line, however
  deeply nested the key is (`M.foo = {...}`, `M = { foo = {...} }`,
  `return { foo = {...} }`); root-identifier candidates are cached per
  file mtime

- **Module:** `resolvers/lua/{require_path,identifier_locator,
  local_to_module,chain,symbol_locator,table_locator,value_origin,
  binding_index,alias_index,ts_lua_ast}.lua`
- **Config:** `opts.languages.lua = { enable = true, resolvers = nil,
  custom_resolvers = nil }` — `custom_resolvers` run before the built-ins;
  `enable = false` disables gopath's Lua-specific resolvers for `.lua`
  buffers while universal features (file paths, help tags) keep working

## Other per-language resolvers

One resolver module each, handling that language's import/reference
syntax: Python, JavaScript/TypeScript (+ JSX/TSX), Go, Rust, C/C++, C#,
Zig, Java.

- **Module:** `resolvers/python/import_path.lua`,
  `resolvers/javascript/import_path.lua`, `resolvers/go/import_path.lua`,
  `resolvers/rust/use_path.lua`, `resolvers/c/include_path.lua`,
  `resolvers/csharp/using_path.lua`, `resolvers/zig/import_path.lua`,
  `resolvers/java/import_path.lua`
- **Config:** `opts.languages.<name> = { enable = true, resolvers = nil,
  custom_resolvers = nil }` — one entry per language, all enabled by
  default: `python`, `javascript`, `javascriptreact`, `typescript`,
  `typescriptreact`, `rust`, `go`, `c`, `cpp`, `cs`, `zig`, `java`

## Universal (all filetypes)

Resolvers that don't depend on the buffer's filetype, always active
regardless of `opts.languages`:

- File paths — relative, absolute, with `:line:col`, `(line)`, `+line`
- URLs → `vim.ui.open` / system browser
- `:help` tags — `vim.api.*`, `vim.fn.*`, `vim.loop`, etc.
- `$ENV_VAR/path/file.md`, `${VAR}\rest\of\path.txt`
- Whole-line stacktrace extraction (see [Navigation](NAVIGATION.md))
- Suffix-based partial-path search (see [Navigation](NAVIGATION.md))

- **Module:** `resolvers/common/{help,env_path,filetoken}.lua`
- **Config:** `opts.env_variable_resolution.enable` (default `true`)
