describe("Transaction", function()
  local h, checkmate, transaction, parser, api, util, diff

  before_each(function()
    _G.reset_state()

    h = require("tests.checkmate.helpers")
    checkmate = require("checkmate")
    transaction = require("checkmate.transaction")
    parser = require("checkmate.parser")
    api = require("checkmate.api")
    util = require("checkmate.util")
    diff = require("checkmate.lib.diff")

    checkmate.setup()
    vim.wait(20)

    h.ensure_normal_mode()
  end)

  it("should reject nested transactions in same buffer", function()
    local bufnr = h.setup_test_buffer("")

    assert.has_error(function()
      transaction.run(bufnr, function()
        transaction.run(bufnr, function() end)
      end)
    end, "Nested transactions are not supported for buffer " .. bufnr)
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
    local original_apply_diff = diff.apply_diff
    diff.apply_diff = function(...)
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

    diff.apply_diff = original_apply_diff
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
  end)

  it("should execute callbacks after all operations in a batch (even if no hunks)", function()
    local unchecked = h.get_unchecked_marker()
    local content = [[
- ]] .. unchecked .. [[ Task 1
- ]] .. unchecked .. [[ Task 2
]]
    local bufnr = h.setup_test_buffer(content)

    local execution_order = {}

    local spy_apply_diff = spy.on(diff, "apply_diff")

    transaction.run(bufnr, function(ctx)
      local todo_map = parser.discover_todos(bufnr)

      -- queue ops that produce NO hunks; they still must run before callbacks
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

    -- not called, since no hunks were returned
    assert(spy_apply_diff:called(0))
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
  end)

  it("should run callbacks queued during ops (micro) before sibling callbacks (macro)", function()
    local unchecked = h.get_unchecked_marker()
    local content = "- " .. unchecked .. " TaskMicroMacro"
    local bufnr = h.setup_test_buffer(content)

    local order = {}

    transaction.run(bufnr, function(ctx)
      local todo_map = parser.discover_todos(bufnr)
      local todo = h.find_todo_by_text(todo_map, "TaskMicroMacro")
      assert.is_not_nil(todo)

      -- Op that queues a callback DURING op execution
      ctx.add_op(function(op_ctx)
        table.insert(order, "op")
        -- schedule a micro-cb that runs BEFORE the macro callbacks
        op_ctx.add_cb(function(cb_ctx)
          table.insert(order, "micro")
          -- make a visible change so the macro can observe it
          cb_ctx.add_op(api.toggle_state, { { id = todo.id, target_state = "checked" } })
        end)
        return {} -- no direct diff from this op
      end)

      ctx.add_cb(function(cb_ctx)
        table.insert(order, "macro")
        -- should observe "checked" since micro already applied its op batch
        local updated = cb_ctx.get_todo_by_id(todo.id)
        assert.is_not_nil(updated)
        assert.equal("checked", updated.state)
      end)
    end)

    assert.same({ "op", "micro", "macro" }, order)
  end)

  it("should apply ops enqueued by micro-callbacks before macros run", function()
    local unchecked = h.get_unchecked_marker()
    local content = "- " .. unchecked .. " FP"
    local bufnr = h.setup_test_buffer(content)

    local batches = {}

    -- spy on apply_diff to count op batches
    local original_apply_diff = diff.apply_diff
    diff.apply_diff = function(...)
      table.insert(batches, "apply")
      return original_apply_diff(...)
    end

    transaction.run(bufnr, function(ctx)
      local todo_map = parser.discover_todos(bufnr)
      local todo = h.find_todo_by_text(todo_map, "FP")
      assert.is_not_nil(todo)

      -- batch 1: an op that queues a micro-cb which enqueues another op
      ctx.add_op(function(op_ctx)
        -- micro schedules toggle op
        op_ctx.add_cb(function(cb_ctx)
          cb_ctx.add_op(api.toggle_state, { { id = todo.id, target_state = "checked" } })
        end)
        return {}
      end)

      -- macro cb should run AFTER the micro-triggered toggle applied
      ctx.add_cb(function(cb_ctx)
        local updated = cb_ctx.get_todo_by_id(todo.id)
        assert.equal("checked", updated.state)
      end)
    end)

    -- only the micro-enqueued toggle produced hunks → exactly one apply_diff call
    assert.equal(1, #batches)

    diff.apply_diff = original_apply_diff
  end)

  it("should drain chained micro-callbacks fully before any macro runs", function()
    local bufnr = h.setup_test_buffer("")

    local order = {}

    transaction.run(bufnr, function(ctx)
      ctx.add_op(function(op_ctx)
        table.insert(order, "op")
        -- micro-1
        op_ctx.add_cb(function(inner_ctx)
          table.insert(order, "micro-1")
          -- queue another micro during a micro
          inner_ctx.add_cb(function()
            table.insert(order, "micro-2")
          end)
        end)
        return {}
      end)

      -- macro sibling
      ctx.add_cb(function()
        table.insert(order, "macro")
      end)
    end)

    assert.same({ "op", "micro-1", "micro-2", "macro" }, order)
  end)

  it("should keep apply_diff batching correct when micro enqueues additional ops", function()
    local unchecked = h.get_unchecked_marker()
    local content = ([[
- %s One
- %s Two]]):format(unchecked, unchecked)
    local bufnr = h.setup_test_buffer(content)

    local apply_calls = 0
    local original_apply_diff = diff.apply_diff
    diff.apply_diff = function(...)
      apply_calls = apply_calls + 1
      return original_apply_diff(...)
    end

    transaction.run(bufnr, function(ctx)
      local todo_map = parser.discover_todos(bufnr)

      -- First batch: toggle both items (one op call producing multiple hunks)
      local ops = {}
      for _, todo in pairs(todo_map) do
        table.insert(ops, { id = todo.id, target_state = "checked" })
      end
      ctx.add_op(api.toggle_state, ops)

      -- During the same op batch, enqueue a micro that enqueues another toggle back to unchecked for the first item
      ctx.add_op(function(op_ctx)
        op_ctx.add_cb(function(cb_ctx)
          local tm = cb_ctx.get_todo_map()
          local first = h.find_todo_by_text(tm, "One")
          assert.is_not_nil(first)
          cb_ctx.add_op(api.toggle_state, { { id = first.id, target_state = "unchecked" } })
        end)
        return {}
      end)

      -- Macro just observes final state
      ctx.add_cb(function(cb_ctx)
        local tm = cb_ctx.get_todo_map()
        local one = h.find_todo_by_text(tm, "One")
        local two = h.find_todo_by_text(tm, "Two")
        assert.equal("unchecked", one.state)
        assert.equal("checked", two.state)
      end)
    end)

    -- Expect two apply_diff calls: initial (both -> checked) and micro-driven (One -> unchecked)
    assert.equal(2, apply_calls)

    diff.apply_diff = original_apply_diff
  end)
end)
