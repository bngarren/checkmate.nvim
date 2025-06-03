--[[
Transaction Module 

provides a context for grouping diff generating operations and related callbacks
into “transactions” so that expensive steps (e.g., discover_todos) run only once
per batch, even if many operations or callbacks are queued.

op (operation):
  – A function (plus its original args) that returns zero or more TextDiffHunk[]
  – All queued ops are collected each loop iteration; their hunks are merged,
    applied once via api.apply_diff, then parser.discover_todos is called exactly once.
callback (cb):
  – A function (plus its args) meant to run after the current batch of ops is applied
  – All queued callbacks run only after the todo map has been refreshed (discover_todos).
  – Callbacks can themselves enqueue new ops or callbacks for the next iteration.

some notes on the internals (inside M.run):
  1. entry_fn(context) runs, letting plugin code queue up ops/cbs.
  2. While there are ops or cbs:
     a. If op_queue is nonempty:
       - Pull all ops at once → call op.fn for each, collect all diff hunks → api.apply_diff(bufnr, all_hunks) → parser.discover_todos(bufnr).
     b. If cb_queue is nonempty:
       - Pull all callbacks at once → run each cb_fn(context, ...)
       - Any new ops/cbs now sit in op_queue/cb_queue for next loop iteration.
  3. After both queues drain, optional post_fn() is invoked and transaction ends.

remember...
  - callbacks should not directly mutate buffer state; they should queue ops via add_op
  - batching ensures that discover_todos() is called exactly once per group of ops,
    minimizing expensive recomputation even if many todo items operated on
]]
--

local M = {}
local parser = require("checkmate.parser")
local api = require("checkmate.api")

M._state = nil

function M.is_active()
  return M._state ~= nil
end

function M.current_context()
  return M._state and M._state.context or nil
end

--- Get current transaction state (for debugging)
function M.get_state()
  return M._state
end

--- Starts a transaction for a buffer
---@param bufnr number Buffer number
---@param entry_fn function Function to start the transaction
---@param post_fn function? Function to run after transaction completes
function M.run(bufnr, entry_fn, post_fn)
  assert(not M._state, "Nested transactions are not supported")

  -- Initialize transaction state
  local state = {
    bufnr = bufnr,
    todo_map = parser.get_todo_map(bufnr),
    op_queue = {},
    cb_queue = {},
    seen_ops = {}, --dedupe identical ops
  }

  -- Create the transaction context
  state.context = {
    -- Get the current (latest) todo item by ID
    get_item = function(extmark_id)
      local item = M._state.todo_map[extmark_id]
      if not item then
        vim.notify("Could not find extmark_id: " .. extmark_id)
        vim.notify(vim.inspect(vim.api.nvim_buf_get_extmarks(0, require("checkmate.config").ns_todos, 0, -1, {})))
      end
      return M._state.todo_map[extmark_id]
    end,

    --- Queue any function and its arguments
    --- @param fn function  the fn must return checkmate.TextHunkDiff[] or nil or {}
    --- @param ... any      args to pass when we actually call `fn(...)`.
    add_op = function(fn, ...)
      local fn_name = debug.getinfo(fn, "n").name or tostring(fn)

      local seen_key = fn_name
      for i = 1, select("#", ...) do
        seen_key = seen_key .. "|" .. tostring(select(i, ...))
      end

      if not M._state.seen_ops[seen_key] then
        M._state.seen_ops[seen_key] = true
        table.insert(M._state.op_queue, {
          fn = fn,
          args = { ... },
        })
      end
    end,

    -- Queue a callback
    add_cb = function(cb_fn, ...)
      table.insert(M._state.cb_queue, {
        cb_fn = cb_fn,
        params = { ... },
      })
    end,

    bufnr = bufnr,
  }

  M._state = state

  entry_fn(state.context)

  -- transaction loop: process operations and callbacks until both queues are empty
  while #M._state.op_queue > 0 or #M._state.cb_queue > 0 do
    if #M._state.op_queue > 0 then
      local queued = M._state.op_queue
      M._state.op_queue = {}

      -- collect every diff from each op into a single array
      local all_hunks = {}
      for _, op in ipairs(queued) do
        -- call op.fn(context, unpack(op.args))
        local hunks = op.fn(state.context, unpack(op.args))
        if hunks and #hunks > 0 then
          vim.list_extend(all_hunks, hunks)
        end
      end

      if #all_hunks > 0 then
        api.apply_diff(bufnr, all_hunks)
        M._state.todo_map = parser.discover_todos(bufnr)
      end
    end

    if #M._state.cb_queue > 0 then
      local cbs = M._state.cb_queue
      M._state.cb_queue = {}

      for _, cb in ipairs(cbs) do
        cb.cb_fn(state.context, unpack(cb.params))
      end
    end
  end

  -- Execute post-transaction function
  if post_fn then
    post_fn()
  end

  -- Clear transaction state
  M._state = nil
end

return M
