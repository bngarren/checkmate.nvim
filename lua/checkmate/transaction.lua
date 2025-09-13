--[[
Transaction Module 

provides a context for grouping diff generating operations and related callbacks
into “transactions” so that expensive steps (e.g., discover_todos) run only once
per batch, even if many operations or callbacks are queued.

op (operation):
  – A function (plus its original args) that returns zero or more TextDiffHunk[]
  – All queued ops are collected each loop iteration; their hunks are merged,
    applied once via util.apply_diff, then parser.discover_todos is called exactly once.
callback (cb):
  – A function (plus its args) meant to run after the current batch of ops is applied
  – All queued callbacks run only after the todo map has been refreshed (discover_todos).
  – Callbacks can themselves enqueue new ops or callbacks for the next iteration.

some notes on the internals (inside M.run):
  1. entry_fn(context) runs, letting plugin code queue up ops/cbs.
  2. While there are ops or cbs:
     a. If op_queue is nonempty:
       - Pull all ops at once → call op.fn for each, collect all diff hunks → util.apply_diff(bufnr, all_hunks) → parser.discover_todos(bufnr).
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
local diff = require("checkmate.lib.diff")
local util = require("checkmate.util")

---the exposed transaction state is referred to as "context"
---the internal state is M._states[bufnr]
---@class checkmate.TransactionContext
---@field get_todo_map fun(): table<integer, checkmate.TodoItem>
---@field get_todo_by_id fun(id: integer): checkmate.TodoItem?
---@field get_todo_by_row fun(row: integer, root_only?: boolean): checkmate.TodoItem?
---@field add_op fun(fn: function, ...)
---@field add_cb fun(fn: fun(ctx: checkmate.TransactionContext, ...), ...)
---@field get_buf fun(): integer Returns the buffer

M._states = {} -- bufnr -> state

function M.is_active(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return M._states[bufnr] ~= nil
end

function M.current_context(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return M._states[bufnr] and M._states[bufnr].context or nil
end

--- Get current transaction state (for debugging)
function M.get_state(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return M._states[bufnr]
end

--- Starts a transaction for a buffer
---@param bufnr number Buffer number
---@param entry_fn fun(ctx: checkmate.TransactionContext) Function to start the transaction
---@param post_fn function? Function to run after transaction completes
function M.run(bufnr, entry_fn, post_fn)
  assert(not M._states[bufnr], "Nested transactions are not supported for buffer " .. bufnr)

  local state = {
    bufnr = bufnr,
    todo_map = parser.get_todo_map(bufnr),
    op_queue = {},
    cb_queue = {},
    seen_ops = {}, --dedupe identical ops
  }

  -- Create the transaction context
  ---@type checkmate.TransactionContext
  state.context = {
    get_todo_map = function()
      return state.todo_map
    end,
    -- Get the current (latest) todo item by ID
    get_todo_by_id = function(extmark_id)
      return state.todo_map[extmark_id]
    end,

    get_todo_by_row = function(row, root_only)
      return parser.get_todo_item_at_position(state.bufnr, row, 0, { todo_map = state.todo_map, root_only = root_only })
    end,

    --- Queue any function and its arguments
    --- @param fn function fn must return checkmate.TextHunkDiff[] or nil or {}
    --- @param ... any args to pass when we actually call `fn(...)`
    add_op = function(fn, ...)
      local fn_name = debug.getinfo(fn, "n").name or tostring(fn)

      local seen_key = fn_name
      for i = 1, select("#", ...) do
        seen_key = seen_key .. "|" .. tostring(select(i, ...))
      end

      if not state.seen_ops[seen_key] then
        state.seen_ops[seen_key] = true
        table.insert(state.op_queue, {
          fn = fn,
          args = { ... },
        })
      end
    end,

    -- Queue a callback
    add_cb = function(cb_fn, ...)
      table.insert(state.cb_queue, {
        cb_fn = cb_fn,
        params = { ... },
      })
    end,

    get_buf = function()
      return state.bufnr
    end,
  }

  M._states[bufnr] = state

  entry_fn(state.context)

  -- transaction loop --> process operations and callbacks until both queues are empty
  while #state.op_queue > 0 or #state.cb_queue > 0 do
    if #state.op_queue > 0 then
      local queued = state.op_queue
      state.op_queue = {}

      -- collect every diff from each op into a single array
      ---@type checkmate.TextDiffHunk[]
      local all_hunks = {}
      for _, op in ipairs(queued) do
        ---@type checkmate.TextDiffHunk[]
        local op_result = op.fn(state.context, unpack(op.args))
        -- handle the op returning either a TextDiffHunk or TextDiffHunk[]
        if type(op_result) == "table" then
          if not vim.islist(op_result) and getmetatable(op_result) == diff.TextDiffHunk then
            vim.list_extend(all_hunks, { op_result })
          elseif vim.islist(op_result) then
            vim.list_extend(all_hunks, op_result)
          end
        end
      end

      if #all_hunks > 0 then
        diff.apply_diff(bufnr, all_hunks)
        state.todo_map = parser.discover_todos(bufnr)
      end
    end

    if #state.cb_queue > 0 then
      local cbs = state.cb_queue
      state.cb_queue = {}

      for _, cb in ipairs(cbs) do
        pcall(function()
          cb.cb_fn(state.context, unpack(cb.params))
        end)
      end
    end
  end

  if post_fn then
    post_fn()
  end

  M._states[bufnr] = nil
end

return M
