---@diagnostic disable-next-line: missing-fields
local M = {} ---@type checkmate.DebounceModule

---@class checkmate.DebounceModule : table
---@field debounce fun(fn: fun(...), opts?: checkmate.DebounceOpts): checkmate.Debounced
---@overload fun(fn: fun(...), opts?: checkmate.DebounceOpts): checkmate.Debounced

---@class checkmate.Debounced
---@field cancel fun(self: checkmate.Debounced)
---@field flush  fun(self: checkmate.Debounced)
---@field close  fun(self: checkmate.Debounced)
---@overload fun(...)

---@class checkmate.DebounceOpts
---@field ms? integer
---@field leading? boolean
---@field trailing? boolean

local uv = vim.uv

---@param fn fun(...)
---@param opts? checkmate.DebounceOpts
---@return checkmate.Debounced
function M.debounce(fn, opts)
  opts = opts or {}
  local ms = opts.ms or 20
  local leading = opts.leading == true
  local trailing = (opts.trailing ~= false) -- default true

  local timer = assert(uv.new_timer())
  local active = false -- currently inside debounce window
  local pending = false -- a call occurred during the window
  local last_args -- { ..., n = <argc> }

  -- schedule-wrapped caller to stay on the main loop safely
  local call = vim.schedule_wrap(function(...)
    fn(...)
  end)

  local function stop_timer()
    if timer and timer:is_active() then
      timer:stop()
    end
  end

  local function on_timeout()
    stop_timer()
    local do_trailing = trailing and pending
    active, pending = false, false
    if do_trailing and last_args then
      call(unpack(last_args, 1, last_args.n))
    end
  end

  local function invoke(...)
    last_args = { ..., n = select("#", ...) }

    -- leading: fire immediately once per window
    if leading and not active then
      active = true
      pending = false
      if trailing then
        stop_timer()
        timer:start(ms, 0, on_timeout)
      end
      return call(unpack(last_args, 1, last_args.n))
    end

    -- within the window: mark pending and (re)start trailing timer
    pending = true
    active = true
    if trailing then
      stop_timer()
      timer:start(ms, 0, on_timeout)
    end
  end

  local obj = {}

  function obj:cancel()
    stop_timer()
    active, pending, last_args = false, false, nil
  end

  function obj:flush()
    stop_timer()
    if last_args then
      call(unpack(last_args, 1, last_args.n))
    end
    active, pending = false, false
  end

  function obj:close()
    self:cancel()
    if timer and not timer:is_closing() then
      timer:close()
    end
  end

  return setmetatable(obj, {
    __call = function(_, ...)
      return invoke(...)
    end,
  })
end

return setmetatable(M, {
  __call = function(_, fn, opts)
    return M.debounce(fn, opts)
  end,
})
