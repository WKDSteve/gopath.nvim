# Features

gopath.nvim resolves symbols, `require()` paths, and arbitrary file
references under your cursor through a multi-phase pipeline — LSP →
Treesitter → whole-line extraction → suffix search → fuzzy alternate — so
one keypress takes you to the right file, at the right line, however the
reference is written. See the [project README](../../README.md) for
install/quickstart, or the [documentation index](../README.md) for deep
dives into individual subsystems (`resolution.md`, `cache.md`,
`lua-symbols.md`).

- [Navigation](NAVIGATION.md) — the resolution pipeline, whole-line
  extraction, suffix search, visual probe, fuzzy alternates, and
  create-on-missing.
- [Language support](LANGUAGES.md) — Lua-specific resolution and the
  universal (any-filetype) resolvers.
- [Filesystem cache](CACHE.md) — the truncated-path index that makes
  suffix search fast on large trees.
- [Commits](COMMITS.md) — a commit hash under the cursor opens the commit
  (`git show` view or web page), fetches it when missing, and jumps from a
  diff line to the file.
- [External files](EXTERNAL.md) — opening non-text files in the system
  default application.
- [Integrations](INTEGRATIONS.md) — the plugins that call
  `resolve_at_cursor` from outside this repository, and what they rely on.
