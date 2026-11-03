---@module 'gopath.bindings.keymaps'
--- The keymap preset, declared as named actions.
---
--- Declared through `lib.nvim.bindings.keymap`'s registry rather than bound
--- here by hand. Every key stays an individually overridable config value and
--- `false` still drops just that one, but a wrong *name* is now reported
--- instead of silently binding nothing:
---
---   [lib.nvim.bindings.keymap] gopath: no such keymap action: open_hear
---   (did you mean open_here?)
---
--- `mappings = false` still switches the whole preset off, and every `lhs`
--- still accepts a list -- `open_here = { "gF", "<2-LeftMouse>" }` binds both.

local keymap = require("lib.nvim.bindings.keymap")

local M = {}

--- Declare and bind the preset's actions.
---@param config GopathOptions
---@return Lib.Keymap.Registered[]
function M.setup(config)
  local commands = require("gopath.commands")

  ---@param kind string
  ---@return fun(): nil
  local function open(kind)
    return function()
      commands.goto_at_cursor(kind)
    end
  end

  -- `probe` is the one mapping that lives under the user's <leader> prefix
  -- rather than being a single g-prefixed key, so it is the only one whose
  -- group label which-key cannot work out for itself. The prefix is derived
  -- only when `probe` is actually configured, so the label never lands on a
  -- group the user does not use -- and `config.which_key = false` opts out of
  -- the label while leaving every mapping (and its own desc) in place.
  local prefix, group
  local probe = config.mappings and config.mappings.probe
  local probe_lhs = type(probe) == "table" and probe[1] or probe
  if config.which_key ~= false and type(probe_lhs) == "string" then
    prefix = probe_lhs:match("^(<leader>.)%a$")
    if prefix then group = { group = "gopath", mode = { "n", "v" } } end
  end

  ---@type Lib.Keymap.Spec
  local spec = {
    prefix = prefix,
    which_key = group,
    order = {
      "open_here",
      "open_split",
      "open_vsplit",
      "open_tab",
      "open_explorer",
      "open_filetree",
      "copy_location",
      "debug",
      "check",
      "ask_commit",
      "probe",
    },
    actions = {
      open_here = { default = "gP", rhs = open("edit"), desc = "open here" },
      open_split = { rhs = open("window"), desc = "open in split" },
      open_vsplit = { rhs = open("vsplit"), desc = "open in vsplit" },
      open_tab = { rhs = open("tab"), desc = "open in tab" },
      open_explorer = { rhs = open("explorer"), desc = "reveal in file explorer" },
      open_filetree = { rhs = open("filetree"), desc = "reveal in filetree.nvim (soft dependency)" },

      copy_location = {
        rhs = function()
          commands.copy_location()
        end,
        desc = "copy path:line:col",
      },

      debug = {
        rhs = function()
          commands.debug_under_cursor()
        end,
        desc = "debug under cursor",
      },

      -- Reports whether the path under the cursor exists, and offers to
      -- create it when it does not.
      check = {
        rhs = function()
          commands.check_under_cursor()
        end,
        desc = "check path exists / offer create",
      },

      -- A commit hash under the cursor, opened where the user picks.
      ask_commit = {
        rhs = function()
          commands.ask_commit()
        end,
        desc = "open commit under cursor (choose where)",
      },

      -- Suffix-based search. Same key in both modes, same intent, different
      -- source for the text -- so one action with two binds.
      probe = {
        binds = {
          {
            mode = "n",
            desc = "probe path under cursor (vsplit)",
            rhs = function()
              commands.probe_selection({ open_cmd = "vsplit", ask = true })
            end,
          },
          {
            mode = "v",
            desc = "probe selected path (vsplit)",
            rhs = function()
              -- Leave Visual mode first so the '< '> marks are set.
              vim.api.nvim_feedkeys(
                vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
                "x",
                false
              )
              vim.schedule(function()
                -- selection = true because this mapping only ever fires from
                -- Visual mode. The callee cannot infer that itself: the <Esc>
                -- above (and the schedule) mean Visual mode is already over by
                -- the time it runs.
                commands.probe_selection({
                  open_cmd = "vsplit",
                  ask = true,
                  selection = true,
                })
              end)
            end,
          },
        },
      },
    },
  }

  return keymap.register("gopath", spec, config.mappings)
end

return M
