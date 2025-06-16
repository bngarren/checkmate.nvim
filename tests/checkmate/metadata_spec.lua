describe("Metadata", function()
  local h = require("tests.checkmate.helpers")
  local checkmate = require("checkmate")

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

    h.ensure_normal_mode()

    checkmate.setup()
  end)

  after_each(function()
    checkmate.stop()
  end)

  describe("metadata context", function()
    it("should create a context object", function()
      local unchecked = h.get_unchecked_marker()

      local content = "- " .. unchecked .. " Task A @priority(high) @started(today)"
      local bufnr = h.create_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local todo_item = h.get_todo_at_cursor(bufnr)
      assert.is_not_nil(todo_item)
      ---@cast todo_item checkmate.TodoItem

      local context = require("checkmate.metadata").create_context(todo_item, "priority", "high", bufnr)

      assert.is_table(context)
      assert.are_equal(context.buffer, bufnr)
      assert.are_equal(context.name, "priority")
      assert.are_equal(context.value, "high")

      local todo = context.todo
      assert.is_table(todo)
      assert.are_equal(todo._todo_item, todo_item)
      assert.are_equal(todo.state, "unchecked")
      assert.are_equal(todo.text, content)
      assert.are_same(todo.metadata, { { "priority", "high" }, { "started", "today" } })

      assert.is_function(todo.is_checked)
      local c = todo.is_checked()
      assert.is_false(c)

      assert.is_function(todo.get_metadata)

      local p1, p2 = todo.get_metadata("priority")
      assert.are_same("priority", p1)
      assert.are_same("high", p2)

      local s1, s2 = todo.get_metadata("started")
      assert.are_same("started", s1)
      assert.are_same("today", s2)

      local u1, u2 = todo.get_metadata("unknown")
      assert.is_nil(u1)
      assert.is_nil(u2)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should evaluate style fn", function()
      local meta_module = require("checkmate.metadata")
      local config = require("checkmate.config")

      local unchecked = h.get_unchecked_marker()

      local content = "- " .. unchecked .. " Task A @priority(high) @started(today)"
      local bufnr = h.create_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local todo_item = h.get_todo_at_cursor(bufnr)
      assert.is_not_nil(todo_item)
      ---@cast todo_item checkmate.TodoItem

      local context = require("checkmate.metadata").create_context(todo_item, "priority", "high", bufnr)

      local received_ctx
      ---@type checkmate.StyleFn
      local style_fn = function(ctx)
        received_ctx = ctx
        return { fg = "#ff0000" }
      end

      local priority_props = vim.tbl_extend("force", config.options.metadata["priority"], { style = style_fn })

      local result
      assert.no_error(function()
        result = meta_module.evaluate_style(priority_props, context)
      end)

      assert.are_equal(received_ctx, context)

      assert.are_same({ fg = "#ff0000" }, result)
    end)

    it("should evaluate get_value fn", function()
      local meta_module = require("checkmate.metadata")
      local config = require("checkmate.config")

      local unchecked = h.get_unchecked_marker()

      local content = "- " .. unchecked .. " Task A @priority(high) @started(today)"
      local bufnr = h.create_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local todo_item = h.get_todo_at_cursor(bufnr)
      assert.is_not_nil(todo_item)
      ---@cast todo_item checkmate.TodoItem

      local context = require("checkmate.metadata").create_context(todo_item, "priority", "high", bufnr)

      local received_ctx
      ---@type checkmate.GetValueFn
      local get_value_fn = function(ctx)
        received_ctx = ctx
        return "foo"
      end

      local priority_props = vim.tbl_extend("force", config.options.metadata["priority"], { get_value = get_value_fn })

      local result
      assert.no_error(function()
        result = meta_module.evaluate_value(priority_props, context)
      end)

      assert.are_equal(received_ctx, context)

      assert.are_equal("foo", result)
    end)

    it("should evalaute choices fn", function()
      local meta_module = require("checkmate.metadata")
      local config = require("checkmate.config")

      local unchecked = h.get_unchecked_marker()

      local content = "- " .. unchecked .. " Task A @priority(high) @started(today)"
      local bufnr = h.create_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local todo_item = h.get_todo_at_cursor(bufnr)
      assert.is_not_nil(todo_item)
      ---@cast todo_item checkmate.TodoItem

      local context = require("checkmate.metadata").create_context(todo_item, "priority", "high", bufnr)

      ---@type table<string, checkmate.ChoicesFn|table>
      local choices_fns = {
        tbl = { "foo", "bar", "baz" },
        sync_0 = function()
          return { "foo", "bar", "baz" }
        end,
        ---@diagnostic disable-next-line: unused-local
        sync_1 = function(ctx)
          return { "foo", "bar", "baz" }
        end,
        ---@diagnostic disable-next-line: unused-local
        sync_2 = function(ctx, cb)
          return { "foo", "bar", "baz" }
        end,
        ---@diagnostic disable-next-line: unused-local
        async = function(ctx, cb)
          cb({ "foo", "bar", "baz" })
        end,
      }

      local choices_cb = function(items)
        assert.same({ "foo", "bar", "baz" }, items)
      end

      for _, choices in pairs(choices_fns) do
        local priority_props = vim.tbl_extend("force", config.options.metadata["priority"], { choices = choices })

        local result
        assert.no_error(function()
          result = meta_module.evaluate_choices(priority_props, context, choices_cb)
        end)

        assert.is_nil(result)
      end
    end)
  end)
end)
