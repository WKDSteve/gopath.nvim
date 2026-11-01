# Configuration

Full `setup()` option reference for gopath.nvim, with defaults and inline
comments. For deep dives into specific subsystems, see the
[Documentation index](./README.md) (cache/truncated-path resolution,
resolution pipeline, Lua symbol resolution, keymap/command cheatsheet).

```lua
require("gopath").setup({
  -- Resolution mode: "hybrid" | "lsp" | "treesitter" | "builtin"
  mode  = "hybrid",
  order = { "lsp", "treesitter", "builtin" },
  lsp_timeout_ms = 200,

  -- Language-specific resolvers
  languages = {
    lua = { enable = true },
  },

  -- Whole-line path extraction (Phase 3.5)
  linepath = {
    enable = true,
  },

  -- Suffix-based filesystem search
  tailsearch = {
    enable           = true,
    max_components   = 6,       -- number of trailing path segments to try
    ask_on_ambiguous = true,    -- show vim.ui.select when multiple matches
    roots            = nil,     -- nil = auto: bufdir→cwd→git root→stdpaths
    limit            = 100,     -- max files returned per root
  },

  -- A task id (`<area>/<slug>`) under the cursor opens its task file, through
  -- tasks.nvim (soft dependency: without it nothing happens and the id is read
  -- as a path). Only an id a vault knows counts. Several targets (an open and a
  -- finished task of one slug, the id in two vaults) are offered to pick from
  -- by gF, `:Gopath open` and the context menu's Open and Reveal. `tasks = false`
  -- turns it off like `enable = false`.
  tasks = {
    enable = true,
    vaults = nil,  -- string[]: vaults to look in, in order (`~`, $VAR and ${VAR}
                   -- expanded; a relative entry is relative to the cwd);
                   -- nil = tasks.nvim's own (setup({ vault }) or $TASKS_VAULT)
  },

  -- Fuzzy alternate when file not found
  alternate = {
    enable               = true,
    similarity_threshold = 75,  -- 0-100; higher = stricter

    -- Candidates you have chosen from this dialog before rise within their
    -- similarity band. max_bonus is that band, in similarity points -- 10 on
    -- a 0-100 scale admitting everything from 75 up, so history breaks
    -- near-ties and never inverts a clear winner. 0 keeps recording but stops
    -- reordering; enable = false does neither.
    frecency = {
      enable    = true,
      max_bonus = 10,
      dir       = nil,  -- nil = lib.nvim's own, stdpath("data")/lib.nvim/frecency
    },
  },

  -- External file opener (images, PDFs, Office files, archives, media, mail
  -- files .msg/.eml/.oft — the last open in the mail client, never as a
  -- binary buffer)
  external = {
    enable     = true,
    extensions = nil,  -- string[] of extra extensions, EXTENDS the built-in list
                       -- (also makes those extensions findable in a line, so a
                       --  Markdown link to one resolves like any other path)

    -- PDF handling. Only has an effect when pdfport.nvim is installed;
    -- without it a PDF always goes straight to the system viewer.
    pdf = {
      picker  = true,      -- chooser: System app / Buffer / Float / Terminal
                           -- ("System app" is first — it's the exception case,
                           --  so it stays one keystroke away)
      default = "system",  -- mode used when picker = false
                           -- "system"|"buffer"|"float"|"terminal"
    },
  },

  -- URLs under the cursor open in the browser instead of resolving to a file
  url = {
    enable     = true,
    bare_hosts = true,  -- also accept "github.com/x" / "git@github.com:a/b.git";
                        -- these only win after every file resolver missed
    schemes    = nil,   -- string[] of extra URL schemes, EXTENDS the built-in list
    tlds       = nil,   -- string[] of extra TLDs for bare_hosts, EXTENDS the built-in list
  },

  -- $VAR / ${VAR} prefix expansion
  env_variable_resolution = {
    enable = true,

    -- Segment-name -> env-var-name map for the REVERSE direction:
    -- :GopathToReposDir / :Gopath to-repos-dir rewrite an absolute path on
    -- the current line whose root segment matches a key here (any drive
    -- letter, any OS -- E:\repos\.., /repos/.., ~/repos/.., bare repos/..)
    -- into `$<value>`. Structural, not literal: it does NOT check what the
    -- named var actually resolves to on this machine.
    shorten_dirs = { repos = "REPOS_DIR" },

    -- Var-name -> absolute-path-string-or-resolver-function map for
    -- "well-known" directories -- no real environment variable needs to be
    -- set for these. Two uses: :GopathToNvimDir / :Gopath to-nvim-dir
    -- rewrite LITERAL occurrences of the resolved directory (not a bare
    -- folder name -- avoids false positives) back to `$<key>`; and the
    -- forward $VAR resolver above falls back here when neither a root of
    -- lib.nvim's registry (lib.nvim.fs.roots) nor a real environment
    -- variable of that name is set. A function is called fresh each time --
    -- needed for stdpath(), only known once Neovim is running.
    -- The values are resolved by that registry (passed per call, nobody
    -- else sees them): a leading `~`, `$VAR` or `%VAR%` is expanded; a
    -- relative path (on Windows also `/x`, which means "on the current
    -- drive"), the filesystem root and a bare drive are refused, and so are
    -- names other than letters, digits and `_`. A root of the same name in
    -- your own `require("lib.nvim.fs.roots").setup({ extra = ... })` wins.
    shorten_known_dirs = {
      NVIM_CONFIG_DIR = function()
        return vim.fn.stdpath("config")
      end,
    },

    -- Both reverse commands also place a BARE RELATIVE path that was
    -- abbreviated from the middle -- e.g.
    -- `team-notes/project.nvim/ROADMAP/ROADMAP.md`: the directory
    -- named by its first segment is searched for below the command's root
    -- (the registry's root for each `shorten_dirs` variable -- your own
    -- root of that name, else the environment variable -- / the known dir),
    -- and when the WHOLE path exists there it becomes
    -- `$REPOS_DIR/Notes/team-notes/casedesk.nvim/...`.
    -- URLs, `./`-paths and `$VAR` paths are never touched. A variable with
    -- no usable root on this machine has nothing to search under.
    root_search = {
      enable = true,
      max_depth = 3, -- levels below the root the first segment may sit at
      max_dirs = 4000, -- directories scanned per lookup, at most
    },
  },

  -- Offer to create a resolved-but-missing file instead of just erroring
  -- (gP/g|/g\/g}). `gC` / :GopathCheck always offer, regardless of `enable`.
  -- Dialog: ui.nvim's ui.kit.confirm, falling back to vim.ui.select.
  create_on_missing = {
    enable  = true,
    confirm = true,  -- false = create silently, no dialog
  },

  -- Truncated path cache ("..." prefix paths) — see docs/cache.md
  truncated = {
    enable                 = true,
    use_cache              = true,
    cache_refresh_interval = 600,   -- seconds between auto-refreshes
    -- How long the per-runtimepath-entry name index stays valid, in ms. Only
    -- a brand-new top-level entry can be hidden by a stale index; lower this
    -- if you install plugins while Neovim is running.
    rtp_index_ttl_ms = 30000,
    max_cache_age          = 3600,  -- seconds before cache is considered stale
    live_search_fallback   = true,
    similarity_threshold   = 75,
    cache_roots            = nil,   -- nil = auto-detect drives/stdpaths
    max_depth              = 6,
    max_paths              = 300000, -- most files one cache build indexes
    excluded_dirs          = { ".git", ".github", "node_modules", "target", "build", ".cache", "venv" },
    auto_rebuild_on_save   = false,
    -- Which saves rebuild the cache when auto_rebuild_on_save is on. DEFAULTS.lua holds nil here and
    -- bindings/autocmds.lua applies { "*.lua", "*.vim" }, so that is the effective default.
    watch_patterns         = nil,   -- nil = { "*.lua", "*.vim" }
  },

  -- Keymaps (false = disabled, string | string[] = key(s))
  mappings = {
    open_here     = "gP",
    open_split    = "g|",
    open_vsplit   = "g\\",
    open_tab      = "g}",
    open_explorer = "gM",  -- reveal in system file manager instead of opening
    open_filetree = "gT",  -- reveal in filetree.nvim instead of opening (soft dep)
    copy_location = "gY",
    debug         = "g?",
    check         = "gC",
    probe         = "<leader>pp",  -- n + v mode
  },

  -- User commands (false = all disabled; individual keys = false to skip)
  commands = {
    resolve = true,
    open    = true,
    copy    = true,
    debug   = true,
    check   = true,
    to_repos_dir = true,
    to_nvim_dir  = true,
  },

  -- Label the probe keymap via which-key.nvim, if installed (no-op otherwise)
  which_key = true,

  -- Which hosts may drive this plugin: `ui_menu = false` keeps ui.nvim's
  -- right-click menu (ui.menu) from composing the "Paths" entry.
  integrations = {
    ui_menu = true,
  },
})
```
