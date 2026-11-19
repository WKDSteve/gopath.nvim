-- gF on a commit hash in a note of a repository: the commit opens in `git show` (a float), a diff line of that view
-- leads to the file, a file the work tree no longer has is read from the commit, and a commit the clone lacks is
-- fetched from its remote after the offer. git is real throughout; the remote is a second repository beside the
-- clone (a path, no network), so it has no web URL and the offer is just "fetch".
-- The selector is a recording stand-in for vim.ui.select (the real config shows ui.kit's): the sheet answers it the
-- way a person picks an entry. The browser for the "web" choice is not reached here (gopath.external).
return {
  id = "gopath.commits",
  feature = "gopath.commits",
  title = "gopath.nvim: gF on a hash shows the commit, leads to its files, and fetches a missing one",
  sizes = { { rows = 30, cols = 100 } },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.setup()
      -- up: c1 adds a.txt and old.txt, c2 removes old.txt; work is cloned from it; then up gets c3
      _G.write("up/a.txt", { "alpha", "one" })
      _G.write("up/old.txt", { "the old file", "only in c1" })
      _G.git("up", { "init", "-q" })
      _G.git("up", { "add", "." })
      _G.git("up", { "commit", "-q", "-m", "c1: a.txt and old.txt" })
      _G.C1 = _G.git("up", { "rev-parse", "HEAD" })
      _G.git("up", { "rm", "-q", "old.txt" })
      _G.git("up", { "commit", "-q", "-m", "c2: old.txt goes" })
      _G.git("", { "clone", "-q", "up", "work" })
      _G.write("up/a.txt", { "alpha", "three" })
      _G.git("up", { "commit", "-q", "-am", "c3: a.txt again" })
      _G.C3 = _G.git("up", { "rev-parse", "HEAD" })
      _G.write("work/NOTES.md", { "first " .. _G.C1:sub(1, 10), "later " .. _G.C3:sub(1, 10) })
      vim.cmd.edit(vim.fn.fnameescape(_G.DIR .. "/work/NOTES.md"))
      -- the selector: remembers what it was asked; a step answers
      vim.ui.select = function(items, opts, on_choice)
        _G.ASKED = { items = items, prompt = opts and opts.prompt or "", on_choice = on_choice }
      end
      _G.shows = function(text)
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find(text, 1, true) ~= nil
      end]],
      note = "a repository up with three commits, a clone work that has the first two, a note in work naming c1 and c3",
    },

    { lua = [[vim.api.nvim_win_set_cursor(0, { 1, 8 })]], note = "the cursor on the hash of c1" },
    { keys = "gF", note = "gF: the commit opens in git show, in a float" },
    {
      wait = [[_G.dialog() and vim.api.nvim_buf_get_name(0):find("gopath://commit/work/", 1, true) ~= nil
        and _G.shows("c1: a.txt and old.txt") and _G.shows("diff --git a/old.txt b/old.txt")]],
      timeout = 10000,
    },
    {
      expect = [[vim.bo.filetype == "git" and not vim.bo.modifiable]],
      note = "a read-only git buffer",
    },

    {
      lua = [[vim.fn.search("^+++ b/old.txt")]],
      note = "the cursor on the diff line of old.txt, which the work tree no longer has",
    },
    { keys = "gF", note = "gF: the file is read from the commit" },
    {
      wait = [[vim.api.nvim_buf_get_name(0):find("gopath://commit-file/", 1, true) ~= nil and _G.shows("only in c1")]],
      timeout = 10000,
    },
    {
      expect = [[vim.bo.readonly and not vim.bo.modifiable]],
      note = "read-only: the version of the commit",
    },

    {
      lua = [[vim.cmd("silent! only!")
      vim.cmd.edit(vim.fn.fnameescape(_G.DIR .. "/work/NOTES.md"))
      vim.api.nvim_win_set_cursor(0, { 2, 8 })]],
      note = "back in the note, the cursor on the hash of c3, which work lacks",
    },
    { keys = "gF", note = "gF: the commit is missing, gopath offers to fetch it" },
    { wait = [[_G.ASKED ~= nil]], timeout = 10000 },
    {
      expect = [[#_G.ASKED.items == 1 and _G.ASKED.items[1] == "fetch" and _G.ASKED.prompt:find("is not in work", 1, true)]],
      note = "only the fetch offer: the remote is a path, it has no web page",
    },
    { lua = [[_G.ASKED.on_choice("fetch")]], note = "the user picks Fetch it from the remote" },
    {
      wait = [[_G.dialog() and _G.shows("c3: a.txt again")]],
      timeout = 15000,
      note = "fetched from up, then shown like any other commit",
    },
    { expect = [[_G.noted("fetching")]], note = "it said it was fetching" },
  },
  manual = {
    "gF on a hash of a repository with a GitHub remote: the offer has 'Open it on the web instead', which opens the commit page",
  },
}
