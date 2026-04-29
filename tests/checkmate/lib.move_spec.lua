describe("API", function()
  local tx = require("checkmate.transaction")
  local Heading = require("checkmate.lib.heading")
  local Move = require("checkmate.lib.move")

  ---@module "tests.checkmate.helpers"
  local h

  ---@module "checkmate.api"
  local api

  ---@module "checkmate.parser"
  local parser

  ---@type {unchecked: string, checked: string, pending: string}
  local m -- markers

  lazy_setup(function()
    -- Hide nvim_echo from polluting test output
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()
  end)

  before_each(function()
    _G.reset_state()

    h = require("tests.checkmate.helpers")
    api = require("checkmate.api")
    parser = require("checkmate.parser")
    util = require("checkmate.util")

    m = {
      unchecked = h.get_unchecked_marker(),
      checked = h.get_checked_marker(),
      pending = h.get_pending_marker(),
    }

    h.ensure_normal_mode()
  end)

  describe("move_todos", function()
    it("test", function()
      h.run_test_cases({
        {
          name = "move single completed todo in same buffer",
          content = {
            "- " .. m.checked .. " Task A",
            "- " .. m.unchecked .. " Task B",
          },
          cursor = { 1, 0 },
          action = function(_, ctx) end,
          wait_ms = 10,
          assert = function(_, lines, ctx)
            assert.matches("## HERE", lines[3])
            assert.matches("Task A", lines[5])
          end,
        },
      })
    end)
  end)
end)
