describe("Transaction", function()
  local h = require("tests.checkmate.helpers")

  before_each(function()
    _G.reset_state()

    h.ensure_normal_mode()
  end)

  it("should apply queued operations and clear state", function()
    local config = require("checkmate.config")
    local transaction = require("checkmate.transaction")
    local parser = require("checkmate.parser")
    local api = require("checkmate.api")

    local unchecked = config.options.todo_markers.unchecked
    local checked = config.options.todo_markers.checked

    -- Create temp buf with one unchecked todo
    local content = "- " .. unchecked .. " TaskX"
    local bufnr = h.create_test_buffer(content)

    assert.is_false(transaction.is_active())

    -- Run a transaction that toggles TaskX to 'checked'
    transaction.run(bufnr, function(ctx)
      local todo_map = parser.discover_todos(bufnr)
      local todo = h.find_todo_by_text(todo_map, "TaskX")
      assert.is_not_nil(todo)
      ---@cast todo checkmate.TodoItem
      ctx.add_op(api.toggle_state, todo.id, "checked")
    end, function()
      -- Post-transaction: buffer line should now show checked marker
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
    local bufnr = h.create_test_buffer("")

    local called = false
    local received = nil

    -- Run a transaction that only queues a callback
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
end)
