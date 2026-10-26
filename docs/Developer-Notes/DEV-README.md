# Gopath.nvim - Developer Documentation

This document provides in-depth technical information for developers who want to extend, customize, or contribute to gopath.nvim.

> **Subsystem deep dives** (user-facing, EN + DE):
> [Cache](../cache.md) · [Resolution pipeline](../resolution.md) ·
> [Lua symbol resolution](../lua-symbols.md). Full docs index:
> [docs/README.md](../README.md).

---

## Table of content

  - [Architecture](#architecture)
    - [Core Components](#core-components)
  - [Resolution Flow](#resolution-flow)
    - [High-Level Flow](#high-level-flow)
    - [Detailed Resolution Logic](#detailed-resolution-logic)
  - [Provider System](#provider-system)
    - [Provider Interface](#provider-interface)
    - [Adding a New Provider](#adding-a-new-provider)
  - [Resolver System](#resolver-system)
    - [Resolver Interface](#resolver-interface)
    - [Result Schema](#result-schema)
  - [Creating Custom Resolvers](#creating-custom-resolvers)
    - [Example: Custom Language Resolver](#example-custom-language-resolver)
    - [Registering Custom Resolver](#registering-custom-resolver)
  - [Testing Resolvers](#testing-resolvers)
    - [Manual Testing](#manual-testing)
    - [Unit Test Example (planned)](#unit-test-example-planned)
  - [Alternate Resolution Deep Dive](#alternate-resolution-deep-dive)
    - [Similarity Algorithm](#similarity-algorithm)
    - [Custom Similarity Functions (planned)](#custom-similarity-functions-planned)
  - [External File Opening](#external-file-opening)
    - [File Type Detection](#file-type-detection)
    - [Platform-Specific Openers](#platform-specific-openers)
    - [Adding Custom Extensions](#adding-custom-extensions)
  - [Configuration Deep Dive](#configuration-deep-dive)
    - [Language Configuration](#language-configuration)
    - [Resolver Selection](#resolver-selection)
  - [Debugging](#debugging)
    - [Debug Output](#debug-output)
    - [Verbose Logging (planned)](#verbose-logging-planned)
  - [Performance Considerations](#performance-considerations)
    - [Caching](#caching)
    - [LSP Timeout](#lsp-timeout)
    - [Async Operations](#async-operations)
  - [Security Considerations](#security-considerations)
    - [Path Sanitization](#path-sanitization)
    - [External Command Injection](#external-command-injection)
    - [User-Provided Resolvers](#user-provided-resolvers)
  - [Performance Benchmarks](#performance-benchmarks)
    - [Typical Resolution Times](#typical-resolution-times)
  - [Contributing Guidelines](#contributing-guidelines)
    - [Code Style](#code-style)
    - [Pull Request Checklist](#pull-request-checklist)
    - [Testing](#testing)
  - [Additional Resources](#additional-resources)
    - [Neovim APIs Used](#neovim-apis-used)
    - [External References](#external-references)
  - [License](#license)

---

## Architecture

### Core Components

```sh
gopath.nvim/
├── lua/gopath/
│   ├── init.lua              # Public API & setup (incl. cache.setup wiring)
│   ├── config.lua            # Configuration management
│   ├── resolve.lua           # Resolution orchestrator (sync pipeline)
│   ├── registry.lua          # Provider & resolver registry
│   ├── commands.lua          # Command impls + async goto_at_cursor
│   ├── keymaps.lua           # Keymap registration
│   ├── usercommands.lua      # :Gopath… user-command registration
│   ├── health.lua            # :checkhealth gopath
│   │
│   ├── providers/            # Provider implementations
│   │   ├── builtin.lua       # Vim builtin functions
│   │   ├── token.lua         # Smart token extraction under cursor
│   │   ├── lsp.lua           # LSP client integration
│   │   └── treesitter.lua    # Treesitter queries
│   │
│   ├── resolvers/            # Language-specific resolvers
│   │   ├── common/           # Universal resolvers
│   │   │   ├── filetoken.lua # <cfile> resolution
│   │   │   ├── linepath.lua  # whole-line path extraction
│   │   │   ├── tailsearch.lua# suffix search (cache / sync / async)
│   │   │   ├── env_path.lua  # $VAR / ${VAR} expansion
│   │   │   └── help.lua      # :help tag resolution
│   │   └── lua/              # Lua-specific resolvers (see lua-symbols.md)
│   │       ├── require_path.lua  chain.lua  binding_index.lua
│   │       ├── alias_index.lua   identifier_locator.lua
│   │       ├── symbol_locator.lua value_origin.lua
│   │       └── local_to_module.lua table_locator.lua
│   │
│   ├── truncated/            # Truncated-path cache (see cache.md)
│   │   ├── cache.lua         # async filesystem index (in-memory + JSON)
│   │   └── finder.lua        # live search (sync fd/rg + async libuv walk)
│   │
│   ├── open/                 # Unified opener
│   │   ├── init.lua          # edit/split/vsplit/tab + jump + externals
│   │   └── help.lua          # Help window
│   │
│   ├── alternate/            # Fuzzy resolution
│   │   ├── init.lua          # Main logic
│   │   ├── ui.lua            # Selection UI
│   │   └── helpers/
│   │       ├── directory.lua # Directory operations
│   │       └── matcher.lua   # Similarity algorithms
│   │
│   ├── external/             # External file opening
│   │   ├── init.lua
│   │   └── helpers/
│   │       ├── detector.lua  # File type detection
│   │       └── opener.lua    # System opener
│   │
│   └── util/                 # Utilities
│       ├── path.lua          # Path search strategies
│       ├── cross.lua         # Cross-platform separators (lib.nvim)
│       ├── location.lua      # :line:col parsing (see util/location.md)
│       ├── log.lua  safe.lua  safe_notify.lua
└──     └── (error handling, logging, deferred notify)
```

---

## Resolution Flow

### High-Level Flow

```sh
User Action (gP)
    ↓
resolve_at_cursor()
    ↓
┌─────────────────────────────────┐
│ Phase 1: Universal Resolvers    │
│ • help.resolve()                 │
│ • filetoken.resolve()            │
└─────────────────────────────────┘
    ↓
┌─────────────────────────────────┐
│ Phase 2: Language-Specific      │
│ • Check if language enabled      │
│ • Run provider pipeline          │
│   - LSP                          │
│   - Treesitter                   │
│   - Builtin                      │
└─────────────────────────────────┘
    ↓
┌─────────────────────────────────┐
│ Phase 3: Fallback               │
│ • Extract <cfile>                │
│ • Build best-guess path          │
└─────────────────────────────────┘
    ↓
commands.goto_at_cursor()
    ↓
┌─────────────────────────────────┐
│ Phase 4: Post-Resolution         │
│ • Check if file exists           │
│ • Try alternate resolution       │
│ • Check external file type       │
│ • Open with appropriate opener   │
└─────────────────────────────────┘
```

### Detailed Resolution Logic

```lua
-- lua/gopath/resolve.lua (simplified)

function M.resolve_at_cursor(opts)
  local cfg = C.get()
  local ft = vim.bo.filetype

  -- Phase 1: Universal (works for ALL filetypes)
  local help_result = resolve_help()
  if help_result then return help_result end

  local filetoken_result = resolve_filetoken()
  if filetoken_result then return filetoken_result end

  -- Phase 2: Language-specific (optional enhancement)
  local lang = cfg.languages[ft]
  if lang and lang.enable ~= false then
    for _, provider in ipairs(cfg.order) do
      local result = run_provider_pipeline(ft, provider)
      if result then return result end
    end
  end

  -- Phase 3: Fallback
  local cfile = vim.fn.expand("<cfile>")
  if cfile ~= "" then
    return build_minimal_result(cfile)
  end

  return nil, "no-match"
end
```

---

## Provider System

### Provider Interface

Each provider must implement:

```lua
---@class Provider
---@field definition_at_cursor fun(timeout_ms: integer): table[]|nil

-- Example: lua/gopath/providers/lsp.lua
function M.definition_at_cursor(timeout_ms)
  local params = vim.lsp.util.make_position_params(0, 'utf-8')
  local res = vim.lsp.buf_request_sync(0, "textDocument/definition", params, timeout_ms)
  -- Process and return results
  return results
end
```

### Adding a New Provider

1. Create `lua/gopath/providers/your_provider.lua`
2. Implement required functions
3. Register in `lua/gopath/registry.lua`
4. Add to config `order` list

---

## Resolver System

### Resolver Interface

Each resolver must implement:
```lua
---@class Resolver
---@field resolve fun(): GopathResult|nil

-- Example: lua/gopath/resolvers/lua/require_path.lua
function M.resolve()
  local module = find_require_module_at_cursor()
  if not module then return nil end

  local path = search_module_path(module)
  if not path then return nil end

  return {
    language = "lua",
    kind = "module",
    path = path,
    source = "builtin",
    confidence = 0.85,
  }
end
```

### Result Schema

```lua
---@class GopathResult
---@field language string Filetype (e.g., "lua", "markdown")
---@field kind string Result type ("module", "field", "file", "help")
---@field path string|nil Absolute file path
---@field range table|nil {line: integer, col: integer}
---@field chain string[]|nil Dotted chain (e.g., {"cfg", "highlight"})
---@field source string Provider name ("lsp", "treesitter", "builtin")
---@field confidence number 0.0-1.0 confidence score
---@field exists boolean|nil Whether file exists on disk
---@field subject string|nil Help subject (for kind="help")
---@field subjects string[]|nil Help candidates (for kind="help")
```

---

## Creating Custom Resolvers

### Example: Custom Language Resolver
```lua
-- lua/gopath/resolvers/python/import_path.lua

local M = {}

---Resolve Python import statements to file paths
---@return GopathResult|nil
function M.resolve()
  local line = vim.api.nvim_get_current_line()

  -- Match: import foo.bar or from foo.bar import baz
  local module = line:match("^%s*import%s+([%w%.]+)")
               or line:match("^%s*from%s+([%w%.]+)%s+import")

  if not module then return nil end

  -- Convert module.name to module/name.py
  local path = module:gsub("%.", "/") .. ".py"

  -- Search in common Python paths
  local abs = search_python_path(path)
  if not abs then return nil end

  return {
    language = "python",
    kind = "module",
    path = abs,
    source = "custom",
    confidence = 0.8,
  }
end

return M
```

### Registering Custom Resolver
```lua
-- In user config
opts = {
  languages = {
    python = {
      enable = true,
      custom_resolvers = {
        require("gopath.resolvers.python.import_path"),
      },
    },
  },
}
```

**Note:** This is planned for a future release. Current architecture supports it but API is not yet exposed.

---

## Testing Resolvers

### Manual Testing
```lua
-- Test resolver directly
:lua local res = require("gopath.resolvers.lua.require_path").resolve()
:lua print(vim.inspect(res))

-- Test full resolution
:GopathDebug
```

### Unit Test Example (planned)
```lua
-- tests/resolvers/lua/require_path_spec.lua
describe("lua.require_path", function()
  it("resolves standard library modules", function()
    -- Setup test file with require("vim.api")
    local result = resolve_at_cursor()
    assert.is_not_nil(result)
    assert.equals("vim/shared.lua", result.path:match("vim/[^/]+%.lua$"))
  end)
end)
```

---

## Alternate Resolution Deep Dive

### Similarity Algorithm

Uses **Levenshtein distance** (edit distance):
```lua
-- lua/gopath/alternate/helpers/matcher.lua

function calculate_similarity(s1, s2)
  local distance = levenshtein_distance(s1, s2)
  local max_len = math.max(#s1, #s2)
  local similarity = (1 - (distance / max_len)) * 100
  return similarity
end
```

#### Examples:
* `chadrer.lua` vs `chadrc.lua`: **87%** (2 edits / 11 chars)
* `cofnig.lua` vs `config.lua`: **90%** (1 edit / 10 chars)
* `init.lua` vs `unit.lua`: **80%** (1 substitution / 8 chars)

### Ordering: similarity first, history as the tiebreak

`matcher.find_similar_files` sorts by similarity alone. `alternate/frecency.lua`
then reorders the surviving candidates by what was chosen from this dialog
before, through
[`lib.nvim.frecency`](https://github.com/WKDSteve/lib.nvim/blob/main/lua/lib/nvim/frecency/README.md)
on the `gopath-alternates` namespace.

The pass runs in `alternate/init.lua`'s `present()`, which is where both entry
points meet — `try_resolve` and the truncated-path route that arrives with
pre-built matches. Reordering in the matcher instead would have covered only
the first and ranked the same file two different ways depending on how the
dialog was reached.

**The cap is the design.** The bonus is
`max_bonus × score / (score + K)` with `K` set to one fresh visit's worth of
score, so it saturates instead of growing with the visit count. Without it a
single visit scores `log(2) × 100 ≈ 69` on the same 0–100 scale similarity
uses, and the list would be ordered by history with similarity as decoration.
Capped at 10 against a threshold of 75, it reorders inside a band and never
inverts a clear winner. Both properties are asserted in
`scripts/ci/functional_tests.lua`.

Recorded on the **choice**, not the open — a file is opened for a dozen
reasons, picked out of this list for exactly one — and flushed immediately,
because this dialog is rare enough that the write costs nothing.

### Custom Similarity Functions (planned)

```lua
-- Future API
opts = {
  alternate = {
    similarity_fn = function(s1, s2)
      -- Custom algorithm (e.g., prioritize prefix matches)
      if s2:match("^" .. vim.pesc(s1:sub(1, 3))) then
        return 95  -- High score for prefix match
      end
      return default_similarity(s1, s2)
    end,
  },
}
```

---

## External File Opening

### File Type Detection
```lua
-- lua/gopath/external/helpers/detector.lua

local EXTERNAL_EXTENSIONS = {
  "png", "jpg", "pdf", "mp4", ...
}

function M.is_external_file(path)
  -- Check URL
  if path:match("^https?://") then return true end

  -- Check extension
  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  return vim.tbl_contains(EXTERNAL_EXTENSIONS, ext)
end
```

### Platform-Specific Openers

| Platform | Command | Notes |
|----------|---------|-------|
| macOS | `open <path>` | Respects file associations |
| Linux | `xdg-open <path>` | Freedesktop standard |
| Windows | `powershell Start-Process "<path>"` | Better than `cmd start` (handles spaces) |

### Adding Custom Extensions
```lua
opts = {
  external = {
    enable = true,
    extensions = {
      "png", "jpg", "pdf",
      "custom_ext",  -- Your custom extension
    },
  },
}
```

---

### Line/Column Support (all filetypes)

Line and column parsing is filetype-agnostic — see
[location.md](./util/location.md). Gopath automatically parses and respects
line and column numbers in file paths:

#### Supported Formats

| Format | Example | Description |
|--------|---------|-------------|
| `:line` | `file.lua:42` | Line only |
| `:line:col` | `file.lua:42:15` | Line and column |
| `(line)` | `file.lua(42)` | Parenthesis format |
| `(line:col)` | `file.lua(42:15)` | Parenthesis with column |
| `+line` | `file.lua +42` | Vim-style |

#### Examples

```lua
-- In any buffer or :messages
"Error in lua/gopath/init.lua:42:15"
--        ^^^^^^^^^^^^^^^^^^^^^^^^
-- Cursor here → gP → Opens at line 42, column 15

-- Works with truncated paths
"...nvim-data/lazy/gopath.nvim/lua/gopath/config.lua:100"
-- Resolves and opens at line 100
```

#### LSP Integration

When LSP is available, line/column information is automatically provided for symbol definitions:

```lua
local setup = require("gopath.config").setup
--                                     ^^^^^
-- Cursor here → gP → Opens config.lua at exact setup() definition
```

### Direct Symbol Definition Jump

#### Architecture

##### Provider Priority:
1. **LSP** (confidence: 1.0) - Exact symbol definitions with line/col
2. **Treesitter** (confidence: 0.75-0.85) - Heuristic pattern matching
3. **Builtin** (confidence: 0.5) - Module-level resolution

#### Resolvers Involved

| Resolver | Purpose | Example |
|----------|---------|---------|
| `symbol_locator.via_lsp` | LSP symbol definitions | `config.setup()` → definition line |
| `symbol_locator.via_treesitter` | Pattern-based search | Fallback when LSP unavailable |
| `identifier_locator` | Bare variable → module | `config` → gopath/config.lua |
| `value_origin` | Chain initialization | `cfg.highlight` → M.cfg.highlight |

#### Resolution Flow

```sh
User presses gP on: config.setup()
                    ^^^^^^
         ↓
LSP Provider: symbol_locator.via_lsp()
         ↓
LSP Request: textDocument/definition
         ↓
Response: { path, line, col }
         ↓
Open: gopath/config.lua:42 (exact definition)
```

#### Fallback Chain

```sh
LSP unavailable or no result
         ↓
Treesitter Provider
         ↓
Parse chain: config.setup
         ↓
binding_index: config → "gopath.config"
         ↓
symbol_locator.via_treesitter()
         ↓
Search file for "setup" pattern
         ↓
Open: gopath/config.lua:42 (heuristic match)
```

---

## Configuration Deep Dive

### Language Configuration

```lua
languages = {
  lua = {
    enable = true,        -- Enable Lua-specific features
    resolvers = nil,      -- nil = all available, or provide list
    custom_resolvers = {  -- User-provided resolver modules
      my_custom_resolver,
    },
  },

  markdown = {
    -- Not specified = universal features only (filetoken, help)
  },

  python = {
    enable = false,  -- Explicitly disable (blocks all)
  },
}
```

#### Behavior:
* **Not in config**: Universal features work (filetoken, help, external)
* **enable = true**: Universal + language-specific features
* **enable = false**: Blocked entirely (returns "language-disabled")

### Resolver Selection

```lua
-- Use only specific resolvers
languages = {
  lua = {
    enable = true,
    resolvers = {
      "require_path",  -- Only require() resolution
      "chain",         -- Only chain resolution
    },
  },
}
```

#### Available Lua Resolvers:
* `require_path` - Resolve `require("module")` to file
* `binding_index` - Map identifiers to modules
* `alias_index` - Resolve aliases
* `chain` - Extract dotted chains
* `value_origin` - Find initializer locations
* `symbol_locator` - Locate symbols in files

---

## Debugging

### Debug Output

```vim
:GopathDebug
```

#### Output:

```vim
=== Gopath Debug ===
  Filetype: lua
  Chain: M -> cfg.highlight
  Binding map size: 5
  Result: {
    confidence = 0.9,
    kind = "field",
    language = "lua",
    path = "/path/to/config.lua",
    range = { line = 42, col = 3 },
    source = "treesitter"
  }
====================
```

### Verbose Logging (planned)

```lua
opts = {
  debug = {
    enable = true,
    log_file = vim.fn.stdpath("cache") .. "/gopath.log",
    log_level = "trace",  -- "error", "warn", "info", "debug", "trace"
  },
}
```

---

## Performance Considerations

### Caching

Two distinct caches exist:

1. **Per-buffer `changedtick` caches** in the Lua resolvers (below), to avoid
   recomputing the binding/alias index while a buffer is unchanged.
2. **The persistent filesystem cache** (`gopath.truncated.cache`) that indexes
   the filesystem in the background for fast truncated-path resolution — its
   scan strategy, matching and lifecycle are documented in
   [cache.md](../cache.md).

The `changedtick` pattern:

```lua
-- lua/gopath/resolvers/lua/binding_index.lua

local cache = setmetatable({}, { __mode = "k" })

function M.get_map()
  local buf = 0
  local tick = vim.api.nvim_buf_get_changedtick(buf)

  local entry = cache[buf]
  if entry and entry.tick == tick then
    return entry.map  -- Cache hit
  end

  -- Cache miss: rebuild
  local map = rebuild(buf)
  cache[buf] = { tick = tick, map = map }
  return map
end
```

### LSP Timeout

```lua
opts = {
  lsp_timeout_ms = 200,  -- Balance between speed and reliability
}
```

#### Recommendations:
* **Fast machines**: 100-150ms
* **Normal use**: 200ms (default)
* **Slow LSP servers**: 500ms
* **Patient users**: 1000ms+

### Async Operations

Expensive filesystem searches run **asynchronously** so the UI never blocks.
The synchronous `resolve_at_cursor` pipeline only consults instant sources
(help, env, rtp, `&path`, and the in-memory truncated-path cache). When no
existing file is found, `commands.goto_at_cursor` derives a search tail and
hands it to `tailsearch.resolve_async`, which is cache-first and otherwise runs
a non-blocking libuv directory walk (`finder.find_async`); a single
`"[gopath] Dateisuche läuft…"` message is shown only when that live walk
actually starts, and the buffer opens once a match arrives.

See [resolution.md](../resolution.md) (fast path vs. async search) and
[cache.md](../cache.md) (the cache and live fallback).

---

## Security Considerations

### Path Sanitization

All paths are sanitized before opening, and converted to OS-native separators
via `lib.nvim` (see [`util/cross.lua`](../../lua/gopath/util/cross.lua)):

```lua
-- lua/gopath/open/init.lua

local target = CROSS.to_native(res.path)   -- OS-native separators (lib.nvim)
vim.cmd.edit(vim.fn.fnameescape(target))
```

### External Command Injection

PowerShell commands use proper quoting:

```lua
-- lua/gopath/external/helpers/opener.lua

-- BAD (vulnerable):
-- string.format('Start-Process %s', path)

-- GOOD (safe):
string.format('Start-Process "%s"', path)
```

### User-Provided Resolvers

Custom resolvers run in **protected mode** (`pcall`):

```lua
-- lua/gopath/registry.lua

local ok, result = pcall(resolver.resolve)
if not ok then
  -- Log error, continue with next resolver
end
```

---

## Performance Benchmarks

### Typical Resolution Times

| Scenario | LSP | Treesitter | Builtin |
|----------|-----|------------|---------|
| Lua require() | 15ms | 8ms | 5ms |
| Table field | 20ms | 12ms | N/A |
| File path | N/A | 3ms | 2ms |
| URL | N/A | 1ms | 1ms |

#### Notes:
* LSP times include network latency
* Treesitter times include parsing (cached after first parse)
* Builtin is fastest but least semantic

---

## Contributing Guidelines

### Code Style

* **Annotations**: Full EmmyLua annotations for all functions
* **Naming**: `snake_case` for functions, `SCREAMING_SNAKE_CASE` for constants
* **Modules**: One feature per file, clear responsibilities
* **Comments**: Explain *why*, not *what*

### Pull Request Checklist

- [ ] Code follows style guide
- [ ] EmmyLua annotations added
- [ ] Tested on Linux/macOS/Windows
- [ ] No external dependencies added
- [ ] README updated (if user-facing change)
- [ ] DEV-README updated (if architecture change)

### Testing

```bash
# Manual testing
nvim --clean -u minimal_init.lua test_file.lua

# Run test suite (planned)
make test
```

---

## Additional Resources

### Neovim APIs Used

* `vim.lsp.buf_request_sync()` - LSP requests
* `vim.treesitter.get_node_at_cursor()` - Treesitter queries
* `vim.fn.expand("<cfile>")` - Vim builtin expansion
* `vim.ui.select()` - Native selection UI
* `vim.loop.fs_*()` - Filesystem operations

### External References

* [Neovim LSP Documentation](https://neovim.io/doc/user/lsp.html)
* [Treesitter Documentation](https://neovim.io/doc/user/treesitter.html)
* [Levenshtein Distance Algorithm](https://en.wikipedia.org/wiki/Levenshtein_distance)
* [EmmyLua Annotations](https://github.com/sumneko/lua-language-server/wiki/EmmyLua-Annotations)

---

## License

MIT License - see [LICENSE](../../LICENSE) file for details.

---
