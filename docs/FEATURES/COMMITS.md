# Commits

A commit hash under the cursor opens that commit. Hashes are everywhere:
commit messages, logs, reviews, and the `commits: [repo@sha]` lists and notes
of a task vault.

## What counts as a commit

- A **bare hash**: 7 to 40 hex digits with at least one digit and one letter.
  `deadbeef` (a word) and `12345678` (a number) are not hashes.
- `repo@hash`, the form of the vault (`tasks.nvim@a02ddae`). Behind `repo@`
  the form is explicit, so any 7 to 40 hex digits count.
- `repo@hash1..hash2` resolves as its **first** commit.

Only the form is read while resolving (no git, no process). A file on disk
spelled like the token wins: a path is never taken for a commit. The reading
is `lib.nvim.git.commit_ref`; without it (an older lib.nvim) commits are not
recognised and everything else works as before.

## Where it opens

| Target | Result |
| --- | --- |
| `web` | the commit page of the remote (GitHub, GitLab, Codeberg, or a host named in lib.nvim's `hosts`), in the browser, through the same opener as URLs |
| `float` | `git show` in a floating window |
| `split` / `vsplit` / `tab` | the same in a horizontal split, a vertical split, a new tab |
| `current` | the same in the current window (`q` goes back) |

The view is a scratch buffer: `filetype=git`, read-only, wiped when hidden;
`q` closes it. `gP` (open here) follows `commit.open` (default `"float"`),
`g|`, `g\` and `g}` always use split, vsplit and tab. `<leader>pc`
(`:Gopath commit`) asks where.

## Which repository

`repo@hash` looks for `<root>/<repo>` in `$REPOS_DIR` and `$REPOS_DIR/repos`,
whichever directory the buffer is in. A bare hash uses the repository of the
buffer, then of the current directory.

## A commit the repository lacks

The result is `missing`. gopath offers to **fetch** it (a full hash is
fetched by itself; a short hash cannot be named to a server, so the remote's
branches are fetched) and, when the remote has a known web host, to **open it
on the web** instead. Without a remote URL there is only the fetch offer; an
ambiguous short hash (two commits start with it) and an unknown repository
only produce a message.

## From the diff to the file

In the `git show` view, a `diff --git a/x b/x`, `+++ b/x` or `--- a/x` line
opens the file in the repository. A file the work tree no longer has is read
from the commit instead (`git show <commit>:<path>`; from the commit's parent
when the commit deleted it), into a read-only buffer. That is the decision
for a missing file: the version of the commit, never a prompt to create it.

## Config

```lua
commit = {
  enable = true,    -- commit = false turns it off as well
  open   = "float", -- "float" | "split" | "vsplit" | "tab" | "current" | "web"
}
```
