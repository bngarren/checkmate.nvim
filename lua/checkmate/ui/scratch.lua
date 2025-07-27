---@class checkmate.Scratch.Config
---@field floating? boolean -- open in floating window
---@field width? number -- window width (columns)
---@field height? number -- window height (lines)
---@field border? string -- window border style
---@field relative? string -- relative positioning context
---@field row? number -- row position
---@field col? number -- column position
---@field ft? string -- filetype

---@class checkmate.Scratch
---@field config checkmate.Scratch.Config
---@field bufnr number -- buffer handle
---@field winid number -- window handle
local M = {}

M.default = {
  floating = true,
  width = nil, -- nil => 80% of columns
  height = nil, -- nil => 80% of lines
  border = "rounded",
  relative = "editor",
  row = nil, -- nil => centered
  col = nil,
  ft = "text",
}

---@param user_config checkmate.Scratch.Config
function M.setup(user_config)
  M.config = vim.tbl_extend("force", M.config, user_config or {})
end

---@param opts? checkmate.Scratch.Config
---@return checkmate.Scratch inst
function M.open(opts)
  opts = vim.tbl_extend("force", M.default, opts or {})
  local inst = setmetatable({ config = opts }, { __index = M })

  local width = opts.width or math.ceil(vim.o.columns * 0.8)
  local height = opts.height or math.ceil(vim.o.lines * 0.8)
  local row = opts.row or math.floor((vim.o.lines - height) / 2)
  local col = opts.col or math.floor((vim.o.columns - width) / 2)

  inst.bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = inst.bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = inst.bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = inst.bufnr })

  if opts.ft then
    vim.api.nvim_set_option_value("filetype", opts.ft, { buf = inst.bufnr })
  end

  if opts.floating then
    inst.winid = vim.api.nvim_open_win(inst.bufnr, true, {
      relative = opts.relative,
      row = row,
      col = col,
      width = width,
      height = height,
      style = "minimal",
      border = opts.border,
    })
  else
    -- fallback to vertical split
    vim.cmd("botright vsplit")
    inst.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(inst.winid, inst.bufnr)
  end

  -- buffer-local mappings: close on 'q' or '<esc>'
  vim.keymap.set("n", "q", function()
    inst:close()
  end, { buffer = inst.bufnr, silent = true })
  vim.keymap.set("n", "<esc>", function()
    inst:close()
  end, { buffer = inst.bufnr, silent = true })

  return inst
end

---@param lines string|string[]
function M:set(lines)
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  end
end

---@param lines string|string[]
function M:append(lines)
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
  end
end

function M:clear()
  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, {})
  end
end

function M:close()
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_close(self.winid, true)
    self.winid = nil
  end
end

return M
