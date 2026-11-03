# What you get with the defaults

| Key | Does |
| --- | --- |
| `gP` | Resolve and open in the current window |
| `g\|` / `g\` / `g}` | The same, in a horizontal split, a vertical split, a new tab |
| `gM` | Reveal the target in the system file manager instead of opening it |
| `gT` | Reveal the target in filetree.nvim's own tree instead of opening it (soft dependency) |
| `gY` | Copy `path:line:col` to the clipboard |
| `gC` | Check the path under the cursor exists; offer to create it if not |
| `g?` | Print the resolution chain to `:messages` — the first thing to try when a jump goes somewhere odd |
| `<leader>pc` | Open the commit hash under the cursor, asking where (`gP` on a hash opens it in a float) |
| `<leader>pp` | Probe the path under the cursor, or the selection, in a vertical split |

Set any config key to `false` to disable a single mapping, or
`mappings = false` for all of them. The full set, including the `:Gopath`
subcommand tree and its legacy `:GopathX` aliases, is the
[bindings cheatsheet](BINDINGS.md).
