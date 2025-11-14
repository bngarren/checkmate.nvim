--- Simple line cache for operations that need repeated access to same lines
--- e.g. a buffer highlighting pass
---@class checkmate.Util.line_cache
---@field private bufnr integer
---@field private lines table<integer, string>
---@field get fun(self: checkmate.Util.line_cache, row: integer): string
local M = {}
M.__index = M

---@param bufnr integer
---@return checkmate.Util.line_cache
function M.new(bufnr)
  local self = setmetatable({
    bufnr = bufnr,
    lines = {},
  }, M)
  return self
end

---@param row integer 0-based row number
---@return string
function M:get(row)
  if self.lines[row] == nil then
    local lines = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)
    self.lines[row] = lines[1] or ""
  end
  return self.lines[row]
end

return M
