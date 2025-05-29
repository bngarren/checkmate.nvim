-- checkmate/transaction.lua

local M = {}
local parser = require("checkmate.parser")
local api = require("checkmate.api")

M._state = nil

-- Helper: Group operations by their API function
local function group_by_fn(ops)
  local batches = {}
  for _, op in ipairs(ops) do
    local fn = op.fn
    batches[fn] = batches[fn] or {}
    table.insert(batches[fn], op)
  end
  return batches
end

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
    todo_map = parser.discover_todos(bufnr),
    op_queue = {},
    cb_queue = {},
    seen_ops = {},
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

    -- Queue an API operation
    add_op = function(fn, extmark_id, ...)
      local fn_name = debug.getinfo(fn, "n").name or tostring(fn)
      local key = fn_name .. ":" .. tostring(extmark_id)
      if not M._state.seen_ops[key] then
        M._state.seen_ops[key] = true
        table.insert(M._state.op_queue, {
          fn = fn,
          extmark_id = extmark_id,
          params = { ... },
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

  -- Execute the entry function
  entry_fn(state.context)

  -- Transaction loop: process operations and callbacks until both queues are empty
  while #M._state.op_queue > 0 or #M._state.cb_queue > 0 do
    -- Process all queued operations
    if #M._state.op_queue > 0 then
      local ops = M._state.op_queue
      M._state.op_queue = {}

      -- Group operations by function for batch processing
      local grouped = group_by_fn(ops)

      for fn, fn_ops in pairs(grouped) do
        -- Prepare items and params arrays for the API function
        local items = {}
        local params = {}

        for _, op in ipairs(fn_ops) do
          -- Find the item using the string ID
          local item = M._state.todo_map[op.extmark_id]
          if item then
            table.insert(items, item)
            table.insert(params, op.params)
          end
        end

        if #items > 0 then
          -- Call the API function with proper signature
          local hunks = fn(items, params, state.context)

          -- Apply the diff if we got hunks back
          if hunks and #hunks > 0 then
            api.apply_diff(bufnr, hunks)
            -- Refresh the todo map after buffer changes
            M._state.todo_map = parser.discover_todos(bufnr)
          end
        end
      end
    end

    -- Process all queued callbacks
    if #M._state.cb_queue > 0 then
      local cbs = M._state.cb_queue
      M._state.cb_queue = {}

      for _, cb in ipairs(cbs) do
        -- Execute callback with transaction context
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
