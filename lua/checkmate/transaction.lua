--[[
Transaction Module 

Provides a context for grouping diff-generating operations and related callbacks
into “transactions” so that expensive steps (e.g., discover_todos) run only once
per batch, even if many operations or callbacks are queued.

semantics:
  - op (operation): functions that returns zero or more TextDiffHunk[]
  - callback (cb): functions to run after the current batch of ops is applied

some notes on the internals (inside M.run):
  1. entry_fn(context) runs, letting plugin code queue up ops/cbs.
  2. while (ops or micro-cbs or macro-cbs):
    1) apply ALL ops → apply merged diff once → refresh todo_map once
    2) drain ALL micro-callbacks  (callbacks scheduled while running ops or other micro-cbs)
    3) drain ALL macro-callbacks  (callbacks scheduled outside ops; e.g., by entry_fn or other macro-cbs)
    Any callbacks scheduled during (1) or (2) are classified as micro and will run before any macro callback
    Any callbacks scheduled during (3) are macro.
  3. After both queues drain, optional post_fn() is invoked and transaction ends.

This guarantees:
  - Every callback sees a fresh todo_map from the prior op batch
  - “Internal” reactions queued inside ops (e.g., metadata on_add/on_remove) run and settle
    before any sibling callbacks queued by public API code after add_op
  - discover_todos() is called exactly once per batch of ops

remember...
  - callbacks should not directly mutate buffer state; they should queue ops via add_op
  - batching ensures that discover_todos() is called exactly once per group of ops,
    minimizing expensive recomputation even if many todo items operated on
]]
--

local M = {}
local parser = require("checkmate.parser")
local diff = require("checkmate.lib.diff")

---the exposed transaction state is referred to as "context"
---the internal state is M._states[bufnr]
---@class checkmate.TransactionContext
---@field get_todo_map fun(): checkmate.TodoMap
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
    cb_micro_queue = {}, -- callbacks scheduled during op application or other micro-cbs
    cb_macro_queue = {}, -- callbacks scheduled by entry_fn or other macro-cbs
    seen_ops = {},
    phase = "idle", -- "idle" | "op" | "cb_micro" | "cb_macro"
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
      -- if scheduled while applying ops or running other micro-cbs, classify as MICRO
      -- otherwise, classify as MACRO
      local pack = { cb_fn = cb_fn, params = { ... } }
      if state.phase == "op" or state.phase == "cb_micro" then
        table.insert(state.cb_micro_queue, pack)
      else
        table.insert(state.cb_macro_queue, pack)
      end
    end,

    get_buf = function()
      return state.bufnr
    end,
  }

  M._states[bufnr] = state

  -- this is where the call queues up ops/callbacks (macro by default)
  entry_fn(state.context)

  -- drain until stable: ops → micro → macro (repeat)
  while #state.op_queue > 0 or #state.cb_micro_queue > 0 or #state.cb_macro_queue > 0 do
    if #state.op_queue > 0 then
      local queued = state.op_queue
      state.op_queue = {}

      ---@type checkmate.TextDiffHunk[]
      local all_hunks = {}

      state.phase = "op"
      for _, op in ipairs(queued) do
        local op_result = op.fn(state.context, unpack(op.args))
        if type(op_result) == "table" then
          if not vim.islist(op_result) and getmetatable(op_result) == diff.TextDiffHunk then
            vim.list_extend(all_hunks, { op_result })
          elseif vim.islist(op_result) then
            vim.list_extend(all_hunks, op_result)
          end
        end
      end
      state.phase = "idle"

      if #all_hunks > 0 then
        diff.apply_diff(bufnr, all_hunks)
        state.todo_map = parser.get_todo_map(bufnr)
      end
    elseif #state.cb_micro_queue > 0 then
      local cbs = state.cb_micro_queue
      state.cb_micro_queue = {}
      state.phase = "cb_micro"
      for _, cb in ipairs(cbs) do
        pcall(function()
          cb.cb_fn(state.context, unpack(cb.params))
        end)
      end
      state.phase = "idle"
    else -- macro
      local cbs = state.cb_macro_queue
      state.cb_macro_queue = {}
      state.phase = "cb_macro"
      for _, cb in ipairs(cbs) do
        pcall(function()
          cb.cb_fn(state.context, unpack(cb.params))
        end)
      end
      state.phase = "idle"
    end
  end

  if post_fn then
    post_fn()
  end

  M._states[bufnr] = nil
end

return M
