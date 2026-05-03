---@diagnostic disable: undefined-field

describe("API", function()
  ---@module "tests.checkmate.helpers"
  local h

  ---@module "checkmate.api"
  local api

  ---@module "checkmate.parser"
  local parser

  ---@module "checkmate.util"
  local util

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

  local function lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local function line_count(bufnr)
    return vim.api.nvim_buf_line_count(bufnr)
  end

  ---@param todo_map checkmate.TodoMap
  ---@param pattern string
  ---@return integer
  local function id_by_text(todo_map, pattern)
    local todo = h.exists(h.find_todo_by_text(todo_map, pattern), "todo not found: " .. pattern)
    return todo.id
  end

  local function wait_for_scheduled_move()
    vim.wait(50)
    vim.cmd("redraw")
  end

  describe("same-buffer moves", function()
    it("moves todos by cursor/default source, explicit ids, range/selection, and preserves subtrees", function()
      h.run_test_cases({
        {
          name = "default source under cursor moves to EOF by default",
          content = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task C" }),
          },
          cursor = { 2, 0 },
          action = function(cm)
            cm.move_todos()
          end,
          expected = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task B" }),
          },
        },
        {
          name = "explicit id moves before numeric line-boundary",
          content = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task C" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = { location = 2 },
            })
          end,
          expected = {
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task C" }),
          },
        },
        {
          name = "explicit id moves subtree to EOF",
          content = {
            h.todo_line({ text = "Parent A" }),
            h.todo_line({ indent = 2, text = "Child A1" }),
            h.todo_line({ indent = 2, text = "Child A2" }),
            h.todo_line({ text = "Task B" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Parent A") } },
              destination = { location = line_count(ctx.buffer) },
            })
          end,
          expected = {
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Parent A" }),
            h.todo_line({ indent = 2, text = "Child A1" }),
            h.todo_line({ indent = 2, text = "Child A2" }),
          },
        },
        {
          name = "multiple explicit ids preserve source order and root spacing",
          content = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task D" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = {
                ids = {
                  id_by_text(ctx.todo_map, "Task A"),
                  id_by_text(ctx.todo_map, "Task C"),
                },
              },
              destination = {
                location = line_count(ctx.buffer),
                root_spacing = 1,
              },
            })
          end,
          expected = {
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task D" }),
            h.todo_line({ text = "Task A" }),
            "",
            h.todo_line({ text = "Task C" }),
          },
        },
        {
          name = "visual selection moves selected root todos to EOF",
          content = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ indent = 2, text = "Child B1" }),
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task D" }),
          },
          selection = { 2, 0, 3, 0, "V" },
          action = function(cm)
            cm.move_todos({
              destination = { root_spacing = 0 },
            })
          end,
          expected = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task D" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ indent = 2, text = "Child B1" }),
          },
        },
        {
          name = "visual selection moves selected child todos to EOF",
          content = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ indent = 2, text = "Child B1" }),
            h.todo_line({ indent = 4, text = "Grandchild B1a" }),
            h.todo_line({ indent = 2, text = "Child B2" }),
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task D" }),
          },
          -- select Child B1 and grandchild B1a only
          selection = { 3, 0, 4, 0, "V" },
          action = function(cm)
            cm.move_todos({
              destination = { root_spacing = 0 },
            })
          end,
          expected = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ indent = 2, text = "Child B2" }),
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task D" }),
            h.todo_line({ indent = 2, text = "Child B1" }),
            h.todo_line({ indent = 4, text = "Grandchild B1a" }),
          },
        },
      })
    end)
  end)
end)
