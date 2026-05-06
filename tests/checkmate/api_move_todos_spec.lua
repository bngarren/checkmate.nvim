---@diagnostic disable: undefined-field

local heading = require("checkmate.lib.heading")

describe("API/move_todos", function()
  ---@module "tests.checkmate.helpers"
  local h

  ---@module "checkmate.api"
  local api

  ---@module "checkmate.parser"
  local parser

  ---@module "checkmate.util"
  local util

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
    vim.wait(10)
    vim.cmd("redraw")
  end

  describe("same-buffer moves", function()
    it("should move todos by cursor/default source, explicit ids, range/selection, and preserves subtrees", function()
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

    it("should move todos into heading destinations", function()
      h.run_test_cases({
        {
          name = "existing heading inserts near top by default",
          content = {
            "# Inbox",
            h.todo_line({ text = "Task A" }),
            "# Done",
            "",
            h.todo_line({ text = "Existing Done" }),
            "# Later",
            h.todo_line({ text = "Task B" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = heading.new("Done", 1),
              },
            })
          end,
          expected = {
            "# Inbox",
            "# Done",
            "",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Existing Done" }),
            "# Later",
            h.todo_line({ text = "Task B" }),
          },
        },
        {
          name = "existing heading inserts near top with root spacing before existing content",
          content = {
            "# Inbox",
            h.todo_line({ text = "Task A" }),
            "# Done",
            "",
            h.todo_line({ text = "Existing Done" }),
            "# Later",
            h.todo_line({ text = "Task B" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = heading.new("Done", 1),
                root_spacing = 1,
              },
            })
          end,
          expected = {
            "# Inbox",
            "# Done",
            "",
            h.todo_line({ text = "Task A" }),
            "",
            h.todo_line({ text = "Existing Done" }),
            "# Later",
            h.todo_line({ text = "Task B" }),
          },
        },
        {
          name = "existing heading append_top=false appends to bottom of section",
          content = {
            "# Inbox",
            h.todo_line({ text = "Task A" }),
            "# Done",
            "",
            h.todo_line({ text = "Existing Done" }),
            "# Later",
            h.todo_line({ text = "Task B" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = heading.new("Done", 1),
                append_top = false,
                root_spacing = 1,
              },
            })
          end,
          expected = {
            "# Inbox",
            "# Done",
            "",
            h.todo_line({ text = "Existing Done" }),
            "",
            h.todo_line({ text = "Task A" }),
            "# Later",
            h.todo_line({ text = "Task B" }),
          },
        },

        {
          name = "missing heading is created at EOF",
          content = {
            "# Inbox",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                -- no `location`
                heading = heading.new("Done", 1),
              },
            })
          end,
          expected = {
            "# Inbox",
            h.todo_line({ text = "Task B" }),
            "",
            "# Done",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "heading blank line is inserted when missing",
          content = {
            "# Inbox",
            h.todo_line({ text = "Task A" }),
            "# Done",
            h.todo_line({ text = "Existing Done" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = heading.new("Done", 1),
              },
            })
          end,
          expected = {
            "# Inbox",
            "# Done",
            "",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Existing Done" }),
          },
        },
        {
          name = "heading blank lines are collapsed to one",
          content = {
            "# Inbox",
            h.todo_line({ text = "Task A" }),
            "# Done",
            "",
            "",
            h.todo_line({ text = "Existing Done" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = heading.new("Done", 1),
              },
            })
          end,
          expected = {
            "# Inbox",
            "# Done",
            "",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Existing Done" }),
          },
        },
        {
          name = "blank_line_under_heading=false preserves heading layout",
          content = {
            "# Inbox",
            h.todo_line({ text = "Task A" }),
            "# Done", -- no blank line under, should be preserved per user opt
            h.todo_line({ text = "Existing Done" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = heading.new("Done", 1),
                blank_line_under_heading = false,
              },
            })
          end,
          expected = {
            "# Inbox",
            "# Done",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Existing Done" }),
          },
        },
        {
          name = "inserts new heading at specific line boundary",
          -- i.e., when both heading and location are given as opts
          content = {
            "# Inbox",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            "", -- want to insert after this
            "# Saved",
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task D" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = heading.new("Pending", 1),
                location = 4, -- before "# Saved"
              },
            })
          end,
          expected = {
            "# Inbox",
            h.todo_line({ text = "Task B" }),
            "",
            "# Pending",
            "",
            h.todo_line({ text = "Task A" }),
            "# Saved",
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task D" }),
          },
        },
      })
    end)

    it("should clean up or preserve source blank lines according to cleanup_source", function()
      h.run_test_cases({
        {
          name = "cleanup_source=true removes one redundant blank line",
          content = {
            h.todo_line({ text = "Task A" }),
            "",
            h.todo_line({ text = "Task B" }),
            "",
            h.todo_line({ text = "Task C" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task B") } },
              destination = { location = line_count(ctx.buffer) },
              cleanup_source = true,
            })
          end,
          expected = {
            h.todo_line({ text = "Task A" }),
            "",
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task B" }),
          },
        },
        {
          name = "cleanup_source=false preserves surrounding blank lines",
          content = {
            h.todo_line({ text = "Task A" }),
            "",
            h.todo_line({ text = "Task B" }),
            "",
            h.todo_line({ text = "Task C" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.todo_map, "Task B") } },
              destination = { location = line_count(ctx.buffer) },
              cleanup_source = false,
            })
          end,
          expected = {
            h.todo_line({ text = "Task A" }),
            "",
            "",
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task B" }),
          },
        },
      })
    end)
  end)

  describe("cross-buffer moves", function()
    ---@class MoveTodosCrossBufferCase
    ---@field name string
    ---@field source string[]
    ---@field dest string[]
    ---@field action fun(cm: Checkmate, ctx: table)
    ---@field expected_source string[]
    ---@field expected_dest string[]

    ---@param test_cases MoveTodosCrossBufferCase[]
    local function run_cross_buffer_cases(test_cases)
      local cm = require("checkmate")
      cm.setup(h.DEFAULT_TEST_CONFIG)

      for _, tc in ipairs(test_cases) do
        local src_bufnr
        local dest_bufnr

        local ok, err = pcall(function()
          src_bufnr = h.setup_test_buffer(tc.source, "source-" .. tc.name .. ".md")
          h.activate_checkmate_buffer(src_bufnr, 100)

          dest_bufnr = h.setup_test_buffer(tc.dest, "dest-" .. tc.name .. ".md")
          h.activate_checkmate_buffer(dest_bufnr, 100)

          -- the public API uses the current buffer as source
          vim.api.nvim_set_current_buf(src_bufnr)
          vim.api.nvim_win_set_buf(0, src_bufnr)

          local ctx = {
            source = src_bufnr,
            dest = dest_bufnr,
            cm = cm,
            source_todo_map = parser.get_todo_map(src_bufnr),
            dest_todo_map = parser.get_todo_map(dest_bufnr),
          }

          tc.action(cm, ctx)

          -- cross-buffer destination transaction is scheduled by api.move_todos
          wait_for_scheduled_move()

          h.assert_lines_equal(lines(src_bufnr), tc.expected_source, tc.name .. " source")
          h.assert_lines_equal(lines(dest_bufnr), tc.expected_dest, tc.name .. " dest")
        end)

        if src_bufnr and vim.api.nvim_buf_is_valid(src_bufnr) then
          h.cleanup_test_buffer(src_bufnr)
        end
        if dest_bufnr and vim.api.nvim_buf_is_valid(dest_bufnr) then
          h.cleanup_test_buffer(dest_bufnr)
        end

        assert(ok, err)
      end

      pcall(cm._stop)
    end

    it("should move todos between buffers by explicit row destinations", function()
      run_cross_buffer_cases({
        {
          name = "explicit destination EOF",
          source = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
          },
          dest = {
            h.todo_line({ text = "Dest A" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                location = line_count(ctx.dest),
              },
            })
          end,
          expected_source = {
            h.todo_line({ text = "Task B" }),
          },
          expected_dest = {
            h.todo_line({ text = "Dest A" }),
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "destination buffer default location uses destination EOF",
          source = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task C" }),
          },
          dest = {
            h.todo_line({ text = "Dest A" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
              },
            })
          end,
          expected_source = {
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task C" }),
          },
          expected_dest = {
            h.todo_line({ text = "Dest A" }),
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "multiple ids preserve source order and root spacing",
          source = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task C" }),
          },
          dest = {
            h.todo_line({ text = "Dest A" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = {
                ids = {
                  id_by_text(ctx.source_todo_map, "Task A"),
                  id_by_text(ctx.source_todo_map, "Task C"),
                },
              },
              destination = {
                bufnr = ctx.dest,
                root_spacing = 1,
              },
            })
          end,
          expected_source = {
            h.todo_line({ text = "Task B" }),
          },
          expected_dest = {
            h.todo_line({ text = "Dest A" }),
            h.todo_line({ text = "Task A" }),
            "",
            h.todo_line({ text = "Task C" }),
          },
        },
        {
          name = "subtree moves intact between buffers",
          source = {
            h.todo_line({ text = "Parent A" }),
            h.todo_line({ indent = 2, text = "Child A1" }),
            h.todo_line({ indent = 2, text = "Child A2" }),
            h.todo_line({ text = "Task B" }),
          },
          dest = {
            "# Dest",
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.source_todo_map, "Parent A") } },
              destination = {
                bufnr = ctx.dest,
              },
            })
          end,
          expected_source = {
            h.todo_line({ text = "Task B" }),
          },
          expected_dest = {
            "# Dest",
            h.todo_line({ text = "Parent A" }),
            h.todo_line({ indent = 2, text = "Child A1" }),
            h.todo_line({ indent = 2, text = "Child A2" }),
          },
        },
      })
    end)

    it("should move todos between buffers into heading destinations", function()
      run_cross_buffer_cases({
        {
          name = "existing destination heading top insert",
          source = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
          },
          dest = {
            "# Done",
            "",
            h.todo_line({ text = "Existing Done" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = heading.new("Done", 1),
              },
            })
          end,
          expected_source = {
            h.todo_line({ text = "Task B" }),
          },
          expected_dest = {
            "# Done",
            "",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Existing Done" }),
          },
        },
        {
          name = "existing destination heading append bottom",
          source = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
          },
          dest = {
            "# Done",
            "",
            h.todo_line({ text = "Existing Done" }),
            "# Later",
            h.todo_line({ text = "Later Task" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = heading.new("Done", 1),
                append_top = false,
                root_spacing = 1,
              },
            })
          end,
          expected_source = {
            h.todo_line({ text = "Task B" }),
          },
          expected_dest = {
            "# Done",
            "",
            h.todo_line({ text = "Existing Done" }),
            "",
            h.todo_line({ text = "Task A" }),
            "# Later",
            h.todo_line({ text = "Later Task" }),
          },
        },
        {
          name = "missing destination heading is created at EOF",
          source = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
          },
          dest = {
            "# Inbox",
            h.todo_line({ text = "Dest A" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              by = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = heading.new("Done", 1),
              },
            })
          end,
          expected_source = {
            h.todo_line({ text = "Task B" }),
          },
          expected_dest = {
            "# Inbox",
            h.todo_line({ text = "Dest A" }),
            "",
            "# Done",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
      })
    end)

    it("should support cursor/default source for cross-buffer moves", function()
      run_cross_buffer_cases({
        {
          name = "cursor source moves to destination EOF",
          source = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
          },
          dest = {
            h.todo_line({ text = "Dest A" }),
          },
          action = function(cm, ctx)
            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            cm.move_todos({
              destination = {
                bufnr = ctx.dest,
              },
            })
          end,
          expected_source = {
            h.todo_line({ text = "Task A" }),
          },
          expected_dest = {
            h.todo_line({ text = "Dest A" }),
            h.todo_line({ text = "Task B" }),
          },
        },
      })
    end)
  end)
end)
