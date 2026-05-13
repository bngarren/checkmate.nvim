---@diagnostic disable: undefined-field

local cm_heading = require("checkmate.lib.heading")

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
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = { row = 2 },
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
              source = { ids = { id_by_text(ctx.todo_map, "Parent A") } },
              destination = { row = line_count(ctx.buffer) },
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
          name = "multiple explicit ids preserve source order and parent spacing",
          content = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Task D" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = {
                ids = {
                  id_by_text(ctx.todo_map, "Task A"),
                  id_by_text(ctx.todo_map, "Task C"),
                },
              },
              destination = {
                row = line_count(ctx.buffer),
              },
              insertion = {
                parent_spacing = 1,
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
              insertion = { parent_spacing = 0 },
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
              insertion = { parent_spacing = 0 },
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
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Done", 1),
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
          name = "existing heading inserts near top with parent spacing before existing content",
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
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Done", 1),
              },
              insertion = {
                parent_spacing = 1,
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
          name = "plain heading table is normalized",
          content = {
            h.todo_line({ text = "Task A" }),
            "## Done",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = { title = "Done", level = 2 },
              },
            })
          end,
          expected = {
            "## Done",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "existing heading placement=bottom appends to bottom of section",
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
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Done", 1),
              },
              insertion = {
                placement = "bottom",
                parent_spacing = 1,
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
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                -- no `row`
                heading = cm_heading.new("Done", 1),
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
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Done", 1),
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
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Done", 1),
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
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Done", 1),
              },
              insertion = {
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
          -- i.e., when both heading and row are given as opts
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
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Pending", 1),
                row = 4, -- before "# Saved"
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

    it("should preserve_source_headings context when requested", function()
      h.run_test_cases({
        {
          name = "nearest mode recreates each todo's immediate source heading under an existing destination heading",
          content = {
            "# School",
            h.todo_line({ text = "Task A" }),
            "# Club",
            h.todo_line({ text = "Task B" }),
            "## Archive",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = {
                ids = {
                  id_by_text(ctx.todo_map, "Task A"),
                  id_by_text(ctx.todo_map, "Task B"),
                },
              },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              preserve_source_headings = "nearest",
            })
          end,
          expected = {
            "# School",
            "# Club",
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Task A" }),
            "",
            "### Club",
            "",
            h.todo_line({ text = "Task B" }),
          },
        },
        {
          name = "nearest mode keeps only the immediate source heading from a nested chain",
          content = {
            "# School",
            "## Campus",
            h.todo_line({ text = "Task A" }),
            "## Archive",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              preserve_source_headings = "nearest",
            })
          end,
          expected = {
            "# School",
            "## Campus",
            "## Archive",
            "",
            "#### Campus",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "all mode deduplicates shared ancestor prefixes between sibling source headings",
          content = {
            "# School",
            "## Campus A",
            h.todo_line({ text = "Task A" }),
            "## Campus B",
            h.todo_line({ text = "Task B" }),
            "## Archive",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = {
                ids = {
                  id_by_text(ctx.todo_map, "Task A"),
                  id_by_text(ctx.todo_map, "Task B"),
                },
              },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              preserve_source_headings = "all",
            })
          end,
          expected = {
            "# School",
            "## Campus A",
            "## Campus B",
            "## Archive",
            "",
            "### School",
            "",
            "#### Campus A",
            "",
            h.todo_line({ text = "Task A" }),
            "",
            "#### Campus B",
            "",
            h.todo_line({ text = "Task B" }),
          },
        },
        {
          name = "orphan todos go directly into the destination beside headed groups",
          content = {
            h.todo_line({ text = "Orphan Task" }),
            "# Work",
            h.todo_line({ text = "Work Task" }),
            "## Archive",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = {
                ids = {
                  id_by_text(ctx.todo_map, "Orphan Task"),
                  id_by_text(ctx.todo_map, "Work Task"),
                },
              },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              preserve_source_headings = "nearest",
            })
          end,
          expected = {
            "# Work",
            "## Archive",
            "",
            h.todo_line({ text = "Orphan Task" }),
            "",
            "### Work",
            "",
            h.todo_line({ text = "Work Task" }),
          },
        },
        {
          name = "row-only mode stamps source headings at their original levels",
          content = {
            "# School",
            "## Campus",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Anchor" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                row = line_count(ctx.buffer),
              },
              preserve_source_headings = "all",
            })
          end,
          expected = {
            "# School",
            "## Campus",
            h.todo_line({ text = "Anchor" }),
            "# School",
            "",
            "## Campus",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "row plus heading mode normalizes source headings under the created heading",
          content = {
            "# School",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Anchor" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                row = line_count(ctx.buffer),
                heading = cm_heading.new("Archive", 2),
              },
              preserve_source_headings = "nearest",
            })
          end,
          expected = {
            "# School",
            h.todo_line({ text = "Anchor" }),
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "blank_line_under_heading=false applies to generated source headings",
          content = {
            "# School",
            "## Campus",
            h.todo_line({ text = "Task A" }),
            "## Archive",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              insertion = {
                blank_line_under_heading = false,
              },
              preserve_source_headings = "all",
            })
          end,
          expected = {
            "# School",
            "## Campus",
            "## Archive",
            "### School",
            "#### Campus",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "parent_spacing applies between top-level todos in the same preserved heading section",
          content = {
            "# School",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            "## Archive",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = {
                ids = {
                  id_by_text(ctx.todo_map, "Task A"),
                  id_by_text(ctx.todo_map, "Task B"),
                },
              },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              insertion = {
                parent_spacing = 1,
              },
              preserve_source_headings = "nearest",
            })
          end,
          expected = {
            "# School",
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Task A" }),
            "",
            h.todo_line({ text = "Task B" }),
          },
        },
        {
          name = "headings inside fenced code blocks are ignored when building source chains",
          content = {
            "```",
            "## Not A Heading",
            "```",
            h.todo_line({ text = "Task A" }),
            "## Archive",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              preserve_source_headings = "nearest",
            })
          end,
          expected = {
            "```",
            "## Not A Heading",
            "```",
            "## Archive",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "deep source heading levels are capped at Markdown level six under a destination heading",
          content = {
            "# School",
            "##### Deep",
            h.todo_line({ text = "Task A" }),
            "## Archive",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              preserve_source_headings = "all",
            })
          end,
          expected = {
            "# School",
            "##### Deep",
            "## Archive",
            "",
            "### School",
            "",
            "###### Deep",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "full matching source chain merges payload into an existing nested destination heading",
          content = {
            "# School",
            h.todo_line({ text = "Task A" }),
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Existing Archived" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              insertion = {
                placement = "bottom",
              },
              preserve_source_headings = "nearest",
            })
          end,
          expected = {
            "# School",
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Existing Archived" }),
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "full matching source chain inserts near the top with parent spacing before existing content",
          content = {
            "# School",
            h.todo_line({ text = "Task A" }),
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Existing Archived" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              insertion = {
                parent_spacing = 1,
              },
              preserve_source_headings = "nearest",
            })
          end,
          expected = {
            "# School",
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Task A" }),
            "",
            h.todo_line({ text = "Existing Archived" }),
          },
        },
        {
          name = "partial matching source chain emits the diverging tail without applying parent_spacing above the heading",
          content = {
            "# School",
            "## Campus",
            h.todo_line({ text = "Task A" }),
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Existing School" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              insertion = {
                placement = "bottom",
                parent_spacing = 2,
              },
              preserve_source_headings = "all",
            })
          end,
          expected = {
            "# School",
            "## Campus",
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Existing School" }),
            "",
            "#### Campus",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "partial matches sharing an existing parent create separate child sections",
          content = {
            "# School",
            "## Campus A",
            h.todo_line({ text = "Task A" }),
            "## Campus B",
            h.todo_line({ text = "Task B" }),
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Existing School" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = {
                ids = {
                  id_by_text(ctx.todo_map, "Task A"),
                  id_by_text(ctx.todo_map, "Task B"),
                },
              },
              destination = {
                heading = cm_heading.new("Archive", 2),
              },
              insertion = {
                placement = "bottom",
              },
              preserve_source_headings = "all",
            })
          end,
          expected = {
            "# School",
            "## Campus A",
            "## Campus B",
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Existing School" }),
            "",
            "#### Campus A",
            "",
            h.todo_line({ text = "Task A" }),
            "",
            "#### Campus B",
            "",
            h.todo_line({ text = "Task B" }),
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
              source = { ids = { id_by_text(ctx.todo_map, "Task B") } },
              destination = { row = line_count(ctx.buffer) },
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
              source = { ids = { id_by_text(ctx.todo_map, "Task B") } },
              destination = { row = line_count(ctx.buffer) },
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

    it("should support destination option edge cases", function()
      h.run_test_cases({
        {
          name = "row=0 prepends todos to the very top of the buffer",
          content = {
            h.todo_line({ text = "Existing" }),
            h.todo_line({ text = "Task A" }),
          },
          setup = function(bufnr)
            return { todo_map = parser.get_todo_map(bufnr) }
          end,
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = { row = 0 },
            })
          end,
          expected = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Existing" }),
          },
        },
        {
          name = "parent_spacing=1 inserts a blank line between each moved top-level todo block",
          content = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
            h.todo_line({ text = "Task C" }),
            h.todo_line({ text = "Anchor" }),
          },
          setup = function(bufnr)
            return { todo_map = parser.get_todo_map(bufnr) }
          end,
          action = function(cm, ctx)
            cm.move_todos({
              source = {
                ids = {
                  id_by_text(ctx.todo_map, "Task A"),
                  id_by_text(ctx.todo_map, "Task B"),
                  id_by_text(ctx.todo_map, "Task C"),
                },
              },
              destination = { row = line_count(ctx.buffer) },
              insertion = { parent_spacing = 1 },
            })
          end,
          expected = {
            h.todo_line({ text = "Anchor" }),
            h.todo_line({ text = "Task A" }),
            "",
            h.todo_line({ text = "Task B" }),
            "",
            h.todo_line({ text = "Task C" }),
          },
        },
        {
          name = "placement=bottom appends to the bottom of an existing heading section",
          content = {
            "## Done",
            "",
            h.todo_line({ text = "Already done" }),
            h.todo_line({ text = "Task A" }),
          },
          setup = function(bufnr)
            return {
              todo_map = parser.get_todo_map(bufnr),
              heading = cm_heading.new("Done", 2),
            }
          end,
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = { heading = ctx.heading },
              insertion = { placement = "bottom" },
            })
          end,
          expected = {
            "## Done",
            "",
            h.todo_line({ text = "Already done" }),
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "blank_line_under_heading=false places payload directly under heading",
          content = {
            h.todo_line({ text = "Task A" }),
            "## Done",
          },
          setup = function(bufnr)
            local heading = require("checkmate.lib.heading")
            return {
              todo_map = parser.get_todo_map(bufnr),
              heading = heading.new("Done", 2),
            }
          end,
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.todo_map, "Task A") } },
              destination = {
                heading = ctx.heading,
              },
              insertion = {
                blank_line_under_heading = false,
              },
            })
          end,
          expected = {
            "## Done",
            h.todo_line({ text = "Task A" }),
          },
        },
      })
    end)

    it("should return false and leave the buffer unchanged when no todos match the source", function()
      h.run_test_cases({
        {
          name = "cursor on non-todo line is a no-op",
          content = {
            "Just a plain line",
            h.todo_line({ text = "Task A" }),
          },
          cursor = { 1, 0 },
          action = function(cm, ctx)
            local result = cm.move_todos({
              destination = { row = line_count(ctx.buffer) },
            })
            assert.is_false(result)
          end,
          expected = {
            "Just a plain line",
            h.todo_line({ text = "Task A" }),
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
              source = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                row = line_count(ctx.dest),
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
          name = "destination buffer default row uses destination EOF",
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
              source = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
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
          name = "multiple ids preserve source order and parent spacing",
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
              source = {
                ids = {
                  id_by_text(ctx.source_todo_map, "Task A"),
                  id_by_text(ctx.source_todo_map, "Task C"),
                },
              },
              destination = {
                bufnr = ctx.dest,
              },
              insertion = {
                parent_spacing = 1,
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
              source = { ids = { id_by_text(ctx.source_todo_map, "Parent A") } },
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
              source = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = cm_heading.new("Done", 1),
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
          name = "preserve_source_headings nearest mode works across buffers",
          source = {
            "# School",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
          },
          dest = {
            "## Archive",
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = cm_heading.new("Archive", 2),
              },
              preserve_source_headings = "nearest",
            })
          end,
          expected_source = {
            "# School",
            h.todo_line({ text = "Task B" }),
          },
          expected_dest = {
            "## Archive",
            "",
            "### School",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          name = "preserve_source_headings 'all' mode merges into existing nested headings across buffers",
          source = {
            "# School",
            "## Campus",
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
          },
          dest = {
            "## Archive",
            "",
            "### School",
            "",
            "#### Campus",
            "",
            h.todo_line({ text = "Existing Archived" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = cm_heading.new("Archive", 2),
              },
              insertion = {
                placement = "bottom",
                parent_spacing = 1,
              },
              preserve_source_headings = "all",
            })
          end,
          expected_source = {
            "# School",
            "## Campus",
            h.todo_line({ text = "Task B" }),
          },
          expected_dest = {
            "## Archive",
            "",
            "### School",
            "",
            "#### Campus",
            "",
            h.todo_line({ text = "Existing Archived" }),
            "",
            h.todo_line({ text = "Task A" }),
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
              source = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = cm_heading.new("Done", 1),
              },
              insertion = {
                placement = "bottom",
                parent_spacing = 1,
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
              source = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = cm_heading.new("Done", 1),
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

    it("should create a heading in the destination buffer when none exists", function()
      run_cross_buffer_cases({
        {
          name = "heading created at EOF with blank separator when dest has trailing content",
          source = {
            h.todo_line({ text = "Task A" }),
            h.todo_line({ text = "Task B" }),
          },
          dest = {
            h.todo_line({ text = "Dest existing" }),
          },
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = cm_heading.new("Archive", 2),
              },
            })
          end,
          expected_source = {
            h.todo_line({ text = "Task B" }),
          },
          expected_dest = {
            h.todo_line({ text = "Dest existing" }),
            "",
            "## Archive",
            "",
            h.todo_line({ text = "Task A" }),
          },
        },
        {
          -- an empty buffer in neovim is has one empty string line
          -- Inserting at EOF appends after that line
          -- TODO: maybe we don't want this behavior? i.e. strip that empty line for empty buffers
          name = "heading created at EOF when destination buffer is empty",
          source = {
            h.todo_line({ text = "Task A" }),
          },
          dest = {},
          action = function(cm, ctx)
            cm.move_todos({
              source = { ids = { id_by_text(ctx.source_todo_map, "Task A") } },
              destination = {
                bufnr = ctx.dest,
                heading = cm_heading.new("Done", 1),
              },
            })
          end,
          expected_source = { "" },
          expected_dest = {
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
