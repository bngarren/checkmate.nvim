local M = {}

local uv = vim.uv or vim.loop

local ns_counter = 0
local function create_animation_ns()
  ns_counter = ns_counter + 1
  return vim.api.nvim_create_namespace("checkmate_animation_" .. ns_counter)
end

---@class AnimationState
---@field idx integer current frame index
---@field ext_id integer? current extmark id
---@field timer uv.uv_timer_t? timer handle
---@field bufnr integer
---@field ns integer namespace
---@field stopped boolean
---@field stop? function

---@class NewOpts
---@field bufnr integer buffer (default current)
---@field frames string[] animation frames to cycle through
---@field render fun(frame:string, state:table):integer function to draw a frame, returns extmark id
---@field interval? integer ms between frames (default 100)

--- @param opts NewOpts
--- @return AnimationState state animation handle with :stop()
function M.new(opts)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local frames = opts.frames or {}
  local render = opts.render
  local interval = opts.interval or 100

  assert(type(frames) == "table" and #frames > 0, "new(): frames array required")
  assert(type(render) == "function", "new(): render function required")

  local ns = create_animation_ns()

  ---@type AnimationState
  local state = { idx = 1, ext_id = nil, timer = nil, bufnr = bufnr, ns = ns, stopped = false }

  local function draw()
    if state.stopped then
      return
    end
    local ok, ext_id = pcall(render, frames[state.idx], state)
    if ok and ext_id then
      state.ext_id = ext_id
    end
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  -- start
  draw()

  state.timer = uv.new_timer()
  state.timer:start(
    0,
    interval,
    vim.schedule_wrap(function()
      if state.stopped or not vim.api.nvim_buf_is_valid(bufnr) then
        state:stop()
        return
      end
      state.idx = (state.idx % #frames) + 1
      draw()
    end)
  )

  function state:stop()
    if self.stopped then
      return
    end

    self.stopped = true

    pcall(function()
      if self.timer then
        self.timer:stop()
        self.timer:close()
        self.timer = nil
      end
      if vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.api.nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)
      end

      self.ext_id = nil
    end)
  end

  return state
end

---@class VirtLineOpts
---@field bufnr? integer buffer (default current)
---@field text? string label
---@field row integer 0-indexed row for extmark
---@field col? integer 0-indexed col for extmark
---@field hl_group? string highlight group (default "Comment")
---@field interval? integer ms between frames (default 100)

---Animate a spinner via extmark virt_lines
---@param opts VirtLineOpts
--- @return AnimationState state animation handle with :stop()
function M.virt_line(opts)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local row = opts.row
  local col = opts.col or 0
  local label = opts.text or ""
  local hl = opts.hl_group or "Comment"
  local interval = opts.interval or 80

  local frames = { "⠋", "⠙", "⠚", "⠞", "⠖", "⠦", "⠴", "⠲", "⠳", "⠓" }

  local function render(frame, state)
    local virt = frame .. (label ~= "" and " " .. label or "")
    local mark_opts = {
      virt_lines = { { { virt, hl } } },
      virt_lines_above = false,
      id = state.ext_id,
      priority = 100,
    }
    return vim.api.nvim_buf_set_extmark(state.bufnr, state.ns, row, col, mark_opts)
  end

  return M.new({
    bufnr = bufnr,
    frames = frames,
    render = render,
    interval = interval,
  })
end

---@class InlineOpts
---@field bufnr? integer buffer (default current)
---@field text? string label
---@field range checkmate.Range
---@field hl_group? string highlight group (default "Comment")
---@field interval? integer ms between frames (default 100)

---@param opts InlineOpts
function M.inline(opts)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local interval = opts.interval or 80
  local label = opts.text or ""

  local frames = { "⠋", "⠙", "⠚", "⠞", "⠖", "⠦", "⠴", "⠲", "⠳", "⠓" }

  local function render(frame, state)
    local virt = frame .. (label ~= "" and " " .. label or "")
    local mark_opts = {
      end_row = opts.range["end"].row,
      end_col = opts.range["end"].col,
      virt_text = { { virt, "Comment" } },
      virt_text_pos = "inline",
      hl_mode = "combine",
      id = state.ext_id,
      priority = 100,
    }
    return vim.api.nvim_buf_set_extmark(state.bufnr, state.ns, opts.range.start.row, opts.range.start.col, mark_opts)
  end

  return M.new({
    bufnr = bufnr,
    frames = frames,
    render = render,
    interval = interval,
  })
end

return M
