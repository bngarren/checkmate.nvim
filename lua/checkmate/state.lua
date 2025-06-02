local M = {}

local state = {
  initialized = false,
  running = false,
  setup_callbacks = {},
  active_buffers = {}, -- bufnr -> true
}

function M.is_initialized()
  return state.initialized
end

function M.set_initialized(value)
  state.initialized = value

  -- run cb's after setup done
  if value and #state.setup_callbacks > 0 then
    local callbacks = state.setup_callbacks
    state.setup_callbacks = {}
    for _, callback in ipairs(callbacks) do
      vim.schedule(callback)
    end
  end
end

function M.is_running()
  return state.running
end

function M.set_running(value)
  state.running = value
end

function M.on_initialized(callback)
  if state.initialized then
    callback()
  else
    -- queue it
    table.insert(state.setup_callbacks, callback)
  end
end

function M.register_buffer(bufnr)
  state.active_buffers[bufnr] = true
end

function M.unregister_buffer(bufnr)
  state.active_buffers[bufnr] = nil
end

function M.is_buffer_active(bufnr)
  return state.active_buffers[bufnr] == true
end

function M.get_active_buffers()
  local buffers = {}
  for bufnr in pairs(state.active_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(buffers, bufnr)
    else
      state.active_buffers[bufnr] = nil
    end
  end
  return buffers
end

function M.reset()
  state.initialized = false
  state.running = false
  state.setup_callbacks = {}
  state.active_buffers = {}
end

return M
