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

      assert.is_function(todo.get_metadata)

      local p1, p2 = todo.get_metadata("priority")
      assert.are_same("priority", p1)
      assert.are_same("high", p2)

      local s1, s2 = todo.get_metadata("started")
      assert.are_same("started", s1)
      assert.are_same("today", s2)

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

      ---@type checkmate.StyleFn
      local received_ctx
      local style_fn = function(ctx)
        received_ctx = ctx
        return { fg = "#ff0000" }
      end

      local priority_props = vim.tbl_extend("force", config.options.metadata["priority"], { style = style_fn })

      assert.same(style_fn, priority_props.style)

      local result
      assert.no_error(function()
        result = meta_module.evaluate_style(priority_props, context)
      end)

      assert.are_equal(received_ctx, context)

      assert.are_same({ fg = "#ff0000" }, result)
    end)
  end)
end)
