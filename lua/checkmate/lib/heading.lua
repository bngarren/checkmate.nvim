--- A class for Markdown headings
--- - currently only supports ATX headings, e.g. using #, not setext (using - or = underlines)
---
---@class checkmate.Heading
---@field title string
---@field level integer
local M = {}
M.__index = M

---@param title string Content for new Markdown heading
---@param level integer? Heading level, i.e. number of #s. Default is 2.
---@return checkmate.Heading
function M.new(title, level)
  return setmetatable({ title = title, level = level or 2 }, M)
end

function M.from_atx_heading_string(str)
  if str == nil or #str == 0 then
    return nil
  end
  local hashes, title = str:match("^%s*(#+)%s+(.*)")
  return M.new(title, #hashes)
end

---Build a Markdown heading
---@param title string text after the hashes
---@param level? integer 1-6; clamped; defaults to 2
---@return string
function M.get_heading_string(title, level)
  level = tonumber(level) or 2
  level = math.min(math.max(level, 1), 6)
  return string.rep("#", level) .. " " .. title
end

--- Returns the Lua pattern for the ATX heading, e.g. matching the #'s
function M:get_atx_heading_pattern()
  return "^%s*" .. string.rep("#", 1, self.level) .. "+%s"
end

--- Returns the raw string heading, e.g. "## Some Title"
function M:to_string()
  return M.get_heading_string(self.title, self.level)
end

--- Returns the current heading level + 1
function M:get_child_level()
  return self.level + 1
end

return M
