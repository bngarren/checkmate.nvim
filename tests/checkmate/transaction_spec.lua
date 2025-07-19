describe("Transaction", function()
  local h = require("tests.checkmate.helpers")

  local checkmate = require("checkmate")
  local transaction = require("checkmate.transaction")
  local parser = require("checkmate.parser")
  local api = require("checkmate.api")

  before_each(function()
    _G.reset_state()

    checkmate.setup()
    vim.wait(20)

    h.ensure_normal_mode()
  end)

  after_each(function()
    checkmate.stop()
  end)

  it("should reject nested transactions in same buffer", function()
    local bufnr = h.setup_test_buffer("")

    assert.has_error(function()
      transaction.run(bufnr, function()
        transaction.run(bufnr, function() end)
      end)
    end, "Nested transactions are not supported for buffer " .. bufnr)

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should apply queued operations and clear state", function()
    local unchecked = h.get_unchecked_marker()
    local checked = h.get_checked_marker()

    -- Create temp buf with one unchecked todo
    local content = "- " .. unchecked .. " TaskX"
    local bufnr = h.setup_test_buffer(content)

    assert.is_false(transaction.is_active())

    -- Run a transaction that toggles TaskX to 'checked'
    transaction.run(bufnr, function(ctx)
      local todo_map = parser.discover_todos(bufnr)
      local todo = h.find_todo_by_text(todo_map, "TaskX")
      assert.is_not_nil(todo)
      ---@cast todo checkmate.TodoItem
      ctx.add_op(api.toggle_state, { { id = todo.id, target_state = "checked" } })
    end, function()
      -- buffer line should now show checked marker
      local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      assert.matches(checked, line)
    end)

    assert.is_false(transaction.is_active())

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should execute queued callbacks within a transaction", function()
    -- empty buffer (no todo items needed for callback test)
    local bufnr = h.setup_test_buffer("")

    local called = false
    local received = nil

    -- transaction that only queues a callback
    require("checkmate.transaction").run(bufnr, function(ctx)
      ctx.add_cb(function(_, val)
        called = true
        received = val
      end, 123)
    end)

    assert.is_true(called)
    assert.equal(123, received)

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should batch multiple operations into single apply_diff call", function()
    local config = require("checkmate.config")
    local unchecked = h.get_unchecked_marker()
    local content = [[
- ]] .. unchecked .. [[ Task 1
- ]] .. unchecked .. [[ Task 2
- ]] .. unchecked .. [[ Task 3 ]]
    local bufnr = h.setup_test_buffer(content)

    local apply_diff_called = 0
    local original_apply_diff = api.apply_diff
    api.apply_diff = function(...)
      apply_diff_called = apply_diff_called + 1
      return original_apply_diff(...)
    end

    transaction.run(bufnr, function(ctx)
      local todo_map = parser.discover_todos(bufnr)
      for _, todo in pairs(todo_map) do
        ctx.add_op(api.toggle_state, { { id = todo.id, target_state = "checked" } })
      end
    end)

    -- should only call apply_diff once for all operations
    assert.equal(1, apply_diff_called)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for _, line in ipairs(lines) do
      assert.matches(config.options.todo_states.checked.marker, line)
    end

    api.apply_diff = original_apply_diff

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should update todo map after operations for subsequent callbacks", function()
    local unchecked = h.get_unchecked_marker()
    local content = "- " .. unchecked .. " Task1"
    local bufnr = h.setup_test_buffer(content)

    local states_in_callback = {}

    transaction.run(bufnr, function(ctx)
      local todo_map = parser.discover_todos(bufnr)
      local todo = h.find_todo_by_text(todo_map, "Task1")
      if not todo then
        error("missing todo")
      end

      -- Queue operation to toggle to checked
      ctx.add_op(api.toggle_state, { { id = todo.id, target_state = "checked" } })

      -- Queue callback that should see updated state
      ctx.add_cb(function(cb_ctx)
        local updated_todo = cb_ctx.get_todo_by_id(todo.id)
        table.insert(states_in_callback, updated_todo.state)
      end)
    end)

    -- Callback should see the checked state
    assert.equal(1, #states_in_callback)
    assert.equal("checked", states_in_callback[1])

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should execute callbacks after all operations in a batch", function()
    local unchecked = h.get_unchecked_marker()
    local content = [[
- ]] .. unchecked .. [[ Task 1
- ]] .. unchecked .. [[ Task 2
]]
    local bufnr = h.setup_test_buffer(content)

    local execution_order = {}

    transaction.run(bufnr, function(ctx)
      local todo_map = parser.discover_todos(bufnr)

      for _, todo in pairs(todo_map) do
        ctx.add_op(function()
          table.insert(execution_order, "op:" .. todo.todo_text:match("Task %d"))
          return {} -- No actual diff
        end)
      end

      ctx.add_cb(function()
        table.insert(execution_order, "cb:1")
      end)

      ctx.add_cb(function()
        table.insert(execution_order, "cb:2")
      end)
    end)

    -- operations should execute before callbacks
    assert.equal(4, #execution_order)
    assert.truthy(execution_order[1]:match("^op:"))
    assert.truthy(execution_order[2]:match("^op:"))
    assert.equal("cb:1", execution_order[3])
    assert.equal("cb:2", execution_order[4])

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should provide current_context when transaction is active", function()
    local bufnr = h.setup_test_buffer("")
    local context_inside = nil
    local context_outside = transaction.current_context(bufnr)

    assert.is_nil(context_outside)

    transaction.run(bufnr, function(ctx)
      context_inside = transaction.current_context(bufnr)
      assert.is_not_nil(context_inside)
      assert.equal(ctx, context_inside)
    end)

    context_outside = transaction.current_context(bufnr)
    assert.is_nil(context_outside)

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should deduplicate repeated operations", function()
    local bufnr = h.setup_test_buffer("")
    local op_called = 0

    local function dummy_op()
      op_called = op_called + 1
      return {}
    end

    transaction.run(bufnr, function(ctx)
      ctx.add_op(dummy_op, "foo", "bar")
      ctx.add_op(dummy_op, "foo", "bar") -- same key
      ctx.add_op(dummy_op, "baz") -- different
    end)

    assert.equal(2, op_called)

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should execute post function after transaction completes", function()
    local bufnr = h.setup_test_buffer("")
    local post_called = false

    transaction.run(bufnr, function()
      -- empty txn
    end, function()
      post_called = true
    end)

    assert.is_true(post_called)

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should not crash transaction when callback throws error", function()
    local bufnr = h.setup_test_buffer("")
    local other_callbacks_executed = {}

    assert.has_no_error(function()
      transaction.run(bufnr, function(ctx)
        ctx.add_cb(function()
          table.insert(other_callbacks_executed, "before")
        end)

        ctx.add_cb(function()
          error("Intentional callback error")
        end)

        ctx.add_cb(function()
          table.insert(other_callbacks_executed, "after")
        end)
      end)
    end)

    assert.is_false(transaction.is_active())

    assert.equal(2, #other_callbacks_executed)

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)

  it("should handle callback errors with operations present", function()
    local unchecked = h.get_unchecked_marker()
    local content = "- " .. unchecked .. " Task1"
    local bufnr = h.setup_test_buffer(content)

    assert.has_no_error(function()
      transaction.run(bufnr, function(ctx)
        local todo_map = parser.discover_todos(bufnr)
        local todo = h.find_todo_by_text(todo_map, "Task1")
        if not todo then
          error("missing todo")
        end

        ctx.add_op(api.toggle_state, { { id = todo.id, target_state = "checked" } })

        ctx.add_cb(function()
          error("Callback error after operation")
        end)
      end)
    end)

    -- op should have still worked/applied diff to buffer
    local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    assert.matches(h.get_checked_marker(), line)

    assert.is_false(transaction.is_active())

    finally(function()
      h.cleanup_buffer(bufnr)
    end)
  end)
end)
