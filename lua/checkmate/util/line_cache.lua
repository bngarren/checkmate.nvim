--- Simple line cache for operations that need repeated access to same lines
--- e.g. a buffer highlighting pass
---@class LineCache
---@field private bufnr integer
---@field private lines table<integer, string>
---@field get fun(self: LineCache, row: integer): string
local LineCache = {}
LineCache.__index = LineCache

---@param bufnr integer
---@return LineCache
function LineCache.new(bufnr)
  local self = setmetatable({
    bufnr = bufnr,
    lines = {},
  }, LineCache)
  return self
end

---@param row integer 0-based row number
---@return string
function LineCache:get(row)
  if self.lines[row] == nil then
    local lines = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)
    self.lines[row] = lines[1] or ""
  end
  return self.lines[row]
end

return LineCache
