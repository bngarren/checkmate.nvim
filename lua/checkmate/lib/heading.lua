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

--- Parse a raw ATX heading line into a Heading object
--- Strips the optional CommonMark 4.2 closing sequence (e.g. "## Title ##" → title="Title").
--- Returns nil if the string is not a valid ATX heading
---@param str string
---@return checkmate.Heading|nil
function M.from_atx_heading_string(str)
  if str == nil or #str == 0 then
    return nil
  end
  local hashes, title = str:match("^%s*(#+)%s+(.*)")
  if not hashes then
    return nil
  end
  title = vim.trim(title:gsub("%s+#+%s*$", ""))
  return M.new(title, #hashes)
end

---Build a Markdown heading string
---@param title string text after the hashes
---@param level? integer 1-6; clamped; defaults to 2
---@return string
function M.get_heading_string(title, level)
  level = tonumber(level) or 2
  level = math.min(math.max(level, 1), 6)
  return string.rep("#", level) .. " " .. title
end

--- Returns the ATX heading level (1-6) from a raw buffer line, or nil if the
--- line is not an ATX heading
---@param line string
---@return integer|nil level
function M.get_atx_heading_level(line)
  local hashes = line:match("^%s*(#+)%s+")
  if not hashes or #hashes > 6 then
    return nil
  end
  return #hashes
end

--- Returns a Lua pattern that matches an ATX heading at exactly this level
--- e.g. level=2 → "^%s*##%s"
---@return string
function M:get_atx_heading_pattern()
  return "^%s*" .. string.rep("#", self.level) .. "%s"
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
