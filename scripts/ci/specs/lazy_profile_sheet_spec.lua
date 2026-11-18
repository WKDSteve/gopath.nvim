-- scripts/ci/specs/lazy_profile_sheet_spec.lua
-- TESTS/sheets/lazy-profile.sheet.lua bounds a load-adjusted start time. The sheet itself runs only against the
-- installed config (a skip on the CI), so the adjustment it computes is pinned here: its expression is evaluated
-- with lazy.nvim's two tables replaced.

---@param H table
return function(H)
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
  local sheet = dofile(root .. "/TESTS/sheets/lazy-profile.sheet.lua")

  ---@param name string
  ---@return table
  local function step(name)
    for _, s in ipairs(sheet.steps) do
      if s.name == name then return s end
    end
    error("no measure step " .. name)
  end

  ---@param expr string
  ---@param load_ms number
  ---@param startup_ms number
  ---@param busy number share of all cores busy, 0..1
  ---@return number
  local function adjusted(expr, load_ms, startup_ms, busy)
    local value
    _G.GOPATH_BUSY = busy
    H.with_modules({
      ["lazy.core.config"] = {
        plugins = { ["gopath.nvim"] = { _ = { loaded = { time = load_ms * 1e6 } } } },
      },
      lazy = {
        stats = function()
          return { startuptime = startup_ms }
        end,
      },
    }, function()
      value = assert(loadstring("return " .. expr))()
    end)
    _G.GOPATH_BUSY = nil
    return value
  end

  H.check("lazy-profile: the bound applies to a value adjusted only on a busy machine", function()
    for _, name in ipairs({
      "gopath (VeryLazy) load-adjusted",
      "gopath (VeryLazy) index on disk load-adjusted",
    }) do
      local m = step(name).measure
      H.eq(step(name).max, 120, name .. ": the bound")
      H.eq(adjusted(m, 76, 900, 0.1), 76, "a quick start on a quiet machine: the raw value")
      H.eq(adjusted(m, 150, 900, 0.1), 150, "a doubling on a quiet machine stays above the bound")
      H.eq(adjusted(m, 240, 4000, 0.1), 240, "a slow start on a quiet machine loosens nothing")
      H.eq(adjusted(m, 240, 4000, 0.9), 120, "a slow start on a busy machine halves it")
      H.eq(adjusted(m, 973, 40000, 1), 973 * 0.1, "the factor stops at 0.1")
    end
    H.truthy(
      step("machine busy").measure:find("cpu_info", 1, true),
      "the busy share is sampled in the child"
    )
  end)
end
