--- A class for Markdown headings
--- - currently only supports ATX headings, e.g. using #, not setext (using - or = underlines)
---
---@class checkmate.Heading
---@field title string
---@field level integer
local M = {}
M.__index = M

---@class checkmate.HeadingSection
---@field heading checkmate.Heading
---@field start_row integer 0-based row containing the heading
---@field end_row integer 0-based final row in this heading section
---@field level integer heading level, for convenience
---@field parent_start_row? integer 0-based row of the parent heading section

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

---@param node TSNode
---@return TSNode|nil
local function first_atx_heading_child(node)
  for child in node:iter_children() do
    if child:type() == "atx_heading" then
      return child
    end
  end
end

---Build a section index from the markdown treesitter tree.
---Only includes ATX headings. The markdown parser is required by Checkmate, so
---callers can treat this as the single heading/section source of truth.
---@param bufnr integer
---@param lines? string[] snapshot lines matching the buffer parse
---@return checkmate.HeadingSection[]
function M.get_heading_sections(bufnr, lines)
  local ts_parser = vim.treesitter.get_parser(bufnr, "markdown")
  if not ts_parser then
    error("[checkmate] markdown parser not found")
  end
  local tree = ts_parser:parse()[1]

  if not tree then
    return {}
  end

  local sections = {}

  ---@param node TSNode
  ---@param parent checkmate.HeadingSection|nil
  local function walk(node, parent)
    local entry = parent

    if node:type() == "section" then
      local heading_node = first_atx_heading_child(node)

      if heading_node then
        local heading_row = heading_node:range()
        local _, _, section_end_row = node:range()
        local line = lines and lines[heading_row + 1]

        if not line then
          line = vim.api.nvim_buf_get_lines(bufnr, heading_row, heading_row + 1, false)[1]
        end

        local heading = M.from_atx_heading_string(line)

        if heading then
          entry = {
            heading = heading,
            start_row = heading_row,
            end_row = math.max(heading_row, section_end_row - 1),
            level = heading.level,
            parent_start_row = parent and parent.start_row or nil,
          }
          sections[#sections + 1] = entry
        end
      end
    end

    for child in node:iter_children() do
      if child:type() == "section" then
        walk(child, entry)
      end
    end
  end

  walk(tree:root(), nil)

  table.sort(sections, function(a, b)
    return a.start_row < b.start_row
  end)

  return sections
end

--- Returns the first section matching exact level and title, and
--- optionally exact parent section
---@param sections checkmate.HeadingSection[]
---@param heading checkmate.Heading
---@param parent_start_row? integer
---@return checkmate.HeadingSection|nil
function M.find_section(sections, heading, parent_start_row)
  for _, section in ipairs(sections) do
    local parent_matches = parent_start_row == nil or section.parent_start_row == parent_start_row
    local heading_matches = section.level == heading.level and section.heading.title == heading.title

    if parent_matches and heading_matches then
      return section
    end
  end
end

return M
