---@meta
---@module 'gopath.@types.config'

---@class GopathKeymaps
---@field open_here string|string[]|false Default: "gP"
---@field open_split string|string[]|false Default: "g|"
---@field open_vsplit string|string[]|false Default: "g\\"
---@field open_tab string|string[]|false Default: "g}"
---@field open_explorer string|string[]|false Default: "gM"
--- Reveal the resolved path in the OS file manager (Explorer/Finder/…)
--- instead of opening a buffer for it.
---@field open_filetree string|string[]|false Default: "gT"
--- Reveal the resolved path in filetree.nvim's own tree instead of opening a
--- buffer for it (soft dependency -- warns if filetree.nvim isn't installed
--- or hasn't completed setup()).
---@field copy_location string|string[]|false Default: "gY"
---@field debug string|string[]|false Default: "g?"
---@field probe string|string[]|false Default: "<leader>pp" (n + v mode)
---@field ask_commit string|string[]|false Default: "<leader>pc". Open the commit under the cursor, asking where (web, float, split, vsplit, tab, current).
---@field check string|string[]|false Default: "gC"
--- Check-only: resolve the path under cursor, report whether it exists, and
--- (if missing) offer to create it — without going through open_here/etc.
--- Always offers, even when `create_on_missing.enable = false` (explicit
--- user action overrides the passive opt-out).

---@class GopathCommands
---@field resolve boolean Default: true (creates :GopathResolve)
---@field open boolean Default: true (creates :GopathOpen)
---@field copy boolean Default: true (creates :GopathCopy)
---@field debug boolean Default: true (creates :GopathDebug)
---@field check boolean Default: true (creates :GopathCheck)
---@field to_repos_dir boolean Default: true (creates :GopathToReposDir)
---@field to_nvim_dir boolean Default: true (creates :GopathToNvimDir)

---@class GopathAlternateOptions
---@field enable boolean Default: true
---@field similarity_threshold number Default: 75 (0-100)
---@field frecency? GopathAlternateFrecency Order candidates by what was chosen before

--- Frequency x recency ordering for the alternate list, on top of similarity.
--- Backed by `lib.nvim.frecency` on its own namespace — the same
--- implementation `pickers.nvim` ranks files with, deliberately not the same
--- store: a path opened often in a picker says nothing about which alternate
--- was meant here.
---@class GopathAlternateFrecency
---@field enable boolean Default: true. False records nothing and reorders nothing.
---@field max_bonus number Default: 10. The ceiling of the bonus, in similarity points — history breaks near-ties within a band and never inverts a clear winner. 0 keeps recording but stops reordering.
---@field dir? string|nil Override the storage directory (default: `lib.nvim.frecency`'s own, `stdpath("data")/lib.nvim/frecency`).

---@alias GopathPdfMode "system"|"buffer"|"float"|"terminal"

---@class GopathPdfOptions
---@field picker boolean Default: true.
--- Show a chooser (System app / Buffer / Float / Terminal) when opening a PDF.
--- Requires pdfport.nvim; without it a PDF always goes to the system viewer and
--- no chooser appears. Set false to always use `default` instead.
---@field default GopathPdfMode Default: "system".
--- Mode used when `picker = false`. "system" preserves the pre-pdfport
--- behaviour; the other three are pdfport.nvim renderers.

---@class GopathExternalOptions
---@field enable boolean Default: true
---@field extensions string[]|nil Default: nil. Extends (does not replace) the built-in extension list.
---@field pdf GopathPdfOptions PDF-specific opening (pdfport.nvim integration)

---@class GopathUrlOptions
---@field enable? boolean Default: true. Recognise URLs under the cursor and open them externally.
---@field bare_hosts? boolean Default: true.
--- Also accept scheme-less targets — `github.com/neovim/neovim`,
--- `git@github.com:foo/bar.git` — which are normalized to `https://…`.
--- These only win after every file resolver has failed, so a real file of the
--- same name always takes precedence. Set to false to require an explicit
--- scheme (or a `www.` prefix).
---@field schemes string[]|nil Default: nil. Extends (does not replace) the built-in scheme list.
---@field tlds string[]|nil Default: nil. Extends (does not replace) the built-in TLD list used by `bare_hosts`.

---@class GopathLanguageOptions
---@field enable boolean Default: true
---@field resolvers string[]|nil Default: nil (all available resolvers). Whitelist of resolver names to run for this filetype.
---@field custom_resolvers CustomResolver[]|nil
--- User-supplied resolvers run BEFORE the built-in ones for this filetype.
--- Each entry is either a table implementing `resolve(): GopathResult|nil`
--- or a string module name that returns such a table when required.

---@class GopathTruncated
---@field enable boolean Default: true
---@field use_cache boolean
---@field cache_refresh_interval number Refresh every 10 minutes
---@field rtp_index_ttl_ms number How long the runtimepath name index stays valid, in ms (default 30000)
---@field max_cache_age number Consider cache stale after 1 hour
---@field live_search_fallback boolean Use fd/rg/find if cache misses
---@field similarity_threshold number For multiple match selection
---@field cache_roots table|nil
---@field max_depth number Maximum directory depth to scan
---@field max_paths number Most file paths one cache build indexes (default 300000)
---@field excluded_dirs string[]|nil Directories to skip
---@field watch_patterns string[]|nil
---@field auto_rebuild_on_save boolean

---@class GopathLinepath
---@field enable boolean Default: true. Scan the whole current line for path-like candidates.
---@field cascade boolean Default: true. Run linepath inside the resolve pipeline.

---@class GopathTailsearch
---@field enable boolean Default: true. Resolve path tails via cache + filesystem suffix search.
---@field max_components integer Default: 6. Longest path suffix (in components) to try.
---@field ask_on_ambiguous boolean Default: true. Show vim.ui.select when several files match.
---@field roots string[]|nil Default: nil (auto: bufdir, cwd, git root, stdpath dirs).
---@field limit integer Default: 100. Maximum matches collected per search.

---@class GopathCommit
---@field enable boolean Default: true. Resolve a commit hash (`a02ddae`, `repo@a02ddae`) under the cursor.
---@field open "float"|"split"|"vsplit"|"tab"|"current"|"web" Default: "float". Where `gP` shows the commit.

---@class GopathTasks
---@field enable boolean Default: true. Resolve a task id under the cursor through tasks.nvim; a no-op without it.
---@field vaults string[]|nil Default: nil (tasks.nvim's configured vault). Vaults to look in, in order.

---@class GopathEnvVariableResolution
---@field enable boolean
--- When true, tokens starting with $VAR or ${VAR} are expanded
--- using the current process environment before file resolution.
--- Applies to all filetypes. Default: true.
---@field shorten_dirs? table<string, string> Segment-name -> env-var-name map for :GopathToReposDir. Default: { repos = "REPOS_DIR" }.
---@field shorten_known_dirs? table<string, string|(fun(): string)> Var-name -> directory (or resolver) map for :GopathToNvimDir. Default: { NVIM_CONFIG_DIR = stdpath("config") }.
---@field root_search? GopathRootSearch Locate bare relative paths below the shorten roots. Default: enabled.

---@class GopathRootSearch
---@field enable? boolean Default: true. Let :GopathToReposDir / :GopathToNvimDir prefix a bare relative path (`team-notes/proj/README.md`) found below a root.
---@field max_depth? integer Default: 3. How many directory levels below a root the path's first segment may sit.
---@field max_dirs? integer Default: 4000. Upper bound on directories scanned per lookup.

---@class GopathCreateOnMissing
---@field enable boolean Default: true.
--- When a resolved path does not exist (and the fuzzy-alternate / nearest-folder
--- fallbacks also fail to find something), offer to create it instead of just
--- reporting "File not found". Set to false to restore the old error-only
--- behaviour for the passive open keymaps (the dedicated `check` keymap still
--- offers to create, since that is an explicit user action).
---@field confirm boolean Default: true.
--- Ask "create '<path>'?" via vim.ui.select before creating. Set to false to
--- create missing files silently (no prompt) whenever offered.

---@class GopathIntegrationsOptions
---@field ui_menu? boolean Default: true. Let ui.nvim's right-click menu (`ui.menu`) compose the "Paths" entry.

---@class GopathOptions
---@field dev_mode? boolean # Print debug notifies
---@field mode? "builtin"|"treesitter"|"lsp"|"hybrid" Default: "hybrid"
---@field order? string[] Default: { "lsp", "treesitter", "builtin" }
---@field lsp_timeout_ms? integer Default: 200
---@field languages? table<string, GopathLanguageOptions> Language-specific configuration
---@field alternate? GopathAlternateOptions Fuzzy alternate resolution
---@field external? GopathExternalOptions External file opening
---@field url? GopathUrlOptions URL recognition (gF on a link opens the browser)
---@field env_variable_resolution? GopathEnvVariableResolution Expand $VAR prefixes in paths
---@field create_on_missing? GopathCreateOnMissing Offer to create missing files instead of erroring
---@field mappings? GopathKeymaps|false Keymaps (false = disable all)
---@field commands? GopathCommands|false User commands (false = disable all)
---@field which_key? boolean Default: true. Label the probe keymap via which-key.nvim, if installed.
---@field integrations? GopathIntegrationsOptions Which hosts may drive this plugin (`ui_menu`).
---@field deps_popup? boolean Default: true. Show the lib.nvim.deps "declared tools" popup once, ever, on first setup() after install (needs lib.nvim.deps — a no-op without it).
---@field truncated? GopathTruncated
---@field linepath? GopathLinepath Whole-line path extraction
---@field tailsearch? GopathTailsearch Cache + filesystem suffix search
---@field commit? GopathCommit|false Commit hashes under the cursor open the commit (`git show` view or web page)
---@field tasks? GopathTasks Task ids (`<area>/<slug>`) open their task file, through tasks.nvim (soft dependency)
