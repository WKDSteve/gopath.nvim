-- TESTS/sheets/features.lua -- the functionalities of gopath.nvim as its user meets them; `testing sheets report`
-- says which ones have a feature sheet (`feature = "<id>"`) and in which state, and K16 warns about a sheet that names
-- an id not listed here. Data: read with an empty environment like a sheet (testing.nvim docs/SHEETS.md).
-- The list follows docs/FEATURES/ (README.md and its pages) and ALL/manual-test-checklists/gopath.md.
return {
  {
    id = "gopath.open",
    title = "gF, g|, g\\, g} and :Gopath open open the file under the cursor in place, in a split or in a tab",
    surface = { "command:Gopath open" },
    docs = "docs/FEATURES/NAVIGATION.md",
  },
  {
    id = "gopath.resolve",
    title = "gF resolves identifiers, table chains, config values, paths in comments and strings, and help tags",
    docs = "docs/FEATURES/LANGUAGES.md",
  },
  {
    id = "gopath.whole-line",
    title = "A path anywhere on the line is found, with path:line:col from stack traces",
    docs = "docs/FEATURES/NAVIGATION.md",
  },
  {
    id = "gopath.fuzzy",
    title = "When the exact file does not exist, similar names are offered",
    docs = "docs/FEATURES/NAVIGATION.md",
  },
  {
    id = "gopath.probe",
    title = "<leader>pp and :Gopath probe find the token or the selection by its suffix",
    surface = { "command:Gopath probe" },
    docs = "docs/FEATURES/NAVIGATION.md",
  },
  {
    id = "gopath.check",
    title = "gC and :Gopath check report whether the path exists and offer to create a missing one",
    surface = { "command:Gopath check" },
    docs = "docs/FEATURES/NAVIGATION.md",
  },
  {
    id = "gopath.info",
    title = "g? reports how the path under the cursor resolves, gY copies path:line:col",
    surface = { "command:Gopath debug", "command:Gopath copy" },
    docs = "docs/FEATURES/NAVIGATION.md",
  },
  {
    id = "gopath.cache",
    title = "A background index of the roots resolves truncated paths; :Gopath cache builds, reports and grows it",
    surface = {
      "command:Gopath cache build",
      "command:Gopath cache info",
      "command:Gopath cache add-root",
    },
    docs = "docs/FEATURES/CACHE.md",
  },
  {
    id = "gopath.shorten",
    title = ":Gopath to-repos-dir and to-nvim-dir rewrite a path on the line or in the selection to $VAR",
    surface = { "command:Gopath to-repos-dir", "command:Gopath to-nvim-dir" },
    docs = "docs/FEATURES/NAVIGATION.md",
  },
  {
    id = "gopath.reveal",
    title = "gM reveals the resolved file in the file manager, gT in filetree.nvim, without opening a buffer",
    docs = "docs/FEATURES/EXTERNAL.md",
  },
  {
    id = "gopath.external",
    title = "Images, PDFs and other media open in their external application, URLs in the browser",
    docs = "docs/FEATURES/EXTERNAL.md",
  },
  {
    id = "gopath.commits",
    title = "gF on a commit hash (or repo@hash) opens it in git show, offers to fetch a missing one; diff lines lead to the file",
    docs = "docs/FEATURES/COMMITS.md",
  },
  {
    id = "gopath.hover",
    title = "hover.nvim previews the path under the cursor through gopath",
    docs = "docs/FEATURES/INTEGRATIONS.md",
  },
  {
    id = "gopath.context-menu",
    title = "The right-click menu has a Paths entry for the path under the cursor",
    docs = "docs/FEATURES/INTEGRATIONS.md",
  },
}
