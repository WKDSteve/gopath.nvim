---@module 'gopath.config.DEFAULTS'
---@brief Plugin-side default configuration for gopath.nvim.

---@type GopathOptions
return {
  dev_mode = false,
  mode = "hybrid",
  order = { "lsp", "treesitter", "builtin" },
  lsp_timeout_ms = 200,

  -- Per-filetype resolver configuration.
  -- `enable=false` disables gopath's language resolvers for that filetype
  -- (universal features like file paths and help tags still work).
  -- `custom_resolvers` are user resolvers that run BEFORE the built-in ones.
  languages = {
    lua = { enable = true, resolvers = nil, custom_resolvers = nil },
    python = { enable = true, resolvers = nil, custom_resolvers = nil },
    javascript = { enable = true, resolvers = nil, custom_resolvers = nil },
    javascriptreact = { enable = true, resolvers = nil, custom_resolvers = nil },
    typescript = { enable = true, resolvers = nil, custom_resolvers = nil },
    typescriptreact = { enable = true, resolvers = nil, custom_resolvers = nil },
    rust = { enable = true, resolvers = nil, custom_resolvers = nil },
    go = { enable = true, resolvers = nil, custom_resolvers = nil },
    c = { enable = true, resolvers = nil, custom_resolvers = nil },
    cpp = { enable = true, resolvers = nil, custom_resolvers = nil },
    cs = { enable = true, resolvers = nil, custom_resolvers = nil },
    zig = { enable = true, resolvers = nil, custom_resolvers = nil },
    java = { enable = true, resolvers = nil, custom_resolvers = nil },
  },

  alternate = {
    enable = true,
    similarity_threshold = 75,

    -- Candidates you have chosen from this dialog before rise within their
    -- similarity band. `max_bonus` is that band, in similarity points: 10 on
    -- a 0-100 scale that admits everything from 75 up, so history breaks
    -- near-ties and never inverts a clear winner. 0 disables the reordering
    -- while still recording; `enable = false` disables both.
    frecency = {
      enable = true,
      max_bonus = 10,
      dir = nil, -- default: lib.nvim's own, stdpath("data")/lib.nvim/frecency
    },
  },

  external = {
    enable = true,
    extensions = nil,

    -- PDF handling. Only takes effect when pdfport.nvim is installed;
    -- without it a PDF always goes straight to the system viewer.
    pdf = {
      picker = true, -- false → always open with `default`, no chooser
      default = "system", -- mode used when picker = false
    },

    -- Image handling. Only takes effect when images.nvim is installed;
    -- without it an image always goes straight to the system viewer.
    images = {
      picker = true, -- false -> always open with `default`, no chooser
      default = "system", -- "system"|"show"|"zen", used when picker = false
      optout = false, -- true -> never offer images.nvim, even when installed
    },
  },

  url = {
    enable = true,
    bare_hosts = true,
    schemes = nil,
    tlds = nil,
  },

  env_variable_resolution = {
    enable = true,

    -- Segment-name -> env-var-name map used by :GopathToReposDir /
    -- :Gopath to-repos-dir (the reverse direction). Structural, not literal:
    -- a path whose root segment is "repos" -- E:\repos\.., C:/repos/..,
    -- /repos/.., ~/repos/.., or bare repos/.. -- is rewritten to `$REPOS_DIR`
    -- regardless of drive letter/OS and regardless of what $REPOS_DIR
    -- actually resolves to on this machine.
    shorten_dirs = { repos = "REPOS_DIR" },

    -- Var-name -> absolute-path-string-or-resolver-function map for
    -- "well-known" directories: used by :GopathToNvimDir / :Gopath
    -- to-nvim-dir (rewrites literal occurrences of the directory to `$VAR`)
    -- AND by env_path's forward resolution ($VAR/rest -> absolute path) as
    -- the fallback when neither a lib.nvim.fs.roots root nor a real
    -- environment variable of that name is set. A function is called fresh
    -- each time (needed for stdpath(), only knowable once Neovim is
    -- running). The values are resolved by lib.nvim.fs.roots (opts.extra,
    -- per call): `~`/`$VAR` expanded, relative values refused.
    shorten_known_dirs = {
      NVIM_CONFIG_DIR = function()
        return vim.fn.stdpath("config")
      end,
    },

    -- :GopathToReposDir / :GopathToNvimDir also place a BARE RELATIVE path
    -- that was abbreviated from the middle, e.g.
    -- `team-notes/project.nvim/ROADMAP/ROADMAP.md`: the directory
    -- named by its first segment is searched for below the command's root
    -- (the lib.nvim.fs.roots root of each shorten_dirs variable, or any
    -- shorten_known_dirs entry), and
    -- when the whole path exists there it becomes
    -- `$REPOS_DIR/Notes/team-notes/casedesk.nvim/...`.
    -- `enable = false` turns the search off.
    root_search = {
      enable = true,
      max_depth = 3, -- levels below the root the first segment may sit at
      max_dirs = 4000, -- directories scanned per lookup, at most
    },
  },

  create_on_missing = {
    enable = true,
    confirm = true,
  },

  truncated = {
    enable = true,
    use_cache = true,
    cache_refresh_interval = 600,
    -- How long the per-runtimepath-entry name index stays valid, in ms. Only
    -- a brand-new top-level entry can be hidden by a stale index; lower this
    -- if you install plugins while Neovim is running.
    rtp_index_ttl_ms = 30000,
    max_cache_age = 3600,
    live_search_fallback = true,
    similarity_threshold = 75,
    cache_roots = nil,
    max_depth = 6,
    -- Most file paths one cache build indexes (breadth-first, so the shallow
    -- levels of every root survive). Bounds the size of the cache file and the
    -- startup cost of loading it when a root is huge (e.g. a session started in
    -- %TEMP%); beyond the cap the live search takes over.
    max_paths = 300000,
    excluded_dirs = {
      ".git",
      ".github",
      "node_modules",
      "target",
      "build",
      ".cache",
      "venv",
    },
    watch_patterns = nil,
    auto_rebuild_on_save = false,
  },

  linepath = {
    enable = true,
    cascade = true,
  },

  tailsearch = {
    enable = true,
    max_components = 6,
    ask_on_ambiguous = true,
    roots = nil,
    limit = 100,
  },

  -- A task id (`<area>/<slug>`) under the cursor opens the task file, through
  -- tasks.nvim's `tasks_nvim.resolve`. A soft dependency: without tasks.nvim
  -- this does nothing, says nothing, and gF works as before. `vaults` lists
  -- the vaults to look in (in order); nil means tasks.nvim's configured vault.
  tasks = {
    enable = true,
    vaults = nil,
  },

  -- A commit hash under the cursor (`a02ddae`, `repo@a02ddae`) opens that commit. `open` is where `gP` shows it:
  -- "float" | "split" | "vsplit" | "tab" | "current" (`git show` in a read-only buffer) or "web" (the commit page
  -- of the remote, in the browser). `g|`, `g\` and `g}` pick a split, a vsplit and a tab whatever `open` says.
  commit = {
    enable = true,
    open = "float",
  },

  mappings = {
    open_here = "gP",
    open_split = "g|",
    open_vsplit = "g\\",
    open_tab = "g}",
    open_explorer = "gM",
    open_filetree = "gT",
    copy_location = "gY",
    debug = "g?",
    probe = "<leader>pp",
    check = "gC",
    ask_commit = "<leader>pc",
  },

  commands = {
    resolve = true,
    open = true,
    copy = true,
    debug = true,
    check = true,
    to_repos_dir = true,
    to_nvim_dir = true,
  },

  -- which-key.nvim is a soft dependency: label registration for the
  -- probe keymap is skipped silently when which-key is not installed.
  which_key = true,

  -- One-time "which CLI tools does this plugin want, and why" popup on
  -- first setup() after install (via lib.nvim.deps). false disables it for
  -- this plugin specifically, right here in the spec passed to setup() —
  -- no vim.g needed. See README.
  deps_popup = true,

  -- Which hosts may drive this plugin. `ui_menu = false` keeps ui.nvim's
  -- right-click menu (ui.menu) from composing the Paths entry; `items()` stays
  -- available to any other host.
  integrations = {
    ui_menu = true,
  },
}
